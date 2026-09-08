# hevenos on BlueHeaven — dual-boot runbook (corrected from the live machine)

Rewritten 2026-08-12 after a read-only survey of BlueHeaven itself over SSH
(`root@192.168.1.131`, Arch live ISO, ASRock Z690 Phantom Gaming 4). Everything below
is measured from the actual hardware, not inferred. Original `forclaude.md` is unchanged
beside this file.

## What the original runbook got wrong

| Original claim | Reality on the machine |
|---|---|
| One Windows install ("C:"), NVMe p3 is "old E:" | **Two Windows installs.** `nvme0n1p3` = user *Holden*, hive last written **2024-08-20**. `sdb2` = user *Heaven*, hive written **today**. The live one is on the SATA disk. |
| "your C: Windows and its ESP are untouched" | `sdb` has **no ESP**. The live Windows boots from `nvme0n1p1` — the same disk being repartitioned. True, but for a reason the runbook did not state. |
| root will be ~837 G | **~930 G.** There is already ~93 GiB unallocated between p3 and p4 that merges into the new root. |
| clone via `git@github.com:` | SSH clone fails — the live ISO has no key or agent. Repo is public; use HTTPS. |
| "~96M vfat ESP" | Partition is **100 MiB** (96 MiB usable, 70 MiB free). Fine either way — systemd-boot needs ~150 KiB. |
| VMD warning was hedged | **VMD is definitely active.** `0000:00:0e.0` is bound to the vmd driver and `nvme0n1`'s parent chain runs through `pci10000:e0`. The initramfs fix is required, not optional. |
| (not mentioned) | **BitLocker: not present.** Every NTFS volume reports `TYPE="ntfs"`, none report `TYPE="BitLocker"`. No recovery-key risk. |
| (not mentioned) | **Secure Boot: disabled (setup mode).** No blocker for unsigned systemd-boot. |

## Proof that deleting `nvme0n1p3` is safe

The BCD hive from the ESP was parsed with `hivex`:

- `{9dea862c-…}` (Windows Boot Manager) `DEFAULT` → `{4c64389d-cbe3-11ee-…}`
- `{4c64389d-…}` description `"Windows 10"`, device + osdevice → **`sdb2`**
- `DISPLAYORDER` contains that one entry and nothing else
- **No live BCD object references `nvme0n1p3`.** (A raw byte scan finds 3 hits for its
  GUID, but they sit in freed hive cells — the residue of the entry that was already
  deleted, not a live reference.)

So the boot menu has exactly one entry, it points at the live Windows on `sdb2`, and
`nvme0n1p3` is orphaned. Deleting it cannot break Windows.

## Backups already taken (on Ravenclaw, `/root/hevenos/blueheaven-backups/`)

| File | What it restores |
|---|---|
| `nvme0n1-gpt.bak` | full GPT (`sgdisk --load-backup=`) |
| `nvme0n1.sfdisk` | human-readable partition table |
| `esp-nvme0n1p1.img.gz` | byte image of the Windows ESP (gzip-verified) |
| `BCD` | the Windows boot configuration hive |

## The procedure — three commands total

Everything is wrapped in `/root/setup.sh` on the live ISO (md5 `8cbc88d5…`). It refuses to
run unless five guards pass: root on the live overlay, nothing on the NVMe mounted, p3 still
carries the surveyed PARTUUID, p1/p4 still the surveyed ESP and recovery, and `/dev/sdb2`
still readable as a Windows install. Then it asks you to type `YES`.

```bash
/root/setup.sh                      # 1. repartition, format, mount, clone the repo
cd /root/hevenos && ./install.sh    # 2. the installer
/root/after-install.sh              # 3. vmd initramfs fix, then reboot
```

What `setup.sh` does, in order: deletes p3 · creates p3 = 1 GiB XBOOTLDR (`ea00`,
`HEVEN-BOOT`) · creates p5 = rest, ext4 (`8300`, `HEVEN-root`) · `mkfs.fat -F32` on p3 and
`mkfs.ext4` on p5 · mounts p5 at `/mnt`, p3 at `/mnt/boot`, p1 at `/mnt/efi` · **verifies
`bootmgfw.efi` still exists on the ESP** and aborts loudly if not · clones the branch over
HTTPS · writes `after-install.sh`.

Never formatted: `nvme0n1p1` (ESP), `p2` (MSR), `p4` (recovery), and both other disks.

### During `install.sh`

- "Install bootloader to /dev/nvme0n1?" → `y`. Cosmetic on UEFI: `install.sh:146` detects
  the `/mnt/efi` mount and runs `bootctl --esp-path=/efi --boot-path=/boot install`.
- Answer hostname / timezone / user / passwords up front. No NVIDIA prompt is expected —
  no discrete GPU was detected.

### Why step 3 exists

The NVMe sits behind Intel VMD. Without `vmd` in the initramfs the installed system cannot
find its own root filesystem and drops to an emergency shell. `autodetect` usually catches
it; `after-install.sh` makes it certain and verifies the module actually landed in the image
before telling you it is safe to reboot.

## After reboot

- systemd-boot menu (5 s): **Arch Linux (hevenos)** and **Windows Boot Manager**. Windows
  boots the Heaven install on `sdb2` exactly as it does today.
- First login auto-runs stage 2 (AUR packages) — let it finish; it retries on next login if
  interrupted. Then niri starts.

## Notes

- Do NOT switch the BIOS storage mode from RAID/VMD to AHCI — it will break the running
  Windows.
- `install.sh:150` writes `default arch` to `loader.conf`; systemd-boot matches entry IDs
  including the extension, so strictly it should be `arch.conf`. With two entries
  `arch.conf` sorts first and wins anyway. Cosmetic.
- The runbook's optional cleanup, `bcdedit /delete {4c64389a-cbe3-11ee-87e7-b6b7977f3f8b}`,
  targets a **Windows Recovery Environment** entry pointing at `nvme0n1p4` — the recovery
  partition we are keeping, whose OS (the Holden install) is gone. Harmless to leave,
  harmless to remove.
- Rollback: restore the GPT with
  `sgdisk --load-backup=nvme0n1-gpt.bak /dev/nvme0n1`. This brings the table back but not
  the deleted NTFS filesystem — that install is gone once step 1 runs. The live Windows on
  `sdb2` is on a different disk and is never written to.
