source "$(dirname "${BASH_SOURCE[0]}")/../tools/build-payload.sh"

test_build_payload_scrubs() {
    work="$(mktemp -d)"
    src_root="$work/src"
    mkdir -p "$src_root/.config/fish" "$src_root/.local/bin"
    printf 'SETUVAR --export OPENAI_API_KEY:sk\\x2dproj\\x2dLEAK\n' \
        > "$src_root/.config/fish/fish_variables"
    printf 'SETUVAR --export openai_api_key:sk\\x2dproj\\x2dLEAK2\n' \
        >> "$src_root/.config/fish/fish_variables"
    printf 'SETUVAR __fish_initialized:4300\n' \
        >> "$src_root/.config/fish/fish_variables"
    : > "$src_root/.config/fish/fish_variablescV1lM2c1Kr"
    ln -s /nonexistent/claude      "$src_root/.local/bin/claude"
    ln -s /nonexistent/terminalgpt "$src_root/.local/bin/terminalgpt"
    printf 'binary' > "$src_root/.local/bin/uv"
    printf 'binary' > "$src_root/.local/bin/uvx"
    printf '#!/bin/sh\n' > "$src_root/.local/bin/lid-handler"
    ( cd "$src_root" && tar czf "$work/src.tar.gz" . )

    build_payload "$work/src.tar.gz" "$work/out.tar.gz"

    listing="$(tar tzf "$work/out.tar.gz")"
    assert_false grep -qi 'OPENAI_API_KEY' <(tar xzf "$work/out.tar.gz" -O ./.config/fish/fish_variables)
    assert_false grep -q 'claude'        <<<"$listing"
    assert_false grep -q 'terminalgpt'   <<<"$listing"
    assert_false grep -q '/uv$'          <<<"$listing"
    assert_false grep -q '/uvx$'         <<<"$listing"
    assert_false grep -q 'fish_variablescV1lM2c1Kr' <<<"$listing"
    assert_contains "$listing" 'lid-handler' "keeps unrelated files"
    assert_contains "$(tar xzf "$work/out.tar.gz" -O ./.config/fish/fish_variables)" '__fish_initialized' "keeps other setuvars"
    rm -rf "$work"
}
