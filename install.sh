#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/ui.sh"
source "$HERE/lib/detect.sh"
source "$HERE/lib/packages.sh"

MNT="${HEVENOS_MNT:-/mnt}"
NVIDIA_PROPRIETARY=""   # set to "yes" in collect_config if chosen; read by install_packages/install_bootloader

detect_all() {
    is_x86_64 || die "This machine is not x86_64; mainline Arch is x86_64-only."
    FIRMWARE="$(detect_firmware)"
    UCODE="$(ucode_for_vendor "$(cpu_vendor)")"
    GPU="$(detect_gpu_vendor "$(lspci 2>/dev/null || true)")"
    GPU_PKGS="$(gpu_packages "$GPU")"
    if gpu_below_gl_floor "$(lspci -nn 2>/dev/null || true)"; then
        GL_FLOOR=below; else GL_FLOOR=ok; fi
    RAM_KB="$(awk '/MemTotal/{print $2; exit}' /proc/meminfo)"
    if has_broadcom_wifi "$(lspci 2>/dev/null; lsusb 2>/dev/null)"; then
        BROADCOM=yes; else BROADCOM=no; fi
    if is_asus_hardware; then ASUS=yes; else ASUS=no; fi
    ROOT_SRC="$(findmnt -no SOURCE "$MNT" 2>/dev/null || echo '?')"
    DISK="/dev/$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -1 || true)"
}

print_detection() {
    cat >&2 <<EOF
  firmware : $FIRMWARE
  ucode    : ${UCODE:-<none>}
  gpu      : $GPU  ->  $GPU_PKGS
  gl floor : $GL_FLOOR
  ram (kB) : $RAM_KB  (swap: $(needs_swap "$RAM_KB" && echo yes || echo no))
  broadcom : $BROADCOM
  asus     : $ASUS
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
    if [[ "$GL_FLOOR" == below ]]; then
        die "This GPU is below the supported hardware floor (OpenGL 3.3-class needed — roughly Intel HD 3000 / 2011 or newer; see README). kitty hard-requires OpenGL 3.3 and niri's theme shaders exceed this chip's limits. Unsupported — no install possible on this hardware."
    fi
    if [[ "$FIRMWARE" == bios ]]; then
        [[ -b "$DISK" ]] || die "Could not determine a valid disk for GRUB (got '$DISK'). Check that $MNT is mounted on a real partition, then rerun."
    fi
    say "Target disk for bootloader: $DISK"
    ask_yes_no "Install bootloader to $DISK?" y || die "Aborted at disk confirmation."
}

base_install() {
    say "Refreshing package databases"
    pacman -Sy --noconfirm
    say "pacstrap base system + microcode ($UCODE)"
    local bootloader_pkg=""
    [[ "$FIRMWARE" == bios ]] && bootloader_pkg="grub"
    # shellcheck disable=SC2086
    pacstrap "$MNT" base base-devel linux linux-firmware linux-headers \
        git networkmanager wpa_supplicant sudo vim nano $UCODE $bootloader_pkg
    genfstab -U "$MNT" >> "$MNT/etc/fstab"
}

collect_config() {
    # Prompts only — no arch-chroot here, so this can run before base_install
    # has even pacstrapped a filesystem to chroot into. Keeping every
    # question (this function + the NVIDIA choice below) front-loaded means
    # the operator answers everything once, up front, then the rest of the
    # install runs unattended instead of stalling mid-run for input.
    say "A few questions coming up. Answer each one, or just hit Enter to accept the default shown in [brackets]."

    local hostnames=(meadow pebble willow comet hazel cricket breeze acorn lumen thistle sprout marigold)
    local usernames=(biscuit clover marble pixel waffle peanut ziggy mochi nova juniper ember momo)
    local default_host="${hostnames[RANDOM % ${#hostnames[@]}]}"
    local default_user="${usernames[RANDOM % ${#usernames[@]}]}"

    CFG_HOST="$(ask_default 'Hostname' "$default_host")"
    CFG_TZ="$(ask_default 'Timezone (Region/City)' 'America/New_York')"
    CFG_USER="$(ask_default 'Username' "$default_user")"
    CFG_ROOTPW="$(_read_secret 'root password')"
    CFG_USERPW="$(_read_secret "password for $CFG_USER")"

    HEVENOS_USER="$CFG_USER"   # exported for later steps

    if [[ "$GPU" == nvidia ]] && ask_yes_no "NVIDIA: install proprietary driver instead of nouveau?" n; then
        NVIDIA_PROPRIETARY=yes
    fi
}

