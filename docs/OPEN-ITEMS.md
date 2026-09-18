# Open items — flagged, not implemented

Consolidated so these are findable instead of buried in dated findings docs.
Each entry names its source. Nothing here is a defect in shipped behaviour;
these are known gaps and judgement calls.

## 1. zram is not implemented

`grep -ri zram` over the whole repo returns nothing.

The fresh whole-disk path now creates a dedicated **swap partition** in
`configure`: RAM-sized within a 4–8 GiB bound and reduced when necessary to
preserve at least 24 GiB for root. `install.sh` adds only that target-local
partition to fstab. The manual-partitioning fallback retains the old behavior:
if no swap partition exists, RAM at or below 2 GiB gets a 2 GiB `/swapfile`,
and higher-RAM machines get no swap.

Gaps:

- **zram on low-RAM targets.** Compressed RAM can still help machines with a
  slow disk. If it lands, priorities must make zram the fast first tier and
  disk swap the lower-priority overflow tier.
- **Manual layouts above 2 GiB still need an explicit swap partition** if swap
  is wanted; only `configure` guarantees one.
- **Hibernation remains intentionally unsupported.** The new 4–8 GiB policy
  is for memory pressure, not resume, which would also require initramfs and
  bootloader configuration.

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
