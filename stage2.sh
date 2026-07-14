#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -ne 0 ]] || { echo "Run stage 2 as your normal user, not root." >&2; exit 1; }
HOME_DIR="$HOME"
PKGS="$HOME_DIR/hevenos/packages"

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
    bootstrap_paru
    install_aur "$PKGS/aur.txt"
    [[ -f "$HOME_DIR/.hevenos-asus" ]] && install_aur "$PKGS/optional/asus.txt"
    if [[ -f "$HOME_DIR/.hevenos-broadcom" ]]; then
        echo ":: Broadcom wifi detected; installing broadcom-wl-dkms"
        paru -S --needed --noconfirm broadcom-wl-dkms
    fi
    fc-cache -f || true
    echo ":: Done — type 'niri' to start the desktop."
}
main
