#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck disable=SC1091
source ./assert.sh

shopt -s nullglob
for f in test_*.sh; do
    # shellcheck disable=SC1090
    source "./$f"
done

# Run every function named test_*. Sourcing install.sh, configure or stage2.sh
# turns 'set -e' back on in this shell, so one failing statement inside one test
# would otherwise abort the whole run -- no summary, no exit code saying which
# test, nothing. Catching that status is not the same as discarding it: the
# assert helpers always return 0, so a non-zero return means the test died
# partway through and the assertions after that point never ran.
#
# Note this also suspends errexit inside the test function itself. A test that
# needs to observe 'set -e' behaviour must run the code in a child shell -- see
# _cfg_call in test_configure.sh and _s2_call in test_stage2.sh.
for fn in $(declare -F | awk '{print $3}' | grep '^test_'); do
    if ! "$fn"; then
        FAILED=$((FAILED + 1))
        printf 'FAIL: %s returned non-zero — it aborted before its last assertion\n' "$fn" >&2
    fi
done

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
