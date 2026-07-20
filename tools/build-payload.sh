#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

# Rebuild the config tarball with all AI credentials/tooling scrubbed out.
# Usage: build-payload <source.tar.gz> <output.tar.gz>
build_payload() {
    local src="$1" out="$2"
    [[ "$out" = /* ]] || out="$PWD/$out"
    local work root
    work="$(mktemp -d)"; root="$work/root"
    mkdir -p "$root"
    tar xzf "$src" -C "$root"

    # 1. Strip the live OpenAI key line (keep every other SETUVAR).
    #    Case-insensitive: fish universal vars are case-sensitive, so
    #    OPENAI_API_KEY and openai_api_key are two distinct stored
    #    SETUVAR lines that can both carry the same live secret.
    #    Also drop the cached tide prompt vars: they memoize a fully
    #    rendered prompt that bakes in the *source* user@host. tide
    #    regenerates them on first prompt, so dropping them both
    #    de-personalizes the payload and costs nothing.
    local fv="$root/.config/fish/fish_variables"
    if [[ -f "$fv" ]]; then
        grep -vi 'OPENAI_API_KEY' "$fv" | grep -v '^SETUVAR _tide_prompt_' \
            > "$fv.new" && mv "$fv.new" "$fv"
    fi
    # 2-4. Remove temp file, AI symlinks, vendored uv/uvx.
    rm -f "$root/.config/fish/"fish_variables?*   # atomic-write leftovers only
    rm -f "$root/.local/bin/claude" "$root/.local/bin/terminalgpt" \
          "$root/.local/bin/uv" "$root/.local/bin/uvx"
    # 5. Remove personal Slack alerting scripts (not part of the desktop).
    rm -f "$root/.local/bin/slack_alarm.py" "$root/.local/bin/slack-alert-daemon"

    # Rebuild with relative paths (never -C $HOME semantics on real home).
    ( cd "$root" && tar czf "$out" . )
    rm -rf "$work"

    # Fail loud if the key somehow survived.
    if tar xzf "$out" -O ./.config/fish/fish_variables 2>/dev/null | grep -qi OPENAI_API_KEY; then
        echo "ERROR: OPENAI_API_KEY still present in $out" >&2
        return 1
    fi
    # Fail loud if the Slack scripts survived.
    if tar tzf "$out" | grep -qE 'slack_alarm\.py|slack-alert-daemon'; then
        echo "ERROR: Slack scripts still present in $out" >&2
        return 1
    fi
    # Fail loud if a shipped config carries an absolute /home/<user> path.
    # The desktop config must be username-agnostic ($HOME-relative); an
    # absolute home path means the source config still needs de-personalizing.
    # Scoped to the files we author (vendored plugins legitimately mention
    # example home paths in comments).
    if tar xzf "$out" -O ./.config/niri/config.kdl ./.config/fish/config.fish 2>/dev/null \
         | grep -qE '/home/[A-Za-z0-9._-]+/'; then
        echo "ERROR: absolute /home/<user> path in shipped config — keep it \$HOME-relative ($out)" >&2
        return 1
    fi
    # Fail loud if the identity-bearing tide prompt cache survived the scrub.
    if tar xzf "$out" -O ./.config/fish/fish_variables 2>/dev/null | grep -q '^SETUVAR _tide_prompt_'; then
        echo "ERROR: cached tide prompt (bakes in source user@host) survived scrub in $out" >&2
        return 1
    fi
    echo "Scrubbed payload written to $out"
}

# Allow running as a script as well as sourcing for tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    build_payload "$@"
fi
