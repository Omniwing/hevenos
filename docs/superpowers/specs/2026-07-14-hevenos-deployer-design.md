# hevenos deployer — design

**Date:** 2026-07-14
**Status:** Approved (pending spec review)

## Purpose

A git-hosted, two-stage installer that replicates omniwing's Arch Linux + niri
Wayland desktop onto a fresh machine with minimal typing. The operator
partitions/formats/mounts the disks by hand; from there the scripts take the
machine from an empty `/mnt` to a booting niri desktop.

Design target: **any x86_64 machine** — sit down at an arbitrary 64-bit laptop
or desktop (or VM), run the script, answer a few prompts, get a working niri
desktop. Achieved via runtime hardware detection (firmware, CPU microcode, GPU
vendor, RAM) and opt-in package lists, not per-machine forks.

Immediate proving grounds: the 2010 HP netbook (legacy BIOS, 64-bit Atom, low
RAM, Intel GMA) and Arthur-class UEFI Intel laptops.

## Non-goals

- Partitioning, formatting, or mounting disks (operator does this first).
- Unattended/zero-prompt install (username, passwords, hostname are prompted).
- 32-bit / i686 hardware. Mainline Arch is x86_64-only (i686 dropped 2017); the
  script asserts a 64-bit CPU and aborts otherwise. Arch Linux 32 is a separate
  project and out of scope.
- Fixing fundamentally unsupported GPUs (e.g. GMA500/Poulsbo, no KMS) — the
  script detects and warns, but cannot make niri run there.
- A general-purpose Arch installer. This replicates one specific environment,
  adapted to the host's hardware.

## Repository shape (single public git repo)

```
hevenos/
  install.sh              # Stage 1 — live ISO, disks already mounted at /mnt
  stage2.sh               # Stage 2 — booted system, run as the user (AUR)
  packages/
    core.txt              # curated must-haves (OS + niri desktop + operation)
    aur.txt               # curated AUR packages (paru-bootstrapped)
    optional/
      fonts-extra.txt     # the ~78 other Nerd Fonts (off by default)
      security-tools.txt  # official-repo pentest tools minus nmap (off by default)
      asus.txt            # asusctl / asusctl-debug / rog-control-center (off by default)
  payload/
    desktop-env.tar.gz    # SCRUBBED, rebuilt config tarball
  README.md
```

Entry point on a fresh machine (from the live ISO, disks mounted):
`pacman -Sy git` → `git clone <repo>` → `./hevenos/install.sh`.
Not `curl | bash`: the 26 MB tarball must be local anyway, so a clone is the
honest entry point.

## Blocking prep task (one-time, before first push)

The source tarball carries AI tooling and a live credential that must not enter
the repo. All of it is bundled *state*, not packages — no pacman/AUR entry in
the lists is AI-specific, so nothing is cut from `core.txt`/`aur.txt`.
`terminalgpt` and Claude Code were pipx/native-installer tools; they can be
reinstalled by hand later.

Rebuild `desktop-env.tar.gz` from a cleaned extraction, removing:

1. The **live `OPENAI_API_KEY`** — strip the
   `SETUVAR --export OPENAI_API_KEY:...` line from
   `.config/fish/fish_variables`.
2. `.local/bin/claude` — dangling symlink to omniwing's Claude Code install.
3. `.local/bin/terminalgpt` — dangling symlink to a pipx OpenAI CLI (the
   consumer of the key above).
4. `.config/fish/fish_variablescV1lM2c1Kr` — leftover atomic-write temp file.
5. `.local/bin/uv` and `.local/bin/uvx` — ~60 MB of vendored general Python
   tooling, unnecessary for a basic install and reinstallable later
   (`pacman -S uv`). Dropping them is the single biggest payload reduction.

Then rebuild (`cd ~; tar czf ...` with relative paths, per project convention —
never `-C $HOME`). **Rotate the OpenAI key** out-of-band regardless — it has
already lived on a USB stick and in another user's home directory.

Verified clean when, against the rebuilt tarball:
`grep -r OPENAI_API_KEY` finds nothing, and
`.local/bin/{claude,terminalgpt,uv,uvx}` are absent.

## Stage 1 — `install.sh`

Runs in the live ISO after the operator has partitioned/formatted/mounted the
target at `/mnt` (and `/mnt/boot` = the ESP on UEFI).

