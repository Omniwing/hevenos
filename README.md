# Hevenos Deployer

A two-stage Arch Linux installer for replicating a Wayland-based desktop environment (niri compositor, fish shell, custom theming) onto target machines.

## Overview

The deployer consists of two stages:

- **Stage 1** runs in the live ISO as root: base system installation, package lists, bootloader setup, and config deployment.
- **Stage 2** runs automatically the first time you log in after reboot (as the regular user): AUR package installation and font cache refresh. No manual step needed — see [Stage 2](#stage-2-post-boot-user-setup) below.

## Prerequisites

- **Partitioned and mounted disks**: Before running `install.sh`, partition and format your target disk(s), then mount the root filesystem at `/mnt`.
- **UEFI systems**: Mount the EFI System Partition (ESP) at `/mnt/boot` **before** running `install.sh`. This prevents the kernel from being shadowed by an empty ESP mounted later during system initialization.
- **BIOS systems**: No ESP required; `/boot` will be a regular directory on the root filesystem.

## Hardware Floor

The desktop has one hard requirement the installer enforces: an **OpenGL
3.3-class GPU** — roughly Intel HD Graphics 3000 (2011) or newer, and any
AMD/NVIDIA silicon from 2007 onward. Two package choices drive this floor:

- **kitty** refuses to start without OpenGL 3.3.
- **niri**'s theme effects are GLES fragment shaders that exceed pre-GL3
  hardware limits (Intel gen3 caps near 64 ALU instructions; the border
  shader alone needs ~253).

Preflight detects the known below-floor GPUs — Intel gen2/gen3 integrated
graphics (through Pineview / GMA 3150, the 2008–2010 Atom netbook line) and
the PowerVR-based GMA 500/600/3600 line, which has no usable 3D driver at
all — and **refuses to install**: no disk write happens. There is no
fallback desktop; this project targets niri/Wayland only. (A separate,
unrelated project — `legacyheven` — is tracking a lighter, theme-free
desktop for hardware below this floor; not part of this repo.) Both PCI-ID
sets are closed (taken verbatim from the kernel's own tables), so the check
never needs maintenance. Everything x86_64 above that floor is fair game.

## Stage 1: Live ISO Installation

Boot the Arch Linux live ISO and run the following commands:

```bash
pacman -Sy git
git clone <repo> hevenos
cd hevenos
./install.sh
```

Replace `<repo>` with the URL of this repository.

The installer will:

1. **Detect hardware**: Firmware type (UEFI/BIOS), CPU vendor and microcode, GPU vendor and OpenGL-floor class (see Hardware Floor above), available RAM, network adapters.
2. **Ask everything up front**: disk-target confirmation, hostname, timezone, username, root/user passwords, and (if an NVIDIA GPU was detected) proprietary-vs-nouveau — all asked back to back before anything long-running starts, so the rest of the install runs unattended.
3. **Install base system**: Base packages, Linux kernel, firmware, microcode, git, NetworkManager, sudo, and editor.
4. **Install packages**: Core desktop packages (niri, waybar, kitty, fish, swaybg, mako, keyd, and other GUI/OS essentials — see `packages/core.txt`) plus driver packages for the detected GPU vendor. If ASUS hardware is detected (see Optional Package Lists below), its AUR packages are queued for automatic installation in Stage 2 — no prompt.
5. **Configure bootloader**: systemd-boot on UEFI systems, GRUB (i386-pc) on BIOS systems.
6. **Enable services**: NetworkManager, wpa_supplicant, chrony, Bluetooth, acpid, keyd; disable iwd to avoid conflicts.
7. **Configure keyd**: Deploy `/etc/keyd/default.conf` (capslock remapped to an extra Super/Mod key) — a system-level file outside the home-relative tarball, recreated on every target.
8. **Migrate WiFi credentials**: The live ISO connects to wifi via `iwd`, not NetworkManager, so those saved credentials don't carry over on their own. Any saved WPA/WPA2-personal network is converted to a NetworkManager connection profile on the target, so it auto-connects on first real boot with no re-entry of the password. (Enterprise wifi or open networks aren't covered by this and fall back to Stage 2's `nmtui` prompt.)
9. **Deploy config**: Extract the desktop environment tarball, adjust hardcoded paths if the username differs from `omniwing`, and set fish as the login shell.

At the end of Stage 1, reboot and remove the installation media.

## Stage 2: Post-Boot User Setup

Stage 2 runs **automatically** — there's nothing to type. The first time you log in at the console (as the regular user created in Stage 1), the login banner detects that setup isn't finished yet and runs `stage2.sh` for you before handing control back:

```
  >> Setup isn't finished — finishing it automatically now.
  >> This installs AUR packages and can take a while on slow hardware.
```

This fires from a `fish_greeting` function (fish is the login shell), with a `.bash_profile` fallback in case fish never became the login shell on a given machine. It only triggers on a plain console/TTY login, not inside an already-running desktop session. If it's interrupted (network hiccup, reboot, walking away) it simply retries on your next login — safe to log out/in or reboot again. Once it succeeds, `stage2.sh` deletes itself and revokes the temporary passwordless-sudo grant Stage 1 set up for the unattended build (everyday `sudo` stays password-protected from then on), so the banner instead greets you with:

```
  >> type 'niri' to start the desktop
```

You can still run `./stage2.sh` manually if you want to watch it run or kick it off before logging out/in.

Stage 2 does the following:

1. **Wait for network**: poll for real DNS resolution rather than assuming it's ready immediately at login; if it's still not up after ~15s, open `nmtui` so you can pick a network, then keep polling.
2. **Full system upgrade, then install AUR packages**: `pacman -Syu` first (time may have passed since Stage 1), then build and install each package in `packages/aur.txt` directly with `makepkg` — no AUR helper. We only ever install a small, fixed, hand-picked list, so paru/yay's extra convenience isn't needed, and it avoids the class of bug where a prebuilt AUR-helper binary is linked against a `libalpm` version that's since moved on.
3. **Install optional AUR packages**: If ASUS hardware was auto-detected during Stage 1 (marker file `.hevenos-asus`), build and install packages from `packages/optional/asus.txt` the same way.
4. **Install Broadcom WiFi drivers**: If Broadcom wireless was detected during Stage 1 (marker file `.hevenos-broadcom`), build and install `broadcom-wl-dkms`.
5. **Refresh font cache**: Rebuild the font cache for newly installed fonts.
6. **Revoke temporary sudo and self-delete**: remove the passwordless-sudo grant and `stage2.sh` itself, marking setup complete.

After Stage 2 completes, start the desktop:

```bash
niri
```

## Optional Package Lists

Nothing here is prompted for — the installer auto-detects what applies and asks nothing:

- **`asus`**: ASUS laptop-specific tools and drivers (AUR packages). Auto-detected from the DMI vendor string (`/sys/class/dmi/id/sys_vendor`) at preflight; a match writes marker file `.hevenos-asus` in Stage 1, which Stage 2 uses to install `packages/optional/asus.txt`.
- **`fonts-extra`** and **`security-tools`**: Native-repo package lists (extended font/Unicode coverage; security and cryptography utilities) kept in the repo for reference, but no longer installed or offered by the installer. Install by hand if wanted: `pacman -S --needed - < packages/optional/<list>.txt`.

Broadcom WiFi detection is likewise automatic; if present, Stage 1 writes marker file `.hevenos-broadcom`, and Stage 2 installs `broadcom-wl-dkms`.

## Configuration

The desktop environment is deployed from `payload/desktop-env.tar.gz`, which contains:

- `.config/niri/config.kdl`: Compositor configuration (spawns waybar, mako, swayidle, swaybg on startup).
- `.config/fish/config.fish`: Fish shell configuration.
- `.config/kitty/`, `.config/waybar/`, `.config/gtk-3.0/`, `.config/gtk-4.0/`: Application configs.
- `.local/bin/`: Custom scripts (e.g., `lid-handler` for laptop power management).
- `.local/share/icons/`: Custom icon sets.
- `Pictures/Wallpapers/`: Wallpaper images (including `cyberpunk-80s-neon.jpg`).

**Hardcoded paths**: The tarball contains three hardcoded `/home/omniwing` paths in `.config/niri/config.kdl` and `.config/fish/config.fish`. If the target username differs, `install.sh` automatically adjusts these paths using `sed`.

## Maintainer Notes

### Payload Updates

The `tools/build-payload.sh` script regenerates the deployment tarball from a source tarball. It:

1. Strips the live OpenAI API key from fish variables (always present in omniwing's config).
2. Removes temporary files, symlinks to AI tools, and vendored utilities.
3. Validates that the key was successfully scrubbed before writing the final archive.

**Important**: Whenever the source config tarball changes:
- Rebuild the payload by running `tools/build-payload.sh <source.tar.gz> payload/desktop-env.tar.gz`.
- **Rotate the OpenAI API key** (fetch a new one from the OpenAI dashboard and update the source before rebuilding).
- The repository **must never contain the live API key**.

### Testing

Run the full static test suite:

```bash
shellcheck ./*.sh lib/*.sh tools/*.sh && bash tests/run.sh   # Static checks (shellcheck) + unit tests
```

Note: `shellcheck` should be installed (e.g. via `pacman -S shellcheck` on Arch, or your distro's package manager elsewhere). For a syntax-only check without shellcheck, use `bash -n ./*.sh lib/*.sh tools/*.sh` as a fallback.

Expected: All static checks pass, 120 tests passed, 0 failed.

## VM Validation Ladder

Before deploying to real hardware, validate the installer across the following environments in order:

1. **Static checks**: Bash style/syntax validation (shellcheck) and unit tests.
   ```bash
   shellcheck ./*.sh lib/*.sh tools/*.sh && bash tests/run.sh
   ```
   Note: Install `shellcheck` if not available (e.g. `pacman -S shellcheck` on Arch). For syntax-only checks without it, use `bash -n ./*.sh lib/*.sh tools/*.sh` as a fallback.
   
   Expected: All checks pass; all 120 tests pass.

2. **Detect smoke test**: Verify hardware detection on each target VM or host.
   ```bash
   sudo ./install.sh --detect
   ```
   Expected: Accurate detection of firmware, CPU, GPU, RAM, and network adapters.

3. **UEFI VM**: Full installation in a virtual machine with UEFI firmware.
   - VM config: OVMF firmware, 4 GiB RAM, 20 GiB disk.
   - Verify: ESP mounted at `/mnt/boot`, systemd-boot installed, successful boot.

4. **BIOS VM**: Full installation in a virtual machine with legacy BIOS firmware.
   - VM config: Seabios firmware, 4 GiB RAM, 20 GiB disk, MBR partition table.
   - Verify: GRUB installed (i386-pc target), successful boot.

5. **GPU vendors**: Test on VMs with different GPU emulations.
   - Virtio: Generic mesa drivers (default).
   - Intel target: Verify on a real machine with Intel integrated graphics (e.g., the HP netbook) if available.
   - Validate GPU package detection and installation.

6. **32-bit abort check**: Confirm that the installer refuses to run on i686.
   - Boot an i686 live ISO.
   - Run `./install.sh`; expect immediate exit with error: "This machine is not x86_64; mainline Arch is x86_64-only."

7. **Real hardware**: Deploy to target machines in production.
   - HP netbook (legacy BIOS, Intel integrated GPU, 1–2 GiB RAM): Baseline for real-world performance.
   - Other machines with varying firmware types, GPUs, and RAM as available.
   - Verify all deployment stages, desktop launch, and basic functionality.