apply_config() {
    local host="$CFG_HOST" tz="$CFG_TZ" user="$CFG_USER"
    # Config values are passed as positional parameters ($1..$3) to a *quoted*
    # here-doc (bash -s), never string-interpolated into it. A value with shell
    # metacharacters — a single quote, $, backtick, space — therefore can't
    # break the chroot script or be executed inside it. (Passwords are handled
    # separately below, straight into chpasswd's stdin as data.)
    arch-chroot "$MNT" /bin/bash -euo pipefail -s "$host" "$tz" "$user" <<'CHROOT'
host="$1"; tz="$2"; user="$3"
ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime
hwclock --systohc || true
sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf
echo 'KEYMAP=us' > /etc/vconsole.conf
echo "MAKEFLAGS=\"-j$(nproc)\"" >> /etc/makepkg.conf
echo "$host" > /etc/hostname
mkinitcpio -P
id -u "$user" >/dev/null 2>&1 || useradd -m -G wheel "$user"
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
CHROOT

    # Passwords never touch the shell as text: fed to chpasswd on stdin as
    # data, so any character (including ' $ ` and spaces) is safe.
    printf 'root:%s\n' "$CFG_ROOTPW"       | arch-chroot "$MNT" chpasswd
    printf '%s:%s\n'  "$user" "$CFG_USERPW" | arch-chroot "$MNT" chpasswd
}

_read_secret() { # label
    local label="$1" a b
    while true; do
        printf '  Enter %s: ' "$label" >&2; read -rs a >&2; echo >&2
        printf '  Confirm %s: ' "$label" >&2; read -rs b >&2; echo >&2
        [[ "$a" == "$b" ]] && { echo "$a"; return; }
        warn "Passwords did not match. Try again."
    done
}

install_bootloader() {
    say "Installing bootloader ($FIRMWARE)"
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
        if [[ "${NVIDIA_PROPRIETARY:-}" == yes ]]; then
            arch-chroot "$MNT" sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 nvidia-drm.modeset=1"/' /etc/default/grub
        fi
        arch-chroot "$MNT" grub-install --target=i386-pc "$DISK"
        arch-chroot "$MNT" grub-mkconfig -o /boot/grub/grub.cfg
    fi
}

enable_services() {
    say "Enabling system services"
    local svc
    for svc in NetworkManager wpa_supplicant chronyd bluetooth acpid keyd; do
        arch-chroot "$MNT" systemctl enable "$svc" 2>/dev/null \
            || warn "Could not enable $svc.service — its package may not have installed (check missing.txt on the target)."
    done
    arch-chroot "$MNT" systemctl disable iwd 2>/dev/null || true
}

configure_keyd() {
    # capslock -> leftmeta: capslock doubles as an extra Super/Mod key for
    # niri's keybinds. This is a systemd-managed /etc file, not part of the
    # home-relative desktop-env tarball, so it has to be recreated here
    # explicitly on every target — same category of gap as the getty
    # autologin drop-in.
    say "Configuring keyd (capslock as an extra Super key)"
    install -Dm644 "$HERE/overlay/keyd-default.conf" "$MNT/etc/keyd/default.conf"
}

