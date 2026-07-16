# Project: Arch Linux + niri Desktop Replication

## What this project is

Replicating omniwing's personal Arch Linux desktop environment (Wayland + niri
compositor, fish shell, custom theming) onto other machines from a payload of
two package lists and one config tarball. One deployment is complete (friend's
laptop); a second is in progress (2010-era HP netbook).

## The payload (lives on a USB flash drive)

- `pkglist-native.txt` — official-repo packages, generated with `pacman -Qqen`
- `pkglist-aur.txt` — AUR/foreign packages, generated with `pacman -Qqem`
- `desktop-env.tar.gz` — home-relative config tarball containing:
  `.config/niri`, `.config/fish`, `.config/kitty`, `.config/waybar`,
  `.config/gtk-3.0`, `.config/gtk-4.0`, `.local/bin` (includes `lid-handler`
  script), `.local/share/icons`, `Pictures/Wallpapers` (includes
  `cyberpunk-80s-neon.jpg`, referenced by swaybg)
  - Tarball was created with `cd ~` + relative paths (NOT `-C $HOME` — see
    lessons). Extract with `cd ~; tar xzf desktop-env.tar.gz`.

## Source environment facts (omniwing's laptop)

- niri config: `~/.config/niri/config.kdl` spawns at startup: waybar, mako,
  swayidle (inline args, no separate config file), a `lid-handler` script via
  bash, and swaybg with the wallpaper above.
- TWO HARDCODED `/home/omniwing` paths in config.kdl (lid-handler path and
  wallpaper path). On any target where the username differs:
  `sed -i "s|/home/omniwing|$HOME|g" ~/.config/niri/config.kdl`
  and check with `grep -rl /home/omniwing ~/.config ~/.local/bin`.
- NO custom GTK theme (stock Adwaita), no cursor theme, no dconf state, no
  user-local fonts. Font used by waybar/kitty: **JetBrainsMono Nerd Font**,
  provided by a package already present in pkglist-native.txt.
- niri launch mechanism: getty autologin drop-in at
  `/etc/systemd/system/getty@tty1.service.d/autologin.conf` (system-side,
  NOT in tarball — must be recreated per machine) + exec logic in fish config
  (travels with tarball).
- fish is the login shell: `chsh -s /usr/bin/fish`.

## Standard deployment sequence (after base Arch install + first boot)

1. As root: `pacman -Syu` FIRST (stale DBs cause false "target not found").
2. `pacman -S --needed base-devel git`
3. Install native list, tolerating stale names (fish syntax):
   `pacman -S --needed (comm -12 (pacman -Slq | sort | psub) (sort pkglist-native.txt | psub))`
   Capture stragglers:
   `comm -13 (pacman -Slq | sort | psub) (sort pkglist-native.txt | psub) > missing.txt`
4. Bootstrap AUR helper as regular user (NEVER installable via pacman):
   `git clone https://aur.archlinux.org/paru-bin.git && cd paru-bin && makepkg -si`
   Use **paru-bin** not paru on weak hardware (paru compiles Rust for hours).
5. `paru -S --needed - < pkglist-aur.txt` (prefer `-bin` variants on slow CPUs)
6. `cd ~; tar xzf desktop-env.tar.gz; fc-cache -f`
7. Username path fix (sed above) if user != omniwing.
8. `chsh -s /usr/bin/fish`
9. Recreate getty autologin drop-in (root).
10. Restart niri fully (`niri msg action quit` + relogin) — config changes via
    tar extraction do NOT hot-reload (new inode breaks inotify watch); kitty
    reloads with `pkill -USR1 kitty` or a fresh process.

## Lessons learned (hard-won, do not relearn)

- **tar `--ignore-failed-read` warnings are benign.** A wall of "Cannot stat"
  lines means missing optional dirs were skipped, NOT failure. Check exit code
  and `tar tzf` contents before assuming breakage.
- **Avoid `-C $VAR` with tar in fish.** cd first, use relative paths.
- **`tar xzf` overwrites silently by default** — re-extraction is safe/idempotent.
- **`tar rf` cannot append to compressed archives** — rebuild instead.
- **Fresh-install ESP trap:** if the ESP isn't mounted at `/mnt/boot` BEFORE
  pacstrap, the kernel lands on the ext4 root and gets shadowed when the empty
  ESP is later mounted over it. Fix: umount /boot, move kernel files to the
  real ESP, mount it, add to fstab, then `bootctl install`. Also: genfstab
  must capture BOTH partitions.
- **Chroot keyring is empty:** `pacman-key --init && pacman-key --populate archlinux`
  before installing packages in a chroot (otherwise endless PGP signature
  failures asking about individual maintainer keys).