### 1. Preflight & detection (fail loud, never guess)
The "light sweep" is deliberately narrow: on Arch, almost all hardware drivers
are in-kernel modules that auto-load, so detection only covers the handful of
things that *are* explicit package/config decisions.
- **CPU is x86_64:** assert `lscpu`/`uname -m` reports x86_64 (or `lm` flag
  present); abort with a clear message on 32-bit-only hardware (see Non-goals).
- Assert `/mnt` is a mountpoint and network works; on UEFI, assert `/mnt/boot`
  is mounted (guards the ESP-shadowing trap from the project lessons).
- **Firmware:** `/sys/firmware/efi/fw_platform_size` absent ⇒ BIOS, present ⇒
  UEFI.
- **CPU microcode:** `/proc/cpuinfo` `vendor_id` ⇒ `intel-ucode` or `amd-ucode`.
- **GPU vendor:** `lspci -nn | grep -iE 'VGA|3D|Display'` ⇒ Intel / AMD/ATI /
  NVIDIA / other, feeding the graphics-driver step (§8a). Warn (do not abort)
  on GMA500/Poulsbo — no KMS, niri unworkable, operator's call to continue.
- **Wifi chipset:** scan `lspci`/`lsusb` for Broadcom BCM43xx; these are NOT in
  `linux-firmware` and leave wifi dead. If found, flag it and record the fix
  (`broadcom-wl-dkms` or `b43-firmware`, handled in stage 2 / noted in report)
  rather than pretending networking is fine.
- **RAM total** ⇒ swap decision (§7).
- **Target disk for GRUB:** derive the parent block device of the `/mnt` mount,
  present it, require operator confirmation before `grub-install`.

### 2. Base install
- `pacman -Sy` (fresh DBs — stale DBs cause false "target not found").
- `pacstrap /mnt` base linux linux-firmware linux-headers base-devel git
  networkmanager wpa_supplicant sudo vim nano `<detected-ucode>`.

### 3. fstab
- `genfstab -U /mnt >> /mnt/etc/fstab`; on UEFI confirm **both** partitions
  captured.

### 4. chroot configuration (via `arch-chroot`)
- Prompt: hostname, timezone, locale (sensible defaults offered).
- `mkinitcpio -P`.
- Prompt + set root password.
- Prompt username; create user with `-m -G wheel -s /usr/bin/fish`, set its
  password, enable `%wheel` sudo.
- Path fix: `sed -i "s|/home/omniwing|/home/<user>|g"` across
  `~/.config/niri/config.kdl` and `~/.config/fish/config.fish` (three hardcoded
  paths total: lid-handler, wallpaper, pipx PATH line). Verify with
  `grep -rl /home/omniwing ~/.config ~/.local/bin` returning nothing.
  (Skip the rewrite when username == omniwing.)

### 5. Bootloader (firmware-dependent)
- **UEFI:** `bootctl install`; write a loader entry referencing the ucode and
  root (`root=UUID=... rw`), plus `initrd` lines for both ucode and the kernel.
- **BIOS:** `grub-install --target=i386-pc <confirmed-disk>` (whole disk);
  `grub-mkconfig -o /boot/grub/grub.cfg`. MBR/dos table, bootable flag on the
  root partition. No ESP exists, so the shadowing trap cannot occur.

### 6. Services
- `systemctl enable NetworkManager wpa_supplicant chrony bluetooth acpid`.
- Explicitly ensure `iwd` is **not** enabled (only one network daemon).

### 7. Swap (conditional)
- If RAM ≤ ~2 GB: `fallocate -l 2G /swapfile; chmod 600; mkswap; swapon` +
  fstab entry.

### 8. Native packages (tolerant install)
- Sync DBs inside chroot, then install `core.txt` intersected with available
  packages:
  `pacman -S --needed $(comm -12 <(pacman -Slq|sort) <(sort core.txt))`.
- Write unavailable names to `/root/missing.txt` (via `comm -13`) and report.
- Prompt (default No) for each optional list: `fonts-extra`, `security-tools`,
  `asus`; install accepted ones the same tolerant way.
- `--needed` throughout ⇒ idempotent, safe to rerun.

