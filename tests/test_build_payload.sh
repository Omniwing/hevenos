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
    # Cached tide prompt bakes in the source user@host — must be scrubbed.
    printf 'SETUVAR _tide_prompt_2881:srcuser\\x40srchost\n' \
        >> "$src_root/.config/fish/fish_variables"
    : > "$src_root/.config/fish/fish_variablescV1lM2c1Kr"
    ln -s /nonexistent/claude      "$src_root/.local/bin/claude"
    ln -s /nonexistent/terminalgpt "$src_root/.local/bin/terminalgpt"
    printf 'binary' > "$src_root/.local/bin/uv"
    printf 'binary' > "$src_root/.local/bin/uvx"
    printf '#!/bin/sh\n' > "$src_root/.local/bin/lid-handler"
    printf '#!/usr/bin/env python3\n' > "$src_root/.local/bin/slack_alarm.py"
    printf '#!/usr/bin/env bash\n'    > "$src_root/.local/bin/slack-alert-daemon"
    ( cd "$src_root" && tar czf "$work/src.tar.gz" . )

    build_payload "$work/src.tar.gz" "$work/out.tar.gz"

    listing="$(tar tzf "$work/out.tar.gz")"
    scrubbed_vars="$(tar xzf "$work/out.tar.gz" -O ./.config/fish/fish_variables)"
    assert_false grep -qi 'OPENAI_API_KEY' <<<"$scrubbed_vars"
    assert_false grep -q 'claude'        <<<"$listing"
    assert_false grep -q 'terminalgpt'   <<<"$listing"
    assert_false grep -q '/uv$'          <<<"$listing"
    assert_false grep -q '/uvx$'         <<<"$listing"
    assert_false grep -q 'fish_variablescV1lM2c1Kr' <<<"$listing"
    assert_false grep -q 'slack_alarm'       <<<"$listing"
    assert_false grep -q 'slack-alert-daemon' <<<"$listing"
    assert_false grep -q 'srcuser'       <<<"$scrubbed_vars"
    assert_false grep -q '_tide_prompt_' <<<"$scrubbed_vars"
    assert_contains "$listing" 'lid-handler' "keeps unrelated files"
    assert_contains "$scrubbed_vars" '__fish_initialized' "keeps other setuvars"
    rm -rf "$work"
}
