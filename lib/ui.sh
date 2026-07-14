# Minimal logging + prompt helpers. Prompts read stdin so they are testable
# and degrade to the default on EOF / non-interactive input.

say()  { printf '\033[1;36m::\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

ask_default() { # prompt default
    local prompt="$1" default="$2" reply
    printf '%s [%s]: ' "$prompt" "$default" >&2
    IFS= read -r reply || true
    [[ -n "$reply" ]] && echo "$reply" || echo "$default"
}

ask_yes_no() { # prompt default(y|n)
    local prompt="$1" default="$2" reply
    printf '%s [%s/%s]: ' "$prompt" \
        "$([[ $default == y ]] && echo Y || echo y)" \
        "$([[ $default == n ]] && echo N || echo n)" >&2
    IFS= read -r reply || true
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy] ]]
}
