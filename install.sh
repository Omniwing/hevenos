#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/ui.sh"
source "$HERE/lib/detect.sh"
source "$HERE/lib/packages.sh"

MNT="${HEVENOS_MNT:-/mnt}"
NVIDIA_PROPRIETARY=""   # set to "yes" in install_packages if chosen; read by install_bootloader

detect_all() {
    is_x86_64 || die "This machine is not x86_64; mainline Arch is x86_64-only."
    FIRMWARE="$(detect_firmware)"
    UCODE="$(ucode_for_vendor "$(cpu_vendor)")"
    GPU="$(detect_gpu_vendor "$(lspci 2>/dev/null || true)")"
    GPU_PKGS="$(gpu_packages "$GPU")"
    RAM_KB="$(awk '/MemTotal/{print $2; exit}' /proc/meminfo)"
    if has_broadcom_wifi "$(lspci 2>/dev/null; lsusb 2>/dev/null)"; then
        BROADCOM=yes; else BROADCOM=no; fi
    ROOT_SRC="$(findmnt -no SOURCE "$MNT" 2>/dev/null || echo '?')"
    DISK="/dev/$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -1 || true)"
}

print_detection() {
    cat >&2 <<EOF
  firmware : $FIRMWARE
  ucode    : ${UCODE:-<none>}
  gpu      : $GPU  ->  $GPU_PKGS
  ram (kB) : $RAM_KB  (swap: $(needs_swap "$RAM_KB" && echo yes || echo no))
  broadcom : $BROADCOM
  target   : $MNT on $ROOT_SRC (disk $DISK)
EOF
}

preflight() {
    [[ $EUID -eq 0 ]] || die "Stage 1 must run as root in the live ISO."
    mountpoint -q "$MNT" || die "$MNT is not mounted. Partition/format/mount first."
    if [[ "$FIRMWARE" == uefi ]]; then
        mountpoint -q "$MNT/boot" || die "UEFI: mount the ESP at $MNT/boot before running (avoids kernel shadowing)."
    fi
    ping -c1 -W3 archlinux.org >/dev/null 2>&1 || warn "Network check failed; continuing but pacstrap may fail."
    say "Target disk for bootloader: $DISK"
    ask_yes_no "Install bootloader to $DISK?" y || die "Aborted at disk confirmation."
}

base_install() {
    say "Refreshing package databases"
    pacman -Sy --noconfirm
    say "pacstrap base system + microcode ($UCODE)"
    # shellcheck disable=SC2086
    pacstrap "$MNT" base base-devel linux linux-firmware linux-headers \
        git networkmanager wpa_supplicant sudo vim nano $UCODE
    genfstab -U "$MNT" >> "$MNT/etc/fstab"
}

configure_system() {
    say "A few questions coming up. Answer each one, or just hit Enter to accept the default shown in [brackets]."

    local hostnames=(meadow pebble willow comet hazel cricket breeze acorn lumen thistle sprout marigold)
    local usernames=(biscuit clover marble pixel waffle peanut ziggy mochi nova juniper ember momo)
    local default_host="${hostnames[RANDOM % ${#hostnames[@]}]}"
    local default_user="${usernames[RANDOM % ${#usernames[@]}]}"

    local host tz user
    host="$(ask_default 'Hostname' "$default_host")"
    tz="$(ask_default 'Timezone (Region/City)' 'America/New_York')"
    user="$(ask_default 'Username' "$default_user")"
    say "Set the ROOT password:"; local rootpw; rootpw="$(_read_secret)"
    say "Set the password for $user:"; local userpw; userpw="$(_read_secret)"

    HEVENOS_USER="$user"   # exported for later steps

    arch-chroot "$MNT" /bin/bash -euo pipefail <<CHROOT
ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime
hwclock --systohc || true
sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf
echo '$host' > /etc/hostname
mkinitcpio -P
echo 'root:$rootpw' | chpasswd
id -u '$user' >/dev/null 2>&1 || useradd -m -G wheel -s /usr/bin/fish '$user'
echo '$user:$userpw' | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
CHROOT

    # Username path fix across the (soon-to-be-extracted) config; done post-extract.
}

_read_secret() { local a b; read -rs a >&2; echo >&2; read -rs b >&2; echo >&2;
    [[ "$a" == "$b" ]] || die "Passwords did not match."; echo "$a"; }

install_bootloader() {
    local root_uuid; root_uuid="$(findmnt -no UUID "$MNT")"
    if [[ "$FIRMWARE" == uefi ]]; then
        arch-chroot "$MNT" bootctl install
        cat > "$MNT/boot/loader/loader.conf" <<EOF
default arch
timeout 3
EOF
        local extra_opts=""
        [[ "${NVIDIA_PROPRIETARY:-}" == yes ]] && extra_opts=" nvidia-drm.modeset=1"
        {
            echo "title   Arch Linux (hevenos)"
            echo "linux   /vmlinuz-linux"
            [[ -n "$UCODE" ]] && echo "initrd  /$UCODE.img"
            echo "initrd  /initramfs-linux.img"
            echo "options root=UUID=$root_uuid rw$extra_opts"
        } > "$MNT/boot/loader/entries/arch.conf"
    else
        arch-chroot "$MNT" grub-install --target=i386-pc "$DISK"
        arch-chroot "$MNT" grub-mkconfig -o /boot/grub/grub.cfg
    fi
}

enable_services() {
    arch-chroot "$MNT" systemctl enable NetworkManager wpa_supplicant chrony bluetooth acpid
    arch-chroot "$MNT" systemctl disable iwd 2>/dev/null || true
}

