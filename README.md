# hevenos

An Arch Linux installer that produces a ready-to-use Wayland desktop — the
[niri](https://github.com/YaLTeR/niri) compositor, fish, kitty and waybar —
in two stages: one in the live ISO, one that finishes itself at first login.

## Requirements

- x86_64 machine with **UEFI** firmware. BIOS/legacy boot is refused.
- An **OpenGL 3.3-class GPU**: roughly Intel HD Graphics 3000 (2011) or newer,
  and any AMD or NVIDIA silicon from 2007 onward. kitty and niri's theme
  shaders both require it. Below-floor GPUs — Intel gen2/gen3 through
  GMA 3150, and the PowerVR GMA 500/600/3600 line — are detected at preflight
  and refused before anything is written to disk. There is no fallback
  desktop; this targets niri/Wayland only.
- A target disk, either prepared by `configure` or by hand.

## Install

Boot the Arch Linux live ISO and run:

```bash
pacman -Sy git
git clone https://github.com/Omniwing/hevenos.git
cd hevenos
./configure      # optional; prepares a whole disk
./install.sh
```

Then reboot and remove the installation media.

### configure

`configure` prepares one entire internal disk and mounts it for `install.sh`:

| Partition | Size | Format | Mounted at |
|---|---:|---|---|
| EFI system | 1 GiB | FAT32 | `/mnt/efi` |
| Swap | 4–8 GiB, from RAM and disk size | swap | — |
| Root | remainder, at least 24 GiB | ext4 | `/mnt` |

It destroys everything on the disk it is given, and asks for two explicit
confirmations first. USB and removable disks, mounted disks, active
RAID/device-mapper stacks, read-only disks and disks too small for a usable
root are never offered as candidates.

Skip it for dual boot or any custom layout: partition the disk yourself and
mount root at `/mnt`. An existing EFI System Partition is found and mounted
automatically — including one belonging to another operating system, which is
added to and never formatted. To choose it yourself, mount it at `/mnt/efi`
beforehand. `/boot` is a regular directory on the root filesystem.

## How it works

**Stage 1** (`install.sh`, as root in the live ISO) detects the hardware, asks
for everything it needs up front — hostname, timezone, user, passwords, and
the NVIDIA driver choice if one applies — then runs unattended: base system,
swap, packages and GPU drivers, bootloader, services, the system files the
desktop needs, WiFi migration, and finally the desktop config unpacked from
`payload/desktop-env.tar.gz`. Nothing after the package stage is allowed to be
fatal, so a package that has been renamed or retired upstream is recorded and
skipped rather than leaving a machine without a bootloader.

**Stage 2** (`stage2.sh`) is left on the target and fires from the login shell
the first time you log in at a console. It upgrades the system and installs
whatever is left — from the official repositories wherever they carry it,
building from the AUR only where that is genuinely the only source — refreshes
the font cache, then removes itself.

## What gets installed

- **Desktop**: niri, waybar, mako, fuzzel, swaybg, swaylock, kitty, fish
- **Applications**: Firefox, Nautilus, Celluloid/mpv — registered as the
  defaults for links, folders, images, PDFs, audio and video
- **Boot**: GRUB with `os-prober`, so any other operating system already on
  the machine keeps its own menu entry
- **System**: NetworkManager with wpa_supplicant, Bluetooth, chrony, acpid,
  pipewire, weekly `fstrim`, and capslock remapped to an extra Super key
- **Drivers** for the detected GPU. ASUS and Broadcom hardware are detected
  automatically and their packages installed without prompting.

WiFi credentials saved in the live ISO are carried over to the installed
system, so it reconnects on first boot without retyping a password.

## First login

Nothing to type: Stage 2 starts on its own at the first console login.

- Interrupted by a missing network or a reboot? It retries at the next login.
- A package that cannot be installed is recorded in
  `~/hevenos-packages-failed.txt`; setup still finishes.
- The temporary passwordless sudo it uses is revoked when it is done, leaving
  everyday `sudo` password-protected.

When it finishes, start the desktop:

```bash
niri
```

## Repository layout

| Path | Contents |
|---|---|
| `packages/core.txt` | Installed on every machine |
| `packages/aur.txt` | Extra packages for Stage 2; empty by default |
| `packages/optional/asus.txt` | Installed when ASUS hardware is detected |
| `packages/optional/{fonts-extra,security-tools}.txt` | Not installed; `pacman -S --needed - < <list>` |
| `payload/desktop-env.tar.gz` | Desktop config: niri, fish, kitty, waybar, GTK, icons, wallpapers, `~/.local/bin` |
| `overlay/` | System files: keyd, default applications, login banner |
| `tests/` | `bash tests/run.sh` |

Every path in the payload is `$HOME`-relative, so the same tarball works for
whatever username is chosen at install time.

## Notes

- Swap is sized for memory pressure, not hibernation; resume-from-disk is not
  configured.
- Partitioning and formatting make old data inaccessible, but are not a secure
  full-device erase.
