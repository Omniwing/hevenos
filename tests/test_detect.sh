source "$(dirname "${BASH_SOURCE[0]}")/../lib/detect.sh"

test_is_x86_64() {
    assert_true  is_x86_64 x86_64
    assert_false is_x86_64 i686
    assert_false is_x86_64 aarch64
}

test_detect_firmware() {
    tmp="$(mktemp)"; touch "$tmp"
    assert_eq "$(detect_firmware "$tmp")" "uefi" "existing efi size file => uefi"
    rm -f "$tmp"
    assert_eq "$(detect_firmware "/nonexistent/efi/size")" "bios" "missing => bios"
}

test_ucode_for_vendor() {
    assert_eq "$(ucode_for_vendor GenuineIntel)" "intel-ucode" "intel"
    assert_eq "$(ucode_for_vendor AuthenticAMD)" "amd-ucode" "amd"
    assert_eq "$(ucode_for_vendor SomethingElse)" "" "unknown => empty"
}

test_detect_gpu_vendor() {
    assert_eq "$(detect_gpu_vendor 'VGA compatible controller: Intel Corporation Atom')" intel "intel"
    assert_eq "$(detect_gpu_vendor 'VGA compatible controller: Advanced Micro Devices AMD/ATI Radeon')" amd "amd"
    assert_eq "$(detect_gpu_vendor 'VGA compatible controller: NVIDIA Corporation GK107')" nvidia "nvidia"
    # Hybrid Intel + NVIDIA laptop: NVIDIA wins
    assert_eq "$(detect_gpu_vendor 'Intel Corporation UHD Graphics
NVIDIA Corporation GP108M')" nvidia "hybrid => nvidia"
    assert_eq "$(detect_gpu_vendor 'Red Hat, Inc. Virtio GPU')" other "vm => other"
    assert_eq "$(detect_gpu_vendor 'VGA compatible controller: ATI Technologies Inc Rage 128 Pro')" amd "bare ATI whole-word => amd"
}

test_gpu_packages() {
    assert_eq "$(gpu_packages intel)"  "mesa vulkan-intel intel-media-driver" "intel pkgs"
    assert_eq "$(gpu_packages amd)"    "mesa vulkan-radeon libva-mesa-driver" "amd pkgs"
    assert_eq "$(gpu_packages nvidia)" "mesa" "nvidia default => nouveau via mesa"
    assert_eq "$(gpu_packages other)"  "mesa" "fallback => mesa"
}

test_has_broadcom_wifi() {
    assert_true  has_broadcom_wifi 'Network controller: Broadcom Inc. BCM4312 802.11b/g LP-PHY'
    assert_false has_broadcom_wifi 'Network controller: Intel Corporation Wireless 7260'
}

test_needs_swap() {
    assert_true  needs_swap 1048576          # 1 GiB
    assert_true  needs_swap 2097152          # exactly 2 GiB
    assert_false needs_swap 8388608          # 8 GiB
    assert_true  needs_swap 4194304 8388608  # custom threshold
}

test_is_asus_hardware() {
    assert_true  is_asus_hardware "ASUSTeK COMPUTER INC."
    assert_true  is_asus_hardware "asus"
    assert_false is_asus_hardware "Hewlett-Packard"
    assert_false is_asus_hardware "Dell Inc."
    assert_false is_asus_hardware ""
}
