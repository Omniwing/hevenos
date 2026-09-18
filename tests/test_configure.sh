# shellcheck shell=bash
_cfg_script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/configure"

_cfg_call() { # shell fragment
    bash -c 'source "$1"; eval "$2"' _ "$_cfg_script" "$1"
}

test_configure_swap_sizing() {
    assert_eq "$(_cfg_call 'cfg_swap_size_mib 1048576 100000')" "4096" \
        "1 GiB RAM gets the 4 GiB swap floor"
    assert_eq "$(_cfg_call 'cfg_swap_size_mib 6291456 100000')" "6144" \
        "6 GiB RAM gets 6 GiB swap"
    assert_eq "$(_cfg_call 'cfg_swap_size_mib 67108864 100000')" "8192" \
        "large RAM is capped at 8 GiB swap"
    assert_eq "$(_cfg_call 'cfg_swap_size_mib 67108864 30517')" "4096" \
        "small disks reduce swap to preserve a 24 GiB root"
    assert_false _cfg_call 'cfg_swap_size_mib 1048576 29697'
}

test_configure_confirmations_are_exact() {
    assert_true  _cfg_call 'cfg_capital_y Y'
    assert_false _cfg_call 'cfg_capital_y y'
    assert_false _cfg_call 'cfg_capital_y yes'
    assert_true  _cfg_call 'cfg_final_confirm CONFIRM'
    assert_false _cfg_call 'cfg_final_confirm confirm'
    assert_false _cfg_call 'cfg_final_confirm " CONFIRM"'
}

test_configure_protects_usb_even_when_not_removable() {
    assert_true _cfg_call 'cfg_usb_or_removable_evidence usb 0 /sys/devices/pci ""'
    assert_true _cfg_call 'cfg_usb_or_removable_evidence "" 0 /sys/devices/pci/usb1/1-1 ""'
    assert_true _cfg_call 'cfg_usb_or_removable_evidence "" 0 /sys/devices/pci "ID_BUS=usb"'
    assert_true _cfg_call 'cfg_usb_or_removable_evidence "" 1 /sys/devices/mmc ""'
    assert_false _cfg_call 'cfg_usb_or_removable_evidence sata 0 /sys/devices/pci "ID_BUS=ata"'
}

test_configure_preflight_succeeds_on_a_ready_machine() {
    # Regression: cfg_preflight used to end in 'cfg_mounts_under_target && die'.
    # On a healthy machine nothing is mounted at $MNT, so that list -- and with
    # it the whole function -- returned 1, 'set -e' killed configure inside
    # main, and the ERR trap printed nothing because no disk had been touched
    # yet. ./configure did nothing at all, with no output and no explanation.
    local out
    out="$(_cfg_call '
        cfg_running_as_root() { return 0; }
        cfg_has_terminal() { return 0; }
        cfg_on_live_iso() { return 0; }
        cfg_require_commands() { return 0; }
        is_x86_64() { return 0; }
        detect_firmware() { echo uefi; }
        gpu_below_gl_floor() { return 1; }
        MNT=/no-such-hevenos-target
        cfg_preflight
        echo PREFLIGHT_RETURNED
    ' 2>&1 || true)"
    assert_eq "$out" "PREFLIGHT_RETURNED" \
        "cfg_preflight returns success, silently, when the machine is ready to install"
}

test_configure_is_source_safe() {
    assert_eq "$(bash -c 'source "$1"' _ "$_cfg_script")" "" \
        "sourcing configure does not run disk discovery or prompts"
}
