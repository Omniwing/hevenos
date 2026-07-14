# Dependency-free assertion helpers. Sourced by test files.
# On failure, increments FAILED and prints a diagnostic; never exits (so all
# tests run). run.sh inspects FAILED.
: "${FAILED:=0}"
: "${PASSED:=0}"

assert_eq() { # actual expected msg
    if [[ "$1" == "$2" ]]; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        printf 'FAIL: %s\n  expected: %q\n  actual:   %q\n' "$3" "$2" "$1" >&2
    fi
}

assert_contains() { # haystack needle msg
    if [[ "$1" == *"$2"* ]]; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        printf 'FAIL: %s\n  %q does not contain %q\n' "$3" "$1" "$2" >&2
    fi
}

assert_true() { # cmd...
    if "$@"; then PASSED=$((PASSED + 1));
    else FAILED=$((FAILED + 1)); printf 'FAIL: expected success: %q\n' "$*" >&2; fi
}

assert_false() { # cmd...
    if "$@"; then FAILED=$((FAILED + 1)); printf 'FAIL: expected failure: %q\n' "$*" >&2;
    else PASSED=$((PASSED + 1)); fi
}