### 8a. Graphics driver (detected, not hardcoded)
Install the userspace GL/Vulkan stack matching the GPU vendor from §1. `mesa`
is the common base for the open drivers; the vendor packages layer on top.

| Detected GPU | Packages installed |
|---|---|
| Intel | `mesa`, `vulkan-intel`, `intel-media-driver` (VAAPI) |
| AMD / ATI | `mesa`, `vulkan-radeon`, `libva-mesa-driver` |
| NVIDIA | **default:** `mesa` only — the nouveau driver is in-kernel (DRM) + mesa (GL); Wayland-friendly, works on old cards, no extra package. **Prompt** to instead install proprietary `nvidia`/`nvidia-open` for reasonably recent cards — sets `nvidia-drm.modeset=1` and adds the kms modules to `mkinitcpio`. |
| Other / VM (virtio, QXL, VMware) | `mesa` (generic; kernel handles the rest) |

Rationale for the NVIDIA default: niri is Wayland, and proprietary NVIDIA on
Wayland is precisely where "just works" fails on unknown/old hardware. Nouveau
trades performance for reliability — the safe default for an arbitrary machine;
the prompt covers the case where the card is new enough to want proprietary.
This step runs in the chroot alongside §8 and is tolerant/`--needed` like it.

### 9. Desktop payload
- Copy `payload/desktop-env.tar.gz` into `/mnt/home/<user>`; extract as the
  user (`cd ~; tar xzf desktop-env.tar.gz`); `chown -R <user>:<user>`;
  `fc-cache -f`.
- tar "Cannot stat" warnings are benign (missing optional dirs); check exit
  code, not stderr volume.

### 10. Shell & launch model
- `chsh -s /usr/bin/fish <user>` (also set at creation, belt-and-suspenders).
- **No autologin, no greetd.** By design the machine boots to a plain tty; the
  user logs in and types `niri`. Nothing to configure here.

### 11. Hand-off
- Copy `stage2.sh` into `/home/<user>`, `chown` it, print:
  "Reboot, remove the install media, log in as <user>, run `./stage2.sh`,
  then type `niri`."

## Stage 2 — `stage2.sh`

Runs on the booted system, as the user (refuses to run as root).

1. Bootstrap the AUR helper (never pacman-installable):
   `git clone https://aur.archlinux.org/paru-bin.git && cd paru-bin && makepkg -si`.
   Use `paru-bin` (prebuilt) — `paru` compiles Rust for hours on Atom.
2. `paru -S --needed - < ~/hevenos/packages/aur.txt`.
3. If the operator opted into ASUS at stage 1 (marker file), also install
   `optional/asus.txt`.
4. If stage 1 flagged a Broadcom BCM43xx wifi chip (marker file), install the
   fix here (`broadcom-wl-dkms`, needs `linux-headers` — already in core) so
   networking comes up. Stage 1's own networking used Ethernet or a supported
   adapter; this closes the wifi gap on the booted system.
5. `fc-cache -f`; print "Done — type `niri` to start the desktop."

## Package curation

Source: Arthur's machine state (`pacman -Qqen` = 187 native, `-Qqem` = 8 AUR),
an ASUS ROG laptop with a large pentest/font splurge. Curation philosophy:
core = anything serving the OS, the niri GUI, or general operation; everything
else is dropped or moved to an opt-in list.

### Native — dropped entirely
- BlackArch-only (never in official repos): `bully`, `reaver`, `wifite`,
  `pixiewps`, `cowpatty`, `fern-wifi-cracker`, `speedpwn`, `blackarch-mirrorlist`.
- Heavy/extraneous apps: `steam`, `discord`, `waydroid`, `rpi-imager`,
  `lib32-mesa`, `lib32-vulkan-icd-loader`, `lib32-vulkan-intel` (multilib only
  existed for steam).
- Unused launcher / non-installable helpers: `greetd`, `greetd-tuigreet`
  (launch is manual tty), `paru`, `yay` (AUR helpers, bootstrapped separately).
- Redundant terminals & unused prompt: `alacritty`, `cool-retro-term`,
  `xterm` (kitty is the terminal), `starship` (config uses **tide**).
- Other extraneous: `freerdp`, `rdesktop`, `tigervnc`, `xorg-xauth`,
  `xorg-xhost`, `subversion`, `figlet`, `asciiquarium`, `mypaint`,
  `xournalpp`, `speedtest-cli`, `picocom`, `python-pyqt5` (fern dep).

