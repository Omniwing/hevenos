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

# Run every function named test_*. The '|| true' is load-bearing: sourcing
# install.sh or configure turns 'set -e' back on in this shell, and without it
# one failing statement inside one test aborts the whole run -- no summary, no
# exit code that says which test, nothing.
for fn in $(declare -F | awk '{print $3}' | grep '^test_'); do
    "$fn" || true
done

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
