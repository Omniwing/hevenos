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

PKG_FAILED=()

install_aur_pkg() { # pkgname -> 0 installed or already present, 1 could not
    # No AUR helper: paru/yay are prebuilt binaries dynamically linked
    # against a specific libalpm SONAME, and staleness on the maintainer's
    # end (outside our control) causes hard-to-fix runtime breakage. We
    # only ever install a small, fixed, hand-picked package list — plain
    # makepkg (part of base-devel, a bash script, no ABI of its own to go
    # stale) is all that's actually needed, and it's what an AUR helper
    # calls internally anyway.
    local pkg="$1"
    pacman -Qi "$pkg" >/dev/null 2>&1 && return 0

    # Never build what the official repositories already ship. Packages do
    # graduate out of the AUR — asusctl, rog-control-center and
    # broadcom-wl-dkms are all in extra now — and the AUR leaves the old git
    # repo in place but empty rather than deleting it, so building first
    # clones nothing and fails on a package that pacman could have installed
    # in seconds.
    if pacman -Si "$pkg" >/dev/null 2>&1; then
        echo ":: Installing $pkg from the official repositories"
        sudo pacman -S --needed --noconfirm "$pkg" && return 0
        echo "!! $pkg is in the official repositories but would not install." >&2
        return 1
    fi

    echo ":: Building $pkg from AUR"
    # /var/tmp, not /tmp: Arch mounts /tmp as RAM-backed tmpfs by default,
    # and a build's object files/caches can exhaust that on a low-RAM
    # machine even with plenty of real disk space free elsewhere
    # ("no space left on device" despite df showing room). /var/tmp is
    # always disk-backed.
    local tmp rc=0; tmp="$(mktemp -d --tmpdir=/var/tmp)"
    if ! git clone "https://aur.archlinux.org/$pkg.git" "$tmp/$pkg"; then
        echo "!! Could not clone $pkg from the AUR." >&2
        rc=1
    elif [[ ! -f "$tmp/$pkg/PKGBUILD" ]]; then
        # The AUR answers an unknown name with an empty repository instead of
        # a 404, so "cloned, but no PKGBUILD" is what a retired, renamed or
        # mistyped package looks like. asusctl-debug was one: a debug-symbol
        # package makepkg produces as a by-product, which 'pacman -Qqem' on
        # the source machine reports as a foreign package like any other.
        echo "!! $pkg is not an AUR package (the repository is empty)." >&2
        rc=1
    elif ! ( cd "$tmp/$pkg" && makepkg -si --noconfirm ); then
        echo "!! $pkg failed to build." >&2
        rc=1
    fi
    rm -rf "$tmp"
    return "$rc"
}

install_aur_list() { # path-to-list
    [[ -f "$1" ]] || return 0
    local pkg
    while IFS= read -r pkg; do
        [[ -z "$pkg" || "$pkg" == \#* ]] && continue
        # One package that cannot be installed must not end the run. Stage 1
        # already works this way; stage 2 used to die on the first failure
        # under 'set -e', leaving stage2.sh in place to fail again at every
        # single login, with no way out but editing the list by hand.
        install_aur_pkg "$pkg" || PKG_FAILED+=("$pkg")
    done < "$1"
    return 0
}

main() {
    # Revoke the temporary passwordless-sudo grant (see install.sh's handoff())
    # on ANY exit — success or failure — so it can never outlive a single run.
    # A failed build previously left NOPASSWD sudo in place until some later
    # run happened to succeed, i.e. potentially forever if a package stayed
    # broken. `sudo -n` means the trap never prompts: on the granted run it
    # removes the file silently; on a later retry (grant already gone) it is a
    # silent no-op. Set here rather than at file scope so that sourcing this
    # script, as the tests do, never touches sudo.
    trap 'sudo -n rm -f /etc/sudoers.d/99-hevenos-stage2 2>/dev/null || true' EXIT

    wait_for_network
    # Full upgrade before building anything: real time may have passed
    # since stage 1 (reboot, walking away).
    sudo pacman -Syu --noconfirm
    install_aur_list "$PKGS/aur.txt"
    if [[ -f "$HOME_DIR/.hevenos-asus" ]]; then
        install_aur_list "$PKGS/optional/asus.txt"
    fi
    if [[ -f "$HOME_DIR/.hevenos-broadcom" ]]; then
        echo ":: Broadcom wifi detected; installing broadcom-wl-dkms"
        install_aur_pkg broadcom-wl-dkms || PKG_FAILED+=(broadcom-wl-dkms)
    fi
    fc-cache -f || true

    if (( ${#PKG_FAILED[@]} > 0 )); then
        printf '%s\n' "${PKG_FAILED[@]}" > "$HOME_DIR/hevenos-packages-failed.txt"
        echo "!! Could not install: ${PKG_FAILED[*]}" >&2
        echo "!! Recorded in ~/hevenos-packages-failed.txt. Setup is otherwise complete." >&2
    fi
    echo ":: Done — type 'niri' to start the desktop."
    # Reached whether or not an optional package installed, so a package that
    # can never succeed cannot trap the login hook in a loop. A run cut short
    # earlier than this — no network, a failed system upgrade — still exits
    # with stage2.sh in place and retries at the next login.
    rm -f "$HOME_DIR/stage2.sh"
}

# Only run when executed, so the tests can source this file for its functions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main
fi
