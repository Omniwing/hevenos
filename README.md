# Hevenos Deployer

A two-stage Arch Linux installer for replicating a Wayland-based desktop environment (niri compositor, fish shell, custom theming) onto target machines.

## Overview

The deployer consists of two stages:

- **Stage 1** runs in the live ISO as root: base system installation, package lists, bootloader setup, and config deployment.
- **Stage 2** runs after first boot as the regular user: AUR package installation and font cache refresh.

## Prerequisites

- **Partitioned and mounted disks**: Before running `install.sh`, partition and format your target disk(s), then mount the root filesystem at `/mnt`.
- **UEFI systems**: Mount the EFI System Partition (ESP) at `/mnt/boot` **before** running `install.sh`. This prevents the kernel from being shadowed by an empty ESP mounted later during system initialization.
- **BIOS systems**: No ESP required; `/boot` will be a regular directory on the root filesystem.

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

1. **Detect hardware**: Firmware type (UEFI/BIOS), CPU vendor and microcode, GPU vendor, available RAM, network adapters.
2. **Prompt for confirmation**: Disk target, hostname, timezone, username, and root/user passwords.
3. **Install base system**: Base packages, Linux kernel, firmware, microcode, git, NetworkManager, sudo, and editor.
4. **Install packages**: Core desktop packages (niri, waybar, kitty, fish, swaybg, mako, swayidle) and optional lists:
   - `fonts-extra`: Additional font packages for extended Unicode/glyph coverage.
   - `security-tools`: General security utilities (e.g., cryptographic tools, network analysis).
   - `asus`: ASUS-specific drivers and utilities (laptop-specific; enabled via marker file).
5. **Configure bootloader**: systemd-boot on UEFI systems, GRUB (i386-pc) on BIOS systems.
6. **Enable services**: NetworkManager, wpa_supplicant, chrony, Bluetooth, acpid; disable iwd to avoid conflicts.
7. **Deploy config**: Extract the desktop environment tarball, adjust hardcoded paths if the username differs from `omniwing`, and set fish as the login shell.

At the end of Stage 1, reboot and remove the installation media.

## Stage 2: Post-Boot User Setup

After first boot, log in as the regular user (created during Stage 1) and run:

```bash
./stage2.sh
```

This will:

1. **Bootstrap paru**: Install the prebuilt `paru-bin` AUR helper (source builds of paru take hours on older hardware).
2. **Install AUR packages**: Install packages from `packages/aur.txt`.
3. **Install optional AUR packages**: If `fonts-extra` or `asus` were selected during Stage 1, install their respective AUR lists.
4. **Install Broadcom WiFi drivers**: If Broadcom wireless was detected, install `broadcom-wl-dkms`.
5. **Refresh font cache**: Rebuild the font cache for newly installed fonts.

After Stage 2 completes, start the desktop:

```bash
niri
```

## Optional Package Lists

During installation, you will be prompted to optionally install:

- **`fonts-extra`**: Extended font coverage. Marker file: `.hevenos-fonts-extra` (sets flag for Stage 2 if selected).
- **`security-tools`**: Security and cryptography utilities. Marker file: `.hevenos-security-tools`.
- **`asus`**: ASUS laptop-specific tools and drivers. Marker file: `.hevenos-asus` (Stage 2 uses this to install optional ASUS packages).

Broadcom WiFi detection is automatic; if present, Stage 2 will offer to install `broadcom-wl-dkms`.

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
bash -n ./*.sh lib/*.sh tools/*.sh   # Syntax check
bash tests/run.sh                     # Unit tests
```

Expected: All syntax checks pass, 105 tests passed, 0 failed.

## VM Validation Ladder

Before deploying to real hardware, validate the installer across the following environments in order:

1. **Static checks**: Bash syntax validation and unit tests.
   ```bash
   bash -n ./*.sh lib/*.sh tools/*.sh && bash tests/run.sh
   ```
   Expected: Syntax clean; all 105 tests pass.

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
