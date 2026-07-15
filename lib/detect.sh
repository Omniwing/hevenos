# Pure hardware-detection helpers. Each accepts an injectable argument (for
# tests) and falls back to a live probe when called with none.

is_x86_64() {
    local arch="${1:-$(uname -m)}"
    [[ "$arch" == "x86_64" ]]
}

detect_firmware() {
    local size_path="${1:-/sys/firmware/efi/fw_platform_size}"
    if [[ -e "$size_path" ]]; then echo uefi; else echo bios; fi
}

cpu_vendor() { awk -F': ' '/^vendor_id/{print $2; exit}' /proc/cpuinfo; }

ucode_for_vendor() {
    case "$1" in
        GenuineIntel) echo intel-ucode ;;
        AuthenticAMD) echo amd-ucode ;;
        *)            echo "" ;;
    esac
}

detect_gpu_vendor() {
    local out="$1"
    if   grep -qi 'nvidia' <<<"$out"; then echo nvidia
    elif grep -qiE 'amd|\bati\b|radeon' <<<"$out"; then echo amd
    elif grep -qi 'intel' <<<"$out"; then echo intel
    else echo other; fi
}

gpu_packages() {
    case "$1" in
        intel)  echo "mesa vulkan-intel intel-media-driver" ;;
        amd)    echo "mesa vulkan-radeon libva-mesa-driver" ;;
        nvidia) echo "mesa" ;;   # nouveau (in-kernel DRM + mesa GL) is the default
        *)      echo "mesa" ;;
    esac
}

has_broadcom_wifi() {
    grep -qiE 'broadcom.*(bcm43|802\.11|wireless)|BCM43[0-9]' <<<"$1"
}

needs_swap() {
    local ram_kb="$1" threshold_kb="${2:-2097152}"
    [[ "$ram_kb" -le "$threshold_kb" ]]
}

is_asus_hardware() {
    # ${1-...}, no colon: an explicitly passed empty string (as tests do)
    # must NOT fall through to the live probe — only an omitted arg should.
    local vendor="${1-$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)}"
    grep -qi 'asus' <<<"$vendor"
}
