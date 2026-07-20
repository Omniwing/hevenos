#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -ne 0 ]] || { echo "Run stage 2 as your normal user, not root." >&2; exit 1; }
HOME_DIR="$HOME"
PKGS="$HOME_DIR/hevenos/packages"

wait_for_network() {
    # Runs automatically right at login, before NetworkManager may have
    # finished resolving DNS on slower hardware — or before it has any
    # saved network to connect to at all (e.g. wifi that wasn't migrated
    # from the live ISO; see install.sh's migrate_wifi_credentials). Poll
    # for real resolution rather than a fixed sleep, so this adapts to
    # however long this particular boot actually takes.
    local i
    for i in $(seq 1 8); do   # ~15s
        getent hosts aur.archlinux.org >/dev/null 2>&1 && return 0
        [[ $i -eq 1 ]] && echo ":: Waiting for network..."
        sleep 2
    done

    if command -v nmtui >/dev/null 2>&1; then
        echo ":: No network yet. Opening the network manager — pick your wifi"
        echo ":: network, connect, then exit (Esc or q) to continue setup."
        nmtui
    fi

    for i in $(seq 1 30); do   # another ~60s after nmtui returns
        getent hosts aur.archlinux.org >/dev/null 2>&1 && return 0
        sleep 2
    done
    echo ":: Network still not ready; continuing anyway (may fail)." >&2
}

install_aur_pkg() { # pkgname
    # No AUR helper: paru/yay are prebuilt binaries dynamically linked
    # against a specific libalpm SONAME, and staleness on the maintainer's
    # end (outside our control) causes hard-to-fix runtime breakage. We
    # only ever install a small, fixed, hand-picked package list — plain
    # makepkg (part of base-devel, a bash script, no ABI of its own to go
    # stale) is all that's actually needed, and it's what an AUR helper
    # calls internally anyway.
    local pkg="$1"
    pacman -Qi "$pkg" >/dev/null 2>&1 && return 0
    echo ":: Building $pkg from AUR"
    # /var/tmp, not /tmp: Arch mounts /tmp as RAM-backed tmpfs by default,
    # and a build's object files/caches can exhaust that on a low-RAM
    # machine even with plenty of real disk space free elsewhere
    # ("no space left on device" despite df showing room). /var/tmp is
    # always disk-backed.
    local tmp; tmp="$(mktemp -d --tmpdir=/var/tmp)"
    git clone "https://aur.archlinux.org/$pkg.git" "$tmp/$pkg"
    ( cd "$tmp/$pkg" && makepkg -si --noconfirm )
    rm -rf "$tmp"
}

install_aur_list() { # path-to-list
    [[ -f "$1" ]] || return 0
    local pkg
    while IFS= read -r pkg; do
        [[ -z "$pkg" || "$pkg" == \#* ]] && continue
        install_aur_pkg "$pkg"
    done < "$1"
}

# Revoke the temporary passwordless-sudo grant (see install.sh's handoff())
# on ANY exit — success or failure — so it can never outlive a single run.
# A failed build previously left NOPASSWD sudo in place until some later run
# happened to succeed, i.e. potentially forever if a package stayed broken.
# `sudo -n` means the trap never prompts: on the granted run it removes the
# file silently; on a later retry (grant already gone) it's a silent no-op.
trap 'sudo -n rm -f /etc/sudoers.d/99-hevenos-stage2 2>/dev/null || true' EXIT

main() {
    wait_for_network
    # Full upgrade before building anything: real time may have passed
    # since stage 1 (reboot, walking away).
    sudo pacman -Syu --noconfirm
    install_aur_list "$PKGS/aur.txt"
    [[ -f "$HOME_DIR/.hevenos-asus" ]] && install_aur_list "$PKGS/optional/asus.txt"
    if [[ -f "$HOME_DIR/.hevenos-broadcom" ]]; then
        echo ":: Broadcom wifi detected; installing broadcom-wl-dkms"
        install_aur_pkg broadcom-wl-dkms
    fi
    fc-cache -f || true
    echo ":: Done — type 'niri' to start the desktop."
    # Success only: remove the installer so the login hook stops re-running
    # it. On failure the script has already exited (set -e) with stage2.sh
    # left in place, so setup retries at the next login; the sudo grant is
    # revoked either way by the EXIT trap above.
    rm -f "$HOME_DIR/stage2.sh"
}
main