### Native — moved to opt-in lists
- `optional/fonts-extra.txt`: the ~78 Nerd Font packages beyond the three the
  desktop needs. The **required** font — `ttf-jetbrains-mono-nerd`
  (JetBrainsMono, used by waybar and kitty) — stays in core, never optional.
- `optional/security-tools.txt`: `aircrack-ng`, `hashcat`, `hcxtools`,
  `hcxdumptool`, `hostapd`, `macchanger`, `netdiscover`, `python-scapy`,
  `termshark`. **`nmap` stays in core** (operator uses it generally).

### Native — moved out of core into detected graphics step (§8a)
- `mesa`, `vulkan-intel` (were hardcoded Intel). GPU userspace is now installed
  by vendor detection, not baked into `core.txt`. `vulkan-icd-loader` stays in
  core (vendor-agnostic ICD loader).

### Native — added (referenced by config but missing from the list)
- `swaylock` (niri lock keybind), `playerctl` (media keybinds). Add to core.
- `orca` (a11y keybind) — optional, not core.

### Native — kept in core (representative)
niri, waybar, mako, swaybg, fuzzel, xwayland-satellite, xorg-xwayland,
wayland, wayland-protocols; kitty; fish, nano (default `$EDITOR`), vim;
pipewire, wireplumber, pavucontrol, sof-firmware, alsa-utils; bluez,
bluez-utils; networkmanager, wpa_supplicant, wireguard-tools, openssh, wget,
rsync; vulkan-icd-loader (GPU userspace itself comes from §8a detection);
brightnessctl, power-profiles-daemon, acpid, powertop, cpupower; cmatrix
(Mod+L keybind), fuzzel, swaylock, playerctl; jq, zoxide, broot, btop, tmux,
keyd, libnotify; xdg-desktop-portal, xdg-desktop-portal-gtk; firefox; nmap;
git, man-db, man-pages, chrony, 7zip, unrar, unzip; the three fonts
(`ttf-jetbrains-mono-nerd`, `ttf-nerd-fonts-symbols`,
`ttf-nerd-fonts-symbols-mono`).

Final per-package assignment is produced during implementation from the actual
187-line list; the buckets above are the rules.

### AUR curation
- Keep: `battop`, `byobu`, `ipscan-bin`, `elio`.
- Drop: `neofetch-git` (upstream is dead).
- Move to `optional/asus.txt`: `asusctl`, `asusctl-debug`,
  `rog-control-center` (ASUS ROG only — inert on the HP netbook).

## Error handling

- `set -euo pipefail`; a trap that reports the failing line and leaves the
  chroot in a re-runnable state.
- Tolerant package install isolates missing/renamed packages into a report
  instead of aborting.
- `--needed` + tar-overwrite idempotency mean any stage is safe to rerun after
  a fix.
- Detection asserts (mount points, network, disk confirmation) fail loudly
  before any destructive step.

## Testing / validation

No unit harness for an installer. Validation ladder:
1. `bash -n` + `shellcheck` clean on both scripts.
2. VM matrix — cheapest way to exercise the detection branches:
   - Firmware: UEFI (systemd-boot) and BIOS (GRUB).
   - GPU vendor: QEMU virtio/std (generic mesa path), plus a passthrough or
     bare-metal check for at least Intel; AMD/NVIDIA branches validated by the
     package-selection logic even where hardware isn't on hand.
   - 32-bit guard: confirm the x86_64 assertion aborts cleanly on an i686 VM.
3. Idempotency: rerun stage 1 package/extract steps, confirm no breakage.
4. Real hardware: the HP netbook as the live BIOS/GRUB + Intel-GPU target
   (disposable — nothing on it needs preserving).

## Open items carried forward

- Confirm the netbook GPU (`lspci | grep -i vga`) is GMA 3150 (OK), not GMA500.
- Confirm the netbook has no Broadcom wifi (would trigger the §1 flag).
- AMD/NVIDIA graphics branches are designed but not yet run on real silicon;
  validate opportunistically when such a machine is available.
- Verify `optional/asus.txt` packages are irrelevant on non-ASUS before default
  drop (they are, by name).