- **NetworkManager needs wpa_supplicant enabled** (`systemctl enable --now
  wpa_supplicant`). It's installed as a dependency but NOT auto-enabled.
  Symptom of it missing: nmtui shows "connected" but no traffic, and
  reconnect says "can't reach the adapter." Enable both NM and wpa_supplicant
  in the chroot during install.
- **Only ONE network daemon:** iwd (used in live ISO) must not be enabled on
  the installed system alongside NetworkManager.
- **paru/AUR helpers are never in official repos** — bootstrap via git clone +
  makepkg once; makepkg refuses to run as root.
- **`--needed` makes both install commands idempotent** — safe to rerun.
- **GTK/icon themes install as pacman packages to /usr/share** — configs only
  store theme *names*; the providing package must be in the pkglist or apps
  fall back to Adwaita. (Moot for this environment — stock Adwaita anyway.)

## Machine 2 (in progress): 2010 HP netbook

- Almost certainly **legacy BIOS** (verify: `cat /sys/firmware/efi/fw_platform_size`
  → "No such file" = BIOS). systemd-boot is UEFI-only → use **GRUB**:
  MBR/dos partition table, bootable flag on root partition,
  `grub-install --target=i386-pc /dev/sda` (whole disk, not partition),
  `grub-mkconfig -o /boot/grub/grub.cfg`. No ESP exists; /boot is a plain dir
  on root, so the ESP-shadowing trap can't occur.
- **GPU result (confirmed 2026-07-16): GMA 3150 is BELOW the hevenos floor.**
  i915/KMS binds and niri *starts*, but the chip is OpenGL 2.1-max — kitty
  hard-requires GL 3.3, and niri's theme shaders exceed gen3's ~64-ALU
  fragment-shader limit (border shader alone needs ~253). The kernel also
  strips atomic KMS from gen3 userspace (`intel_display_device.c`, pre-g4x
  loses DRIVER_ATOMIC), so niri runs smithay's little-tested legacy path,
  where this machine hits a deterministic page-flip EACCES display freeze.
  `install.sh` detects below-floor GPUs (Intel gen2/gen3 + PowerVR
  GMA 500/600/3600) at preflight and now refuses unconditionally — no
  prompt, no `--force`, no disk write. hevenos targets niri/Wayland only.
- **X11/Xfce fallback removed from hevenos entirely** (owner's decision,
  2026-07-16): the fallback desktop (`packages/fallback-x11.txt`,
  `configure_x11_fallback()`, the `.hevenos-x11` marker, `X11_FALLBACK`/
  `FORCE`/`--force`) was ripped out of `install.sh`, `stage2.sh`, the login
  banner, tests, and README — verdict was that shipping a second, lesser
  desktop as a silent fallback was the wrong shape for this project.
  `packages/niri-wayland.txt` (a short-lived split from an earlier session)
  was folded back into `packages/core.txt` since the branch that justified
  it no longer exists.
- **Netbook stays in service, but not via hevenos.** Forked into a sibling
  project, **legacyheven** (`~/legacyheven`, github.com/Omniwing/legacyheven
  — pre-planning stage only, see that repo's own docs), whose goal is a
  themeless desktop with the same *behavior* as hevenos (niri-style tiling
  keybinds — window/column focus and move via arrows+hjkl, workspace nav,
  consume/expel, resize, `Mod+Return` terminal launch — see
  `payload/desktop-env.tar.gz`'s `config.kdl` for the exact bind set) on
  hardware below the OpenGL 3.3 floor. Not yet planned or started.
- 1–2 GB RAM: add 2 GB swapfile (`fallocate -l 2G /swapfile; chmod 600
  /swapfile; mkswap /swapfile; swapon /swapfile` + fstab entry).
- Prefer `-bin` AUR variants throughout; Atom-era CPU makes source builds
  impractical.
- Current state at last session: first boot from disk done; was hitting
  "target not found" (stale DBs / stale package names) and had not yet
  bootstrapped paru. Steps 1–4 of the deployment sequence are the fix.
  `missing.txt` contents not yet reviewed.

## Machine 1 (complete): friend's laptop

- UEFI, systemd-boot, NetworkManager + wpa_supplicant enabled, full pkglists
  installed, tarball extracted, hardcoded paths fixed, niri running with
  wallpaper/waybar/kitty theming confirmed. Claude Code was installed
  temporarily via native installer (`~/.local/bin/claude`); remember it
  uninstalls with `rm -f ~/.local/bin/claude; rm -rf ~/.local/share/claude
  ~/.claude; rm ~/.claude.json` and that the auth session in ~/.claude.json
  belongs to omniwing's account — scrub before handback if not done already.

## Conventions for this project

- User is a professional sysadmin; skip fundamentals, be precise and decisive.
- Fish shell syntax for user-level commands (psub, no bashisms).
- Never prefix commands with sudo; mark root-needed commands as [root].
- Verify claims against actual command output rather than theorizing;
  when a command "fails," read the exit code and output literally first.