setup_swap() {
    needs_swap "$RAM_KB" || return 0
    say "Low RAM detected; creating 2 GiB swapfile"
    arch-chroot "$MNT" /bin/bash -euo pipefail <<'CHROOT'
fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
chmod 600 /swapfile
mkswap /swapfile
echo '/swapfile none swap defaults 0 0' >> /etc/fstab
CHROOT
}

install_list() { # path-to-list  label
    local list="$1" label="$2" repo avail
    repo="$(mktemp)"; arch-chroot "$MNT" pacman -Slq | sort -u > "$repo"
    avail="$(available_pkgs "$repo" "$list" | tr '\n' ' ')"
    say "Installing $label: $(wc -w <<<"$avail") packages"
    # shellcheck disable=SC2086
    [[ -n "${avail// }" ]] && arch-chroot "$MNT" pacman -S --needed --noconfirm $avail
    missing_pkgs "$repo" "$list" >> "$MNT/root/missing.txt"
    rm -f "$repo"
}

install_packages() {
    arch-chroot "$MNT" pacman -Sy --noconfirm
    : > "$MNT/root/missing.txt"
    install_list "$HERE/packages/core.txt" "core desktop"

    say "Graphics: $GPU"
    if [[ "$GPU" == nvidia ]]; then
        if ask_yes_no "NVIDIA: install proprietary driver instead of nouveau?" n; then
            GPU_PKGS="nvidia nvidia-utils"
            NVIDIA_PROPRIETARY=yes
            # kms modules for early modeset
            arch-chroot "$MNT" sed -i 's/^MODULES=(\(.*\))/MODULES=(\1 nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
            arch-chroot "$MNT" mkinitcpio -P
        fi
    fi
    # shellcheck disable=SC2086
    arch-chroot "$MNT" pacman -S --needed --noconfirm $GPU_PKGS

    for opt in fonts-extra security-tools asus; do
        if ask_yes_no "Install optional list '$opt'?" n; then
            install_list "$HERE/packages/optional/$opt.txt" "$opt"
            [[ "$opt" == asus ]] && touch "$MNT/home/$HEVENOS_USER/.hevenos-asus"
        fi
    done
}

deploy_payload() {
    local home="$MNT/home/$HEVENOS_USER"
    cp "$HERE/payload/desktop-env.tar.gz" "$home/"
    arch-chroot "$MNT" /bin/bash -euo pipefail <<CHROOT
cd /home/$HEVENOS_USER
sudo -u $HEVENOS_USER tar xzf desktop-env.tar.gz
rm -f desktop-env.tar.gz
CHROOT
    # Username path fix (three hardcoded /home/omniwing paths).
    if [[ "$HEVENOS_USER" != omniwing ]]; then
        arch-chroot "$MNT" /bin/bash -euo pipefail <<CHROOT
sed -i "s|/home/omniwing|/home/$HEVENOS_USER|g" \
    /home/$HEVENOS_USER/.config/niri/config.kdl \
    /home/$HEVENOS_USER/.config/fish/config.fish
CHROOT
    fi
    # Verify no stragglers remain.
    if arch-chroot "$MNT" grep -rl /home/omniwing "/home/$HEVENOS_USER/.config" 2>/dev/null | grep -q .; then
        warn "Some /home/omniwing paths remain — check manually."
    fi

    # Console login banner.
    install -Dm644 "$HERE/overlay/fish_greeting.fish" \
        "$home/.config/fish/functions/fish_greeting.fish"
    arch-chroot "$MNT" chown -R "$HEVENOS_USER:$HEVENOS_USER" "/home/$HEVENOS_USER/.config"
    arch-chroot "$MNT" chsh -s /usr/bin/fish "$HEVENOS_USER"
    arch-chroot "$MNT" sudo -u "$HEVENOS_USER" fc-cache -f || true
}

handoff() {
    cp "$HERE/stage2.sh" "$MNT/home/$HEVENOS_USER/"
    chmod +x "$MNT/home/$HEVENOS_USER/stage2.sh"
    mkdir -p "$MNT/home/$HEVENOS_USER/hevenos/packages/optional"
    cp "$HERE/packages/aur.txt" "$MNT/home/$HEVENOS_USER/hevenos/packages/"
    cp "$HERE/packages/optional/asus.txt" "$MNT/home/$HEVENOS_USER/hevenos/packages/optional/"
    [[ "$BROADCOM" == yes ]] && touch "$MNT/home/$HEVENOS_USER/.hevenos-broadcom"
    arch-chroot "$MNT" chown -R "$HEVENOS_USER:$HEVENOS_USER" "/home/$HEVENOS_USER"
    say "Stage 1 complete."
    printf '\033[1;31mSETUP IS NOT COMPLETE.\033[0m\n' >&2
    printf '\033[1;31mDo not remove the USB drive yet.\033[0m\n' >&2
    cat >&2 <<EOF

  Type: reboot

  If your BIOS/boot order defaults to the USB drive, you'll need to pull
  it so the machine boots the internal disk instead — but only once the
  screen goes black during the restart, never before. This live session
  is running FROM that USB; removing it any earlier can crash the system
  before reboot even starts, forcing you to redo this entire install.

  If the internal disk is already first in the boot order, you don't
  need to remove the USB at all — it'll just boot past it.

  Additional instructions will be provided after reboot.
EOF
}

main() {
    detect_all
    print_detection
    preflight
    base_install
    configure_system
    install_packages
    enable_services
    setup_swap
    install_bootloader
    deploy_payload
    handoff
}

case "${1:-}" in
    --detect) detect_all; print_detection ;;
    *)        main ;;
esac
