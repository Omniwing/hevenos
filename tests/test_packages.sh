source "$(dirname "${BASH_SOURCE[0]}")/../lib/packages.sh"

_mkfile() { local f; f="$(mktemp)"; printf '%s\n' "$@" > "$f"; echo "$f"; }

test_available_pkgs() {
    repo="$(_mkfile niri kitty fish mesa nmap)"
    want="$(_mkfile '# a comment' kitty '' fish '   # indented' bogus-pkg nmap)"
    got="$(available_pkgs "$repo" "$want" | tr '\n' ' ')"
    assert_eq "$got" "fish kitty nmap " "intersection, sorted"
    rm -f "$repo" "$want"
}

test_missing_pkgs() {
    repo="$(_mkfile niri kitty fish mesa nmap)"
    want="$(_mkfile '# a comment' kitty '' fish '   # indented' bogus-pkg nmap)"
    got="$(missing_pkgs "$repo" "$want" | tr '\n' ' ')"
    assert_eq "$got" "bogus-pkg " "only the straggler"
    rm -f "$repo" "$want"
}
