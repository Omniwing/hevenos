# shellcheck shell=bash
# Stage 2 ran as a user's very first login and died on the first package it
# could not install, leaving stage2.sh in place to do exactly the same thing
# at every login afterwards. These cover the three ways that happened.
#
# stage2.sh guards main() behind a BASH_SOURCE/$0 comparison, so sourcing it
# defines the functions without running an install.
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/stage2.sh"

_stage2_setup() {
    _S2="$(mktemp -d)"
    HOME_DIR="$_S2"
    PKGS="$_S2/packages"
    mkdir -p "$PKGS/optional"
    PKG_FAILED=()
    _S2_CALLS="$_S2/calls"
    : > "$_S2_CALLS"

    # Defaults: nothing is installed, nothing is in the official repos, and
    # the AUR serves an empty repository — the asusctl-debug case.
    _S2_INSTALLED=""
    _S2_OFFICIAL=""
    # SC2032: a real 'sudo pacman' could not reach a shell function, but the
    # sudo below is a stub too, so the call is recorded rather than executed.
    # shellcheck disable=SC2032
    pacman() {
        printf 'pacman %s\n' "$*" >> "$_S2_CALLS"
        case "$1" in
            -Qi) grep -qw "$2" <<<"$_S2_INSTALLED" ;;
            -Si) grep -qw "$2" <<<"$_S2_OFFICIAL" ;;
            *)   return 0 ;;
        esac
    }
    sudo() {
        printf 'sudo %s\n' "$*" >> "$_S2_CALLS"
        [[ "$1" == pacman ]] && return 0
        return 0
    }
    git() {   # clone into an existing-but-empty directory, as the AUR does
        printf 'git %s\n' "$*" >> "$_S2_CALLS"
        mkdir -p "${*##* }"
    }
    makepkg() { printf 'makepkg %s\n' "$*" >> "$_S2_CALLS"; }
}

_stage2_teardown() {
    unset -f pacman sudo git makepkg
    rm -rf "$_S2"
}

_stage2_called() { grep -q "$1" "$_S2_CALLS"; }
_stage2_quiet()  { "$@" >/dev/null 2>&1; }

test_stage2_prefers_the_official_repositories_over_the_aur() {
    # asusctl, rog-control-center and broadcom-wl-dkms all moved from the AUR
    # into extra. The AUR keeps the old repository around but empty, so
    # cloning first turns an official package into a hard failure.
    _stage2_setup
    _S2_OFFICIAL="asusctl"
    assert_true _stage2_quiet install_aur_pkg asusctl
    assert_true  _stage2_called 'sudo pacman -S --needed --noconfirm asusctl'
    assert_false _stage2_called 'git clone'
    assert_false _stage2_called 'makepkg'
    _stage2_teardown
}

test_stage2_skips_a_name_that_is_not_an_aur_package() {
    # The exact failure from the trial install: git clones an empty repo, so
    # there is no PKGBUILD and makepkg must never be reached.
    _stage2_setup
    local out
    out="$(install_aur_pkg asusctl-debug 2>&1)" && assert_eq "reached" "unreachable" \
        "install_aur_pkg must report failure for a name the AUR does not have"
    assert_true grep -q 'not an AUR package' <<<"$out"
    assert_false _stage2_called 'makepkg'
    _stage2_teardown
}

test_stage2_finishes_the_list_after_a_package_fails() {
    # The whole point: one bad name used to end the run under 'set -e'.
    _stage2_setup
    _S2_OFFICIAL="rog-control-center"
    printf 'asusctl-debug\nrog-control-center\n' > "$PKGS/optional/asus.txt"

    install_aur_list "$PKGS/optional/asus.txt" >/dev/null 2>&1
    assert_eq "$?" "0" "install_aur_list returns success even when a package fails"
    assert_true _stage2_called 'sudo pacman -S --needed --noconfirm rog-control-center'
    assert_eq "${PKG_FAILED[*]}" "asusctl-debug" "only the failed package is recorded"
    _stage2_teardown
}

test_stage2_skips_a_package_that_is_already_installed() {
    _stage2_setup
    _S2_INSTALLED="asusctl"
    assert_true _stage2_quiet install_aur_pkg asusctl
    assert_false _stage2_called 'sudo pacman -S'
    assert_false _stage2_called 'git clone'
    _stage2_teardown
}

test_package_lists_carry_no_debug_packages() {
    # A '-debug' package is a by-product makepkg emits beside the real one.
    # It is not in any repository and not in the AUR, but 'pacman -Qqem' on
    # the source machine reports it as foreign, so it lands in a list unless
    # someone notices.
    local root list
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    for list in "$root"/packages/*.txt "$root"/packages/optional/*.txt; do
        assert_false grep -qE -- '-debug$' "$list"
    done
}
