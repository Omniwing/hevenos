# shellcheck shell=bash
_storage_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$_storage_root/install.sh"

test_setup_swap_uses_only_prepared_target_partition() {
    local original_target original_whole
    original_target="$(declare -f target_swap_partition)"
    original_whole="$(declare -f whole_disk_for)"
    MNT="$(mktemp -d)"
    mkdir -p "$MNT/etc"
    : > "$MNT/etc/fstab"
    local calls="$MNT/calls"

    target_swap_partition() { printf '/dev/fake-target-swap\n'; }
    whole_disk_for() { printf '/dev/fake-target-disk\n'; }
    blkid() { printf '11111111-2222-3333-4444-555555555555\n'; }
    lsblk() { printf '1048576\n'; }
    swapon() { printf 'swapon %s\n' "$*" >> "$calls"; }
    arch-chroot() { printf 'unexpected arch-chroot\n' >> "$calls"; return 1; }

    setup_swap >/dev/null 2>&1
    assert_true grep -q '^UUID=11111111-2222-3333-4444-555555555555 none swap defaults,discard=once 0 0$' "$MNT/etc/fstab"
    assert_true grep -q '^swapon --discard=once /dev/fake-target-swap$' "$calls"
    assert_false grep -q 'unexpected arch-chroot' "$calls"
    assert_eq "$(awk '$3 == "swap" { n++ } END { print n+0 }' "$MNT/etc/fstab")" \
        "1" "exactly one target swap entry is written"

    unset -f target_swap_partition whole_disk_for blkid lsblk swapon arch-chroot
    eval "$original_target"
    eval "$original_whole"
    rm -rf "$MNT"
}

test_base_install_filters_host_swap_from_genfstab() {
    # The test deliberately matches a literal $MNT.
    # shellcheck disable=SC2016
    assert_true grep -q 'genfstab -U -f "\$MNT" "\$MNT"' "$_storage_root/install.sh"
}

test_installer_enables_periodic_trim() {
    assert_true grep -q 'systemctl enable fstrim.timer' "$_storage_root/install.sh"
}
