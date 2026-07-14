#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

# Rebuild the config tarball with all AI credentials/tooling scrubbed out.
# Usage: build-payload <source.tar.gz> <output.tar.gz>
build_payload() {
    local src="$1" out="$2"
    local work root
    work="$(mktemp -d)"; root="$work/root"
    mkdir -p "$root"
    tar xzf "$src" -C "$root"

    # 1. Strip the live OpenAI key line (keep every other SETUVAR).
    local fv="$root/.config/fish/fish_variables"
    if [[ -f "$fv" ]]; then
        grep -v 'OPENAI_API_KEY' "$fv" > "$fv.new" && mv "$fv.new" "$fv"
    fi
    # 2-4. Remove temp file, AI symlinks, vendored uv/uvx.
    rm -f "$root/.config/fish/"fish_variables?*   # atomic-write leftovers only
    rm -f "$root/.local/bin/claude" "$root/.local/bin/terminalgpt" \
          "$root/.local/bin/uv" "$root/.local/bin/uvx"

    # Rebuild with relative paths (never -C $HOME semantics on real home).
    ( cd "$root" && tar czf "$out" . )
    rm -rf "$work"

    # Fail loud if the key somehow survived.
    if tar xzf "$out" -O ./.config/fish/fish_variables 2>/dev/null | grep -q OPENAI_API_KEY; then
        echo "ERROR: OPENAI_API_KEY still present in $out" >&2
        return 1
    fi
    echo "Scrubbed payload written to $out"
}

# Allow running as a script as well as sourcing for tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    build_payload "$@"
fi
