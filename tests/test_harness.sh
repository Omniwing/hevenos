test_harness_eq() {
    assert_eq "abc" "abc" "identical strings are equal"
    assert_contains "hello world" "world" "substring match"
    assert_true true
    assert_false false
}
