source "$(dirname "${BASH_SOURCE[0]}")/../lib/ui.sh"

test_ask_default_uses_default_on_empty() {
    assert_eq "$(printf '\n' | ask_default 'Host?' 'archbox')" "archbox" "empty => default"
    assert_eq "$(printf 'myhost\n' | ask_default 'Host?' 'archbox')" "myhost" "input wins"
}

test_ask_yes_no_default() {
    local repo_root="$(dirname "${BASH_SOURCE[0]}")/.."
    assert_true  bash -c "source '$repo_root/lib/ui.sh'; printf '\n' | ask_yes_no 'OK?' y"
    assert_false bash -c "source '$repo_root/lib/ui.sh'; printf '\n' | ask_yes_no 'OK?' n"
    assert_true  bash -c "source '$repo_root/lib/ui.sh'; printf 'y\n' | ask_yes_no 'OK?' n"
    assert_false bash -c "source '$repo_root/lib/ui.sh'; printf 'n\n' | ask_yes_no 'OK?' y"
}