migrate_wifi_credentials() {
    # The Arch live ISO connects to wifi via iwd (iwctl), not
    # NetworkManager — those saved credentials never make it onto the
    # target otherwise, so it boots with zero known networks even though
    # the live session connected fine. Migrate any saved iwd profile
    # directly into NetworkManager's keyfile format so the target can
    # auto-connect immediately on first real boot, same as ethernet
    # already does with no extra step. Only covers WPA/WPA2-personal
    # (iwd's .psk profiles) — the common case; anything else (enterprise
    # wifi, open networks) falls through to stage2.sh's nmtui fallback.
    shopt -s nullglob
    local profile ssid key uuid found=0
    for profile in /var/lib/iwd/*.psk; do
        found=1
        ssid="$(basename "$profile" .psk)"
        key="$(awk -F= '/^PreSharedKey=/{print $2; exit}' "$profile")"
        [[ -n "$key" ]] || key="$(awk -F= '/^Passphrase=/{print $2; exit}' "$profile")"
        [[ -n "$key" ]] || continue
        uuid="$(cat /proc/sys/kernel/random/uuid)"
        mkdir -p "$MNT/etc/NetworkManager/system-connections"
        cat > "$MNT/etc/NetworkManager/system-connections/$ssid.nmconnection" <<EOF
[connection]
id=$ssid
uuid=$uuid
type=wifi

[wifi]
mode=infrastructure
ssid=$ssid

[wifi-security]
key-mgmt=wpa-psk
psk=$key

[ipv4]
method=auto

[ipv6]
method=auto
EOF
        chmod 600 "$MNT/etc/NetworkManager/system-connections/$ssid.nmconnection"
        say "Migrated saved wifi network '$ssid' to the installed system"
    done
    shopt -u nullglob
    [[ "$found" == 1 ]] || return 0
}

setup_swap() {
    if ! needs_swap "$RAM_KB"; then
        say "Enough RAM detected; skipping swapfile"
        return 0
    fi
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
    # Full upgrade, not just a database sync: pacstrap's own pacman/libalpm
    # can lag behind by the time stage 2 tries to run a prebuilt paru-bin
    # binary against it, causing an ABI mismatch (libalpm.so.N not found).
    # Arch's own guidance is to never partial-upgrade a system.
    arch-chroot "$MNT" pacman -Syu --noconfirm
    : > "$MNT/root/missing.txt"
    install_list "$HERE/packages/core.txt" "core desktop"

    say "Graphics: $GPU"
    [[ "${NVIDIA_PROPRIETARY:-}" == yes ]] && GPU_PKGS="nvidia nvidia-utils"
    # shellcheck disable=SC2086
    arch-chroot "$MNT" pacman -S --needed --noconfirm $GPU_PKGS

    if [[ "${NVIDIA_PROPRIETARY:-}" == yes ]]; then
        # kms modules for early modeset — must run after the nvidia package
        # above actually provides the .ko files, or mkinitcpio silently
        # builds an initramfs without them.
        arch-chroot "$MNT" sed -i 's/^MODULES=(\(.*\))/MODULES=(\1 nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
        arch-chroot "$MNT" mkinitcpio -P
    fi

    if [[ "$ASUS" == yes ]]; then
        say "ASUS hardware detected — installing asus packages"
        install_list "$HERE/packages/optional/asus.txt" "asus"
        touch "$MNT/home/$HEVENOS_USER/.hevenos-asus"
    fi
}

deploy_payload() {
    say "Deploying desktop configuration"
    local home="$MNT/home/$HEVENOS_USER"
    cp "$HERE/payload/desktop-env.tar.gz" "$home/"
    arch-chroot "$MNT" /bin/bash -euo pipefail <<CHROOT
cd /home/$HEVENOS_USER
sudo -u $HEVENOS_USER tar xzf desktop-env.tar.gz
rm -f desktop-env.tar.gz
CHROOT
    # The config ships with no hardcoded home paths: niri/fish reference
    # $HOME (expanded at runtime via the login shell / spawned bash -c), so
    # the desktop works for whatever username was chosen with no rewriting.

    # Console login banner.
    install -Dm644 "$HERE/overlay/fish_greeting.fish" \
        "$home/.config/fish/functions/fish_greeting.fish"
    arch-chroot "$MNT" chown -R "$HEVENOS_USER:$HEVENOS_USER" "/home/$HEVENOS_USER/.config"

    # Make sure fish is actually registered as a valid login shell before
    # asking chsh to set it — don't rely solely on fish's own install hook.
    arch-chroot "$MNT" bash -c "grep -qxF /usr/bin/fish /etc/shells || echo /usr/bin/fish >> /etc/shells"
    if ! arch-chroot "$MNT" chsh -s /usr/bin/fish "$HEVENOS_USER"; then
        warn "Could not set fish as the login shell for $HEVENOS_USER — it will log in with the default shell instead."
    fi
    arch-chroot "$MNT" sudo -u "$HEVENOS_USER" fc-cache -f || true

    # Fallback auto-continue for bash, in case fish never became the login
    # shell above (or the fish greeting never fires for some other reason
    # specific to this hardware's console/getty setup) — same behavior,
    # shell-agnostic, so first-boot setup completion doesn't depend on a
    # single mechanism.
    cat >> "$home/.bash_profile" <<'BASHRC'

if [ -e "$HOME/stage2.sh" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    echo "  >> Setup isn't finished — finishing it automatically now."
    echo "  >> This installs AUR packages and can take a while on slow hardware."
    "$HOME/stage2.sh"
    if [ -e "$HOME/stage2.sh" ]; then
        echo "  >> automatic setup didn't finish — it will retry at your next login"
    else
        echo "  >> type 'niri' to start the desktop"
    fi
fi
BASHRC
    arch-chroot "$MNT" chown "$HEVENOS_USER:$HEVENOS_USER" "/home/$HEVENOS_USER/.bash_profile"
}

handoff() {
    cp "$HERE/stage2.sh" "$MNT/home/$HEVENOS_USER/"
    chmod +x "$MNT/home/$HEVENOS_USER/stage2.sh"
    mkdir -p "$MNT/home/$HEVENOS_USER/hevenos/packages/optional"
    cp "$HERE/packages/aur.txt" "$MNT/home/$HEVENOS_USER/hevenos/packages/"
    cp "$HERE/packages/optional/asus.txt" "$MNT/home/$HEVENOS_USER/hevenos/packages/optional/"
    [[ "$BROADCOM" == yes ]] && touch "$MNT/home/$HEVENOS_USER/.hevenos-broadcom"
    arch-chroot "$MNT" chown -R "$HEVENOS_USER:$HEVENOS_USER" "/home/$HEVENOS_USER"

    # Temporary passwordless sudo for the stage-2 AUR build window only.
    # makepkg -si calls sudo internally; stage2.sh runs unattended right
    # at login, so a password prompt with nobody there to answer it just
    # times out and kills the whole run. stage2.sh revokes this on any exit
    # (an EXIT trap, so a failed build can't leave it behind) — everyday sudo
    # stays password-protected once setup is actually done.
    cat > "$MNT/etc/sudoers.d/99-hevenos-stage2" <<EOF
$HEVENOS_USER ALL=(ALL:ALL) NOPASSWD: ALL
EOF
    chmod 0440 "$MNT/etc/sudoers.d/99-hevenos-stage2"
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
    collect_config
    base_install
    apply_config
    install_packages
    enable_services
    configure_keyd
    migrate_wifi_credentials
    setup_swap
    install_bootloader
    deploy_payload
    handoff
}

case "${1:-}" in
    --detect) detect_all; print_detection ;;
    *)        main ;;
esac
