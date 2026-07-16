function fish_greeting --description 'hevenos console login banner'
    # Only greet on the pure VT login, never inside a desktop terminal.
    # WAYLAND_DISPLAY covers niri; DISPLAY covers the Xfce/X11 fallback.
    status is-login; or return
    set -q WAYLAND_DISPLAY; and return
    set -q DISPLAY; and return

    # Armbian/Orange-Pi-style MOTD: figlet header, welcome line, then a
    # two-column live stats grid (14-char labels, green values). ASCII-safe
    # output only — the Linux console font has no CJK/emoji glyphs.
    set_color cyan
    echo ' _                                    '
    echo '| |__   _____   _____ _ __   ___  ___ '
    echo "| '_ \\ / _ \\ \\ / / _ \\ '_ \\ / _ \\/ __|"
    echo '| | | |  __/\\ V /  __/ | | | (_) \\__ \\'
    echo '|_| |_|\\___| \\_/ \\___|_| |_|\\___/|___/'
    set_color normal
    echo

    set -l os (string match -r 'PRETTY_NAME="(.*)"' < /etc/os-release)[2]
    echo 'Welcome to hevenos ('$os') with Linux '(uname -r)
    echo

    # Load as a percentage of available cores, Armbian-style.
    set -l cores (nproc)
    set -l load1 (string split ' ' (cat /proc/loadavg))[1]
    set -l loadpct (math "round($load1 / $cores * 100)")

    set -l up (uptime -p | string replace -r '^up ' '')

    set -l memtot (string match -r 'MemTotal:\s+(\d+)' < /proc/meminfo)[2]
    set -l memavail (string match -r 'MemAvailable:\s+(\d+)' < /proc/meminfo)[2]
    set -l mempct (math "round((1 - $memavail / $memtot) * 100)")
    set -l memtot_h (math -s2 "$memtot / 1048576")'G'

    set -l ip (ip -4 route get 1.1.1.1 2>/dev/null | string match -r 'src (\S+)')[2]
    test -n "$ip"; or set ip none

    set -l rootfs (string split -n ' ' (df -h / | tail -1))
    set -l disk "$rootfs[5] of $rootfs[2]"

    _hevenos_stat 'System load:' $loadpct'%' 'Up time:' "$up"
    _hevenos_stat 'Memory usage:' $mempct'% of '$memtot_h 'IP:' "$ip"
    if test -r /sys/class/thermal/thermal_zone0/temp
        set -l temp (math "round("(cat /sys/class/thermal/thermal_zone0/temp)" / 1000)")
        _hevenos_stat 'CPU temp:' $temp'°C' 'Usage of /:' "$disk"
    else
        _hevenos_stat 'Usage of /:' "$disk"
    end
    echo

    if test -e ~/stage2.sh
        set_color --bold yellow
        echo ">> Setup isn't finished — finishing it automatically now."
        echo ">> This installs AUR packages and can take a while on slow hardware."
        set_color normal
        echo
        ~/stage2.sh
        echo
    end

    set_color --bold green
    if test -e ~/stage2.sh
        echo ">> automatic setup didn't finish — it will retry at your next login"
    else if test -e ~/.hevenos-x11
        echo ">> type 'startx' to start the desktop"
    else
        echo ">> type 'niri' to start the desktop"
    end
    set_color normal
    echo
end

function _hevenos_stat --description 'one Armbian-style two-column stat row'
    printf '%-14s ' $argv[1]
    set_color brgreen
    printf '%-17s' $argv[2]
    set_color normal
    if test (count $argv) -ge 4
        printf '%-15s ' $argv[3]
        set_color brgreen
        printf '%s' $argv[4]
        set_color normal
    end
    echo
end
