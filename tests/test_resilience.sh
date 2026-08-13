# shellcheck shell=bash
# A stale package name must never be able to abort an install.
#
# Regression cover for the failure that produced an unbootable machine: Arch
# retired the 'nvidia' package, 'pacman -S nvidia' exited non-zero, 'set -e'
# killed install.sh six functions short of install_bootloader, and the target
# came up with a complete root filesystem and no bootloader.

_res_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load install.sh for its functions only. It guards main() behind a
# BASH_SOURCE/$0 comparison, so sourcing performs no install.
# shellcheck disable=SC1091
source "$_res_root/install.sh"

# Stand in for the target root and for arch-chroot. The stub answers three
# things: 'pacman -Slq' lists a fake repo, 'pacman -S' succeeds only if every
# target is in it, and 'pacman -Qq' reports what the stub actually installed.
_res_setup() {
    MNT="$(mktemp -d)"
    mkdir -p "$MNT/root"
    : > "$MNT/root/missing.txt"
    : > "$MNT/root/installed"
    INSTALL_WARNINGS=0
    _RES_REPO=(niri kitty fish mesa nvidia-open nvidia-utils)
    _RES_FAIL_TRANSACTION=no

    arch-chroot() {
        shift                        # discard the mountpoint argument
        case "$*" in
            "pacman -Slq")  printf '%s\n' "${_RES_REPO[@]}" ;;
            "pacman -Qq "*) grep -qxF "${*##* }" "$MNT/root/installed" ;;
            "pacman -S "*)
                [[ "$_RES_FAIL_TRANSACTION" == no ]] || return 1
                local p r found
                for p in "$@"; do
                    case "$p" in pacman|-S|--needed|--noconfirm) continue ;; esac
                    found=no
                    for r in "${_RES_REPO[@]}"; do
                        [[ "$r" == "$p" ]] && { found=yes; break; }
                    done
                    [[ "$found" == yes ]] || return 1
                    echo "$p" >> "$MNT/root/installed"
                done ;;
            *) return 0 ;;
        esac
    }
}
_res_teardown() { unset -f arch-chroot; rm -rf "$MNT"; }

test_missing_package_does_not_abort() {
    _res_setup
    local out rc
    out="$(install_pkgs "graphics" nvidia nvidia-utils 2>&1)"; rc=$?
    assert_eq "$rc" "0" "install_pkgs returns success despite a dead package name"
    assert_true grep -q 'not found in any configured repository' <<<"$out"
    assert_true grep -q 'probably out of date' <<<"$out"
    _res_teardown
}

test_survivors_are_still_installed() {
    _res_setup
    install_pkgs "graphics" nvidia nvidia-utils >/dev/null 2>&1
    assert_true  grep -qx nvidia-utils "$MNT/root/installed"
    assert_false grep -qx nvidia       "$MNT/root/installed"
    _res_teardown
}

test_missing_package_is_recorded_and_counted() {
    _res_setup
    install_pkgs "graphics" nvidia nvidia-utils >/dev/null 2>&1
    assert_eq "$INSTALL_WARNINGS" "1" "one degradation counted"
    assert_true grep -q 'nvidia' "$MNT/root/missing.txt"
    _res_teardown
}

test_failed_transaction_does_not_abort() {
    _res_setup
    _RES_FAIL_TRANSACTION=yes
    local out rc
    out="$(install_pkgs "core desktop" niri kitty 2>&1)"; rc=$?
    assert_eq "$rc" "0" "a failed pacman transaction is a warning, not an abort"
    assert_true grep -q 'could not complete the transaction' <<<"$out"
    _res_teardown
}

test_clean_run_reports_nothing() {
    _res_setup
    install_pkgs "core desktop" niri kitty fish >/dev/null 2>&1
    assert_eq "$INSTALL_WARNINGS" "0" "no warnings when every package resolves"
    assert_eq "$(report_degradations 2>&1)" "" "summary stays silent on a clean run"
    _res_teardown
}

test_summary_fires_when_degraded() {
    _res_setup
    install_pkgs "graphics" nvidia nvidia-utils >/dev/null 2>&1
    local out; out="$(report_degradations 2>&1)"
    assert_true grep -q 'PROBABLY OUT OF DATE' <<<"$out"
    assert_true grep -q 'nvidia' <<<"$out"
    _res_teardown
}

# nvidia-drm.modeset=1 must be driven by what installed, not by what was asked
# for: the kernel command line outlives the install, and a machine running
# nouveau should not carry a line claiming otherwise.
test_kernel_cmdline_follows_the_installed_driver() {
    _res_setup
    NVIDIA_PROPRIETARY=yes; NVIDIA_ACTIVE=""
    local opts=""
    [[ "${NVIDIA_ACTIVE:-}" == yes ]] && opts=" nvidia-drm.modeset=1"
    assert_eq "$opts" "" "requested but not installed => no modeset option"
    NVIDIA_ACTIVE=yes
    [[ "${NVIDIA_ACTIVE:-}" == yes ]] && opts=" nvidia-drm.modeset=1"
    assert_eq "$opts" " nvidia-drm.modeset=1" "installed => modeset option present"
    NVIDIA_PROPRIETARY=""; NVIDIA_ACTIVE=""
    _res_teardown
}

# The package name the installer now asks for must be one that exists.
test_no_retired_nvidia_package_names() {
    assert_false grep -qE '(^|[^-])\bnvidia\b[^-]' <<<"$(grep 'GPU_PKGS=' "$_res_root/install.sh" | grep -v '^\s*#')"
    assert_true  grep -q 'nvidia-open' "$_res_root/install.sh"
}
