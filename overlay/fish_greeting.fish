function fish_greeting --description 'hevenos console login banner'
    # Only greet on the pure VT login, never inside desktop terminals.
    status is-login; or return
    test "$TERM" = linux; or return

    # ASCII-safe hellos only — the Linux console font has no CJK/emoji glyphs.
    set -l hellos Hello Hi Hey Hola Ciao Hej Salut Hallo Ahoy Howdy \
        Greetings Welcome 'Well met' 'Good day' 'Nice to see you'
    set -l hi $hellos[(random 1 (count $hellos))]

    set_color cyan
    echo '   _                            '
    echo '  | |_  _____ _____ _ _  ___ ___'
    echo "  | ' \\/ -_) V / -_) ' \\/ _ (_-<"
    echo '  |_||_\\___|\\_/\\___|_||_\\___/__/'
    set_color normal
    echo

    set_color brmagenta
    echo -n '  '$hi', '
    set_color --bold white
    echo (whoami)
    set_color normal

    set_color brblack
    printf '  %-7s %s\n' host (uname -n)
    printf '  %-7s %s\n' kernel (uname -r)
    printf '  %-7s %s\n' up (uptime -p | string replace -r '^up ' '')
    set_color normal
    echo

    set_color --bold green
    if test -e ~/stage2.sh
        echo "  >> setup isn't finished yet — run ./stage2.sh, then type 'niri' to start the desktop"
    else
        echo "  >> type 'niri' to start the desktop"
    end
    set_color normal
    echo
end
