# Open items — flagged, not implemented

Consolidated so these are findable instead of buried in dated findings docs.
Each entry names its source. Nothing here is a defect in shipped behaviour;
these are known gaps and judgement calls.

## 1. zram is not implemented at all

`grep -ri zram` over the whole repo returns nothing.

What *is* implemented is a **swapfile**, and only in the low-RAM case:
`install.sh:256` `setup_swap()` calls `needs_swap "$RAM_KB"` (`lib/detect.sh`,
threshold 2 GiB) and on a match creates a 2 GiB `/swapfile` and appends it to
`/etc/fstab`. Above 2 GiB the installer creates no swap of any kind.

Gaps:

- **zram on the low-RAM target.** The HP netbook baseline (1–2 GiB) is exactly
  the machine where compressed RAM swap beats a file on a slow disk. A
  `zram-generator` config is a smaller change than the swapfile path already
  merged.
- **Nothing above 2 GiB.** No swap means no hibernate and a hard OOM under
  memory pressure, on every normal-RAM target.
- If both land, `setup_swap()` needs to decide between them rather than run
  both — zram plus a disk swapfile at equal priority is a known
  thrash pattern.

## 2. Payload / desktop items

From `docs/2026-08-28-display-legibility-and-usage-bars.md` §3 — all flagged
there, none implemented.

- **§3.1 `~/bin` is outside the payload.** `tools/build-payload.sh` ships
  `.local/bin`. `cctok` was installed to `~/bin`, a different directory not in
  the tarball's include set. `bigmode` is in `.local/bin` and travels today.
- **§3.2 `cctok` is arguably a scrub candidate.** `build-payload.sh` already
  strips AI tooling and personal alerting; `cctok` reads `~/.claude/projects`
  and carries hand-calibrated account-specific limits. Owner's judgement call,
  not a defect.
- **§3.3 The waybar config assumes both cctok modules exist.** `modules-left`
  references `custom/cctok` and `custom/cctok-week`, replacing
  `niri/workspaces`. On a target without `~/bin/cctok` those render empty. The
  `niri/workspaces` definition is still in the config; re-listing it is a
  one-line change.
- **§3.4 EDID-less displays are a fleet-wide concern.** A TV reporting a 0-byte
  EDID gives niri no `physical_size`, so it cannot auto-scale and falls back to
  `scale 1` with unreadable text. Nothing is misconfigured when this happens.
  Worth a preflight note: if `physical_size: null`, scale must be set from the
  known panel size. Prefer font size over compositor scale — at matched
  legibility, `scale 1` + a larger font gave ~42% more rows *and* columns than
  `scale 2`.
- **§3.5 Font dependency.** `c3` requires `otf-atkinson-hyperlegible` (official
  repo) and `otf-atkinsonhyperlegiblemono-nerd`. The former was installed
  mid-session on the source machine and may not be in `pkglist-native.txt`.

## 3. Cosmetic

From `docs/2026-08-12-blueheaven-dual-boot-runbook.md`: `install.sh:150` writes
`default arch` to `loader.conf`. systemd-boot matches entry IDs including the
extension, so strictly it should be `arch.conf`. With two entries `arch.conf`
sorts first and wins anyway.
