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
    if command -v paru >/dev/null 2>&1; then return 0; fi
    echo ":: Bootstrapping paru-bin (prebuilt; source paru compiles Rust for hours)"
    local tmp; tmp="$(mktemp -d)"
    git clone https://aur.archlinux.org/paru-bin.git "$tmp/paru-bin"
    ( cd "$tmp/paru-bin" && makepkg -si --noconfirm )
    rm -rf "$tmp"
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
