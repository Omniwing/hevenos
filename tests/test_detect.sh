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

test_find_esp() {
    # Fixtures are `lsblk -rno PATH,PARTTYPE,RM,MOUNTPOINT` output verbatim:
    # single-space separated, empty values left empty.
    local esp=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
    local linux=0fc63daf-8483-4772-8e79-3d69d8477de4

    assert_eq "$(find_esp "/dev/sda  0
/dev/sda1 $esp 0
/dev/sda2 $linux 0 /mnt")" "/dev/sda1" "the one free ESP"

    # Already mounted — the operator is using it for something.
    assert_eq "$(find_esp "/dev/sda1 $esp 0 /boot/efi")" "" "mounted ESP is not free"

    # The live USB this installer is running from carries an ESP of its own.
    assert_eq "$(find_esp "/dev/sdb1 $esp 1")" "" "removable ESP is skipped"

    assert_eq "$(find_esp "/dev/sda1 $esp 0
/dev/nvme0n1p1 $esp 0")" "/dev/sda1
/dev/nvme0n1p1" "two free ESPs => two lines, caller decides"

    assert_eq "$(find_esp "/dev/sda1 $linux 0
/dev/sda2 $linux 0")" "" "no ESP anywhere"

    assert_eq "$(find_esp "/dev/sda1 ${esp^^} 0")" "/dev/sda1" "type GUID is case-insensitive"

    # Explicitly empty input must not fall through to a live lsblk probe.
    assert_eq "$(find_esp "")" "" "empty input => empty, no live probe"
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

test_gpu_below_gl_floor() {
    # The 2010 HP netbook (Pineview / GMA 3150) — the machine that taught us
    assert_true gpu_below_gl_floor '00:02.0 VGA compatible controller [0300]: Intel Corporation Atom Processor D4xx/D5xx/N4xx/N5xx Integrated Graphics Controller [8086:a011]'
    assert_true gpu_below_gl_floor '00:02.0 VGA compatible controller [0300]: Intel Corporation Mobile 945GM/GMS, 943/940GML Express Integrated Graphics Controller [8086:27a2] (rev 03)'
    assert_true gpu_below_gl_floor '00:02.0 VGA compatible controller [0300]: Intel Corporation System Controller Hub (SCH Poulsbo) Graphics Controller [8086:8108] (rev 07)'
    assert_true gpu_below_gl_floor '00:02.0 VGA compatible controller [0300]: Intel Corporation Atom Processor D2xxx/N2xxx Integrated Graphics Controller [8086:0be1] (rev 09)'
    # At or above the floor — must NOT trip
    assert_false gpu_below_gl_floor '00:02.0 VGA compatible controller [0300]: Intel Corporation 2nd Generation Core Processor Family Integrated Graphics Controller [8086:0116] (rev 09)'
    assert_false gpu_below_gl_floor '00:02.0 VGA compatible controller [0300]: Intel Corporation Iris Xe Graphics [8086:9a49] (rev 01)'
    assert_false gpu_below_gl_floor '01:00.0 VGA compatible controller [0300]: NVIDIA Corporation GP108M [GeForce MX150] [10de:1d10] (rev a1)'
    assert_false gpu_below_gl_floor '00:01.0 VGA compatible controller [0300]: Advanced Micro Devices, Inc. [AMD/ATI] Picasso/Raven 2 [1002:15d8]'
    # Pineview HOST BRIDGE (a010) alongside nothing else must not match
    assert_false gpu_below_gl_floor '00:00.0 Host bridge [0600]: Intel Corporation Atom Processor D4xx/D5xx/N4xx/N5xx DMI Bridge [8086:a010]'
    assert_false gpu_below_gl_floor ''
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
