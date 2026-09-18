# shellcheck shell=bash
#
# SC2034/SC2329 are disabled for the whole file: the stubs below are called by
# the sourced stage2.sh rather than from here, and HOME_DIR/PKG_FAILED are that
# script's globals which the tests drive. shellcheck cannot follow the computed
# source path to see any of it.
# shellcheck disable=SC2034,SC2329
# Stage 2 ran at a user's very first login and died on the first package it
# could not install, leaving stage2.sh in place to do exactly the same thing at
# every login afterwards. These cover the three ways that happened.
#
# stage2.sh guards main() behind a BASH_SOURCE/$0 comparison, so sourcing it
# defines the functions without running an install.
_s2_script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/stage2.sh"
# shellcheck disable=SC1090
source "$_s2_script"

# Run a fragment in a child shell that has sourced stage2.sh, so it executes
# under the real 'set -Eeuo pipefail' from line 2 of that file. The runner
# calls each test through 'if ! "$fn"', which suspends errexit for the test's
# whole body — so a test that needs to observe an abort MUST use this.
_s2_call() { # shell fragment
    bash -c 'source "$1"; eval "$2"' _ "$_s2_script" "$1" 2>&1
}

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
    sudo() { printf 'sudo %s\n' "$*" >> "$_S2_CALLS"; return 0; }
    git() {
        # "${!#}" is the LAST argument, the clone destination. "${*##* }" looks
        # like it strips through the final space, but the pattern applies to
        # each parameter separately, so it yields the entire command line and
        # mkdir builds *that* as a path — inside the repo, 24 times over.
        printf 'git %s\n' "$*" >> "$_S2_CALLS"
        mkdir -p "${!#}"          # an existing but empty repo, as the AUR serves
    }
    makepkg() { printf 'makepkg %s\n' "$*" >> "$_S2_CALLS"; }
}

_stage2_teardown() {
    unset -f pacman sudo git makepkg
    rm -rf "$_S2"
}

_stage2_called() { grep -qF "$1" "$_S2_CALLS"; }
_stage2_quiet()  { "$@" >/dev/null 2>&1; }

test_stage2_list_survives_a_failure_under_real_errexit() {
    # THE regression test. Under 'set -e' the old install_aur_list died on the
    # first package it could not install, so the rest of the list was never
    # attempted and main() never reached the line that removes stage2.sh. This
    # has to run in a child shell: in-process the runner has already suspended
    # errexit, and the abort it guards against cannot happen.
    local out
    # shellcheck disable=SC2016  # evaluated in the child shell, not here
    out="$(_s2_call '
        pacman() { case "$1:$2" in -Si:good-two) return 0 ;; *) return 1 ;; esac; }
        sudo() { return 0; }
        git() { mkdir -p "${!#}"; }
        list="$(mktemp)"
        printf "bad-one\ngood-two\n" > "$list"
        install_aur_list "$list"
        echo "REACHED_END failed=[${PKG_FAILED[*]}]"
        rm -f "$list"
    ' || true)"
    assert_contains "$out" "REACHED_END" \
        "a package that cannot be installed must not end the run"
    assert_contains "$out" "failed=[bad-one]" \
        "only the package that failed is recorded"
    assert_contains "$out" "not an AUR package" \
        "and the reason is printed rather than swallowed"
}

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
    # The exact failure from the trial install: the clone succeeds but the
    # repository is empty, so there is no PKGBUILD and makepkg is never run.
    _stage2_setup
    local out
    out="$(install_aur_pkg asusctl-debug 2>&1)"
    assert_false _stage2_quiet install_aur_pkg asusctl-debug
    assert_true grep -q 'not an AUR package' <<<"$out"
    assert_false _stage2_called 'makepkg'
    _stage2_teardown
}

test_stage2_builds_a_package_that_is_only_in_the_aur() {
    # The path left once everything else has graduated to extra: a real
    # PKGBUILD must still reach makepkg.
    _stage2_setup
    git() {
        printf 'git %s\n' "$*" >> "$_S2_CALLS"
        mkdir -p "${!#}"
        : > "${!#}/PKGBUILD"
    }
    assert_true _stage2_quiet install_aur_pkg some-aur-only-thing
    assert_true _stage2_called 'git clone'
    assert_true _stage2_called 'makepkg -si --noconfirm'
    _stage2_teardown
}

test_stage2_records_a_package_whose_build_fails() {
    _stage2_setup
    git() { mkdir -p "${!#}"; : > "${!#}/PKGBUILD"; }
    makepkg() { return 1; }
    local out
    out="$(install_aur_pkg broken-thing 2>&1)"
    assert_false _stage2_quiet install_aur_pkg broken-thing
    assert_true grep -q 'failed to build' <<<"$out"
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
