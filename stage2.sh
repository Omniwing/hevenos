#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -ne 0 ]] || { echo "Run stage 2 as your normal user, not root." >&2; exit 1; }
HOME_DIR="$HOME"
PKGS="$HOME_DIR/hevenos/packages"

wait_for_network() {
    # Runs automatically right at login, before NetworkManager may have
    # finished resolving DNS on slower hardware. Poll for real resolution
    # rather than a fixed sleep, so this adapts to however long this
    # particular boot actually takes instead of guessing a delay.
    local i
    for i in $(seq 1 30); do
        getent hosts aur.archlinux.org >/dev/null 2>&1 && return 0
        [[ $i -eq 1 ]] && echo ":: Waiting for network..."
        sleep 2
    done
    echo ":: Network still not ready after 60s; continuing anyway (may fail)." >&2
}

bootstrap_paru() {
    # A functional check, not just "does the file exist": paru-bin is a
    # prebuilt binary from the AUR, linked against whatever libalpm its
    # maintainer's machine had at build time. If the AUR package lags
    # behind Arch's current libalpm SONAME (outside our control — we
    # don't control that maintainer's rebuild cadence), the installed
    # binary exists but fails to even start. `command -v` alone can't
    # see that, and would wrongly treat a known-broken paru as "already
    # bootstrapped" on every retry, forever.
    paru --version >/dev/null 2>&1 && return 0

    echo ":: Bootstrapping paru-bin (prebuilt; source paru compiles Rust for hours)"
    local tmp; tmp="$(mktemp -d)"
    git clone https://aur.archlinux.org/paru-bin.git "$tmp/paru-bin"
    ( cd "$tmp/paru-bin" && makepkg -si --noconfirm )
    rm -rf "$tmp"

    paru --version >/dev/null 2>&1 && return 0

    echo ":: paru-bin doesn't run on this system (likely a stale prebuilt binary vs. the current libalpm)." >&2
    echo ":: Falling back to building paru from source — this can take a long time on slow hardware." >&2
    sudo pacman -R --noconfirm paru-bin 2>/dev/null || true
    local tmp2; tmp2="$(mktemp -d)"
    git clone https://aur.archlinux.org/paru.git "$tmp2/paru"
    ( cd "$tmp2/paru" && makepkg -si --noconfirm )
    rm -rf "$tmp2"
}

install_aur() { # list
    [[ -f "$1" ]] || return 0
    paru -S --needed --noconfirm - < "$1"
}

main() {
    wait_for_network
    # Full upgrade before touching AUR: real time may have passed since
    # stage 1 (reboot, walking away), and a prebuilt paru-bin binary needs
    # the system's libalpm to actually match what it was linked against.
    sudo pacman -Syu --noconfirm
    bootstrap_paru
    install_aur "$PKGS/aur.txt"
    [[ -f "$HOME_DIR/.hevenos-asus" ]] && install_aur "$PKGS/optional/asus.txt"
    if [[ -f "$HOME_DIR/.hevenos-broadcom" ]]; then
        echo ":: Broadcom wifi detected; installing broadcom-wl-dkms"
        paru -S --needed --noconfirm broadcom-wl-dkms
    fi
    fc-cache -f || true
    echo ":: Done — type 'niri' to start the desktop."
    # Revoke the temporary passwordless sudo stage 1 granted for this
    # unattended build window (see install.sh's handoff()) as the very
    # last action, using the access it's about to remove.
    sudo rm -f /etc/sudoers.d/99-hevenos-stage2
    rm -f "$HOME_DIR/stage2.sh"
}
main
