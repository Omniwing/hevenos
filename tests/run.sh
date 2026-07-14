#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
source ./assert.sh

shopt -s nullglob
for f in test_*.sh; do
    # shellcheck disable=SC1090
    source "./$f"
done

# Run every function named test_*
for fn in $(declare -F | awk '{print $3}' | grep '^test_'); do
    "$fn"
done

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
