_root="$(dirname "${BASH_SOURCE[0]}")/.."
_has() { grep -qxF "$2" "$_root/$1"; }   # file pkg

test_core_keeps_required() {
    for p in fish nano vim nmap \
             pipewire wireplumber pavucontrol sof-firmware alsa-utils \
             networkmanager wpa_supplicant wireguard-tools bluez \
             playerctl cmatrix keyd firefox \
             ttf-jetbrains-mono-nerd ttf-nerd-fonts-symbols \
             ttf-nerd-fonts-symbols-mono; do
        assert_true _has packages/core.txt "$p"
    done
}

test_niri_wayland_content() {
    for p in niri waybar mako swaybg swaylock fuzzel kitty \
             vulkan-icd-loader wayland wayland-protocols \
             xdg-desktop-portal xdg-desktop-portal-gtk \
             xorg-xwayland xwayland-satellite; do
        assert_true  _has packages/niri-wayland.txt "$p"
        assert_false _has packages/core.txt "$p"
    done
}

test_core_excludes_dropped() {
    for p in steam discord waydroid rpi-imager greetd greetd-tuigreet \
             paru yay alacritty cool-retro-term xterm starship \
             blackarch-mirrorlist bully reaver wifite pixiewps \
             mesa vulkan-intel lib32-mesa; do
        assert_false _has packages/core.txt "$p"
    done
}

test_optional_lists_content() {
    assert_true  _has packages/optional/security-tools.txt aircrack-ng
    assert_false _has packages/optional/security-tools.txt nmap   # nmap is core
    assert_true  _has packages/optional/asus.txt asusctl
    assert_true  _has packages/optional/fonts-extra.txt ttf-iosevka-nerd
}

test_aur_curation() {
    # aur.txt is intentionally empty: only OS/chipset-driver/GUI-essential
    # packages are auto-installed, and none of these are that.
    for p in battop byobu ipscan-bin elio neofetch-git asusctl rog-control-center; do
        assert_false _has packages/aur.txt "$p"
    done
}
