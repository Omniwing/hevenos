# shellcheck shell=bash
# A fresh install registered no handler for anything, so xdg-open had nothing
# to launch: clicking a link did nothing, and neither did Firefox's Save As,
# because niri never handed the display to the D-Bus services behind it.
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/install.sh"

_dd_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_dd_mime="$_dd_root/overlay/mimeapps.list"

_dd_handler() { # mime-type -> the .desktop registered for it
    awk -F= -v k="$1" '$1 == k { print $2; exit }' "$_dd_mime"
}

test_defaults_name_a_handler_for_every_kind_we_ship() {
    assert_eq "$(_dd_handler x-scheme-handler/http)"  "firefox.desktop" \
        "a clicked link has a browser to open"
    assert_eq "$(_dd_handler x-scheme-handler/https)" "firefox.desktop" ""
    assert_eq "$(_dd_handler text/html)"              "firefox.desktop" ""
    assert_eq "$(_dd_handler inode/directory)" "org.gnome.Nautilus.desktop" \
        "opening a folder launches the file manager we install"
    assert_eq "$(_dd_handler video/mp4)" \
        "io.github.celluloid_player.Celluloid.desktop" "video opens in celluloid"
    assert_eq "$(_dd_handler video/x-matroska)" \
        "io.github.celluloid_player.Celluloid.desktop" ""
}

test_every_default_names_a_package_we_install() {
    # A handler pointing at a .desktop no installed package provides fails
    # exactly as silently as having no handler at all.
    local -A owner=(
        [firefox.desktop]=firefox
        [org.gnome.Nautilus.desktop]=nautilus
        [io.github.celluloid_player.Celluloid.desktop]=celluloid
        [mpv.desktop]=mpv
    )
    local desktop
    while IFS= read -r desktop; do
        assert_true test -n "${owner[$desktop]:-}"
        assert_true grep -qxF "${owner[$desktop]:-no-such-package}" \
            "$_dd_root/packages/core.txt"
    done < <(awk -F= '/^[a-z]/ { print $2 }' "$_dd_mime" | sort -u)
}

test_xdg_open_itself_is_installed() {
    # xdg-utils provides xdg-open. Every default above is inert without it.
    assert_true grep -qxF xdg-utils "$_dd_root/packages/core.txt"
    assert_true grep -qxF gvfs "$_dd_root/packages/core.txt"   # nautilus trash/mounts
}

_dd_fake_target() { # -> MNT with a niri config in it
    # install.sh's own globals: saved and restored around each test so a later
    # test never inherits a path to a directory this one deleted.
    _DD_OLD_MNT="${MNT-}"; _DD_OLD_USER="${HEVENOS_USER-}"
    MNT="$(mktemp -d)"
    HEVENOS_USER=someone
    mkdir -p "$MNT/home/$HEVENOS_USER/.config/niri"
    printf 'spawn-at-startup "waybar"\n' \
        > "$MNT/home/$HEVENOS_USER/.config/niri/config.kdl"
}

test_portal_environment_line_is_added_once() {
    _dd_fake_target
    local config="$MNT/home/$HEVENOS_USER/.config/niri/config.kdl"

    ensure_portal_environment >/dev/null 2>&1
    assert_eq "$(grep -c dbus-update-activation-environment "$config")" "1" \
        "the portal environment line is added when the config lacks it"
    assert_true grep -q 'WAYLAND_DISPLAY' "$config"
    assert_contains "$(cat "$config")" 'spawn-at-startup "waybar"' \
        "the existing config is appended to, never replaced"

    # Re-running an installer over a target must not stack duplicates.
    ensure_portal_environment >/dev/null 2>&1
    assert_eq "$(grep -c dbus-update-activation-environment "$config")" "1" \
        "a second run adds nothing"
    rm -rf "$MNT"
    MNT="$_DD_OLD_MNT"; HEVENOS_USER="$_DD_OLD_USER"
}

test_portal_environment_warns_instead_of_dying_without_a_config() {
    _dd_fake_target
    rm -f "$MNT/home/$HEVENOS_USER/.config/niri/config.kdl"
    local out
    out="$(ensure_portal_environment 2>&1)"
    assert_eq "$?" "0" "a missing niri config must not abort the install"
    assert_true grep -q 'Save As' <<<"$out"
    rm -rf "$MNT"
    MNT="$_DD_OLD_MNT"; HEVENOS_USER="$_DD_OLD_USER"
}
