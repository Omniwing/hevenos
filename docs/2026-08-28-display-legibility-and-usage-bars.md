# Findings: display legibility + Claude Code usage bars

**Date:** 2026-08-28
**Scope:** Source laptop, driving a Panasonic TH-42PZ80U plasma over HDMI.
**Status:** Both deliverables live and verified on the source machine.
Deployment implications for the payload are flagged but NOT yet implemented.

---

## 1. The display: TH-42PZ80U at 5 feet

### Hardware facts (confirmed, not estimated)

| Fact | Value | Source |
|---|---|---|
| Model | Panasonic TH-42PZ80U, Oct 2008 | user |
| Marketing size | "42-inch class" | — |
| **True diagonal** | **41.6 in** | Panasonic service manual |
| Visible area | 36.2 x 20.4 in | service manual (computed 36.26 — match) |
| Native res | 1920x1080 | EDID-independent, from spec |
| **Computed PPI** | **53.0** | 1920 / 36.26 |
| Viewing distance | ~5 ft (1524 mm) | user |
| One pixel subtends | 1.08 arcmin | derived |

### Root cause of "font is too small"

The TV **reports a 0-byte EDID**:

```
/sys/class/drm/card1-HDMI-A-1: status=connected edid=0B
niri msg -j outputs -> HDMI-A-1 physical_size: null
```

niri cannot know the panel's physical size, so it cannot auto-scale and falls
back to `scale 1`. Nothing was misconfigured — the display simply refused to
identify itself. **Any TV in this deployment fleet may do the same.**

Measured result: text was rendering at **13.7 arcmin** cap height.
ISO 9241-303 sets the *absolute minimum* at 16 and recommends 20-22 — and that
standard assumes normal eyesight.

### The non-obvious rule: scale 1, not scale 2

Compositor scale magnifies *chrome* (bar, gaps, borders) along with text. At
matched legibility to the eye:

| approach | glyph size | terminal |
|---|---|---|
| scale 2 @ kitty 15pt | identical | 76 x 19 |
| **scale 1 @ kitty 20pt** | identical | **118 x 27** |

Same arcminutes, ~42% more rows *and* columns. **Scale 1 wins outright.**
Reach for scale > 1 only when an app cannot set its own font size.

A first attempt using `scale 2` measured 31.6 arcmin — 1.5x the ISO ideal — and
was rejected by the user as too big *while showing less content*. That is the
signature of the scale-vs-font-size mistake.

### Color under a red-shift filter (gammastep -O 3400)

The tint crushes G and B; only red passes at full strength. Measured contrast
loss against `#0A0A0A`:

| accent | contrast loss @3400K | phosphor load |
|---|---|---|
| **amber `#FFB000`** | **30%** | 56% |
| acid lime `#B8FF00` | 47% | 57% |
| green `#00FF41` | 54% | 42% |
| cyan `#00E5FF` | 56% | 63% |
| white `#FFFFFF` | 45% | 100% |

**A green terminal theme actively fights a red night-light filter.** Amber is
the optimum because it is already red-dominant. Shifting green toward
chartreuse/acid-lime recovers much of the loss while still reading as
"terminal green".

Secondary benefit on plasma: amber draws **44% less phosphor power than white**,
which matters for image retention on a 2008 PDP running a static desktop.

### Rendering settings for a ~53 PPI panel

- `font-antialiasing 'grayscale'` — **not** rgba/subpixel. Plasma cells are not
  RGB stripes and the geometry is unknown; subpixel AA causes color fringing.
- `font-hinting 'slight'`
- `cursor-size` 24 -> 48+. An unfindable cursor is a real complaint at 5 ft.
- Low-vision font: `otf-atkinson-hyperlegible` (+ `AtkynsonMono Nerd Font`),
  disambiguates `1/l/I`, `0/O`, `b/d/p/q`.

### Deliverable: `~/.local/bin/bigmode`

Toggle with three configs, all at **scale 1.0**:

| cmd | theme | kitty | cap arcmin | terminal |
|---|---|---|---|---|
| `bigmode c1` | acid-lime phosphor | 20pt | 21.0 | 118x27 |
| `bigmode c2` | amber CRT (recommended) | 20pt | 21.0 | 118x27 |
| `bigmode c3` | high-vis, Atkinson | 22pt | 23.1 | 104x25 |
| `bigmode off` | restore | 13pt | 13.7 | — |

Also `bigger` / `smaller` (live nudge, persisted per config), `toggle`, `status`.

**Safety model:** never edits `~/.config/niri/config.kdl`. Scale is set at
runtime via `niri msg output HDMI-A-1 scale N`, which niri documents as
temporary. Originals archived in `~/.config/bigmode/pristine/`; `off` restores
by `cp` and **verifies with sha256**.

---

## 2. `~/bin/cctok` — Claude Code usage bars in waybar

Two waybar modules showing rolling-window token consumption, read from the
local session transcripts. No network, no daemon, no root, no Node tooling.

```
[ S ███▍··· 49% ]  [ W █▌····· 22% ]
```

### Data source and the three gotchas

`~/.claude/projects/<munged-cwd>/<session-uuid>.jsonl`, one JSON object per
line; assistant turns carry real API accounting at `.message.usage`.

1. **Duplicates are the norm, not an edge case.** Measured on this machine:
   **59.8% of usage-bearing lines are duplicates** (1001 lines -> 402 unique).
   Streaming repeats the same `message.id` with an identical usage block.
   Dedup on `.message.id`, falling back to `.uuid`.
2. **Non-object `.message`** on `summary` and similar line types. Guard with
   `(.message | type) == "object"` or jq aborts.
3. **Live transcript, truncated final line.** The active session file is
   mid-write; jq aborts on the malformed tail. Acceptable (costs the last
   entry) but stderr must be suppressed to keep waybar output clean.

### The decisive finding: weighted, not raw

Measured 7-day raw split on this machine:

```
input 983  cache_write 1,499,928  cache_read 30,656,223  output 575,611
cache_read = 93.66% of all raw tokens
```

**A raw token total is essentially a cache-read meter** and does not track
`/usage` at all. Limits are enforced on *weighted* tokens. Weights applied
(published cache-pricing ratios):

| bucket | weight |
|---|---|
| input | 1x |
| cache write (5m TTL) | 1.25x |
| cache write (1h TTL) | 2x |
| cache read | 0.1x |
| output | 5x |

The transcripts carry `usage.cache_creation.{ephemeral_5m,ephemeral_1h}_input_tokens`,
so the cache-write weight is computed exactly rather than assumed.

Result: 32.7M raw tokens -> **8.94M weighted** over 7 days.

### Design decisions

- **One pass, two windows.** Session (5h) and week (7d) are computed from a
  single read; polling two separate invocations would scan the corpus twice a
  minute for nothing. **70ms** for the full 7-day scan.
- **`find -mmin` prune.** A file older than the window cannot contain entries
  inside it, so the prune is lossless. Corpus is 43MB/198 files total but only
  6.1MB/29 files inside 7 days.
- **Two separate waybar modules**, not one. Different budgets, different reset
  clocks, different alarm conditions — each gets its own slot and its own
  color state, so session can go red while week stays green.
- **Resolution without width.** Module box sizing is kept consistent with every
  other bar module, which caps the bar at 7 cells. Eighth-block partials
  (`▏▎▍▌▋▊▉`) give **56 levels instead of 7** (1.8%/step) in the same footprint.
  The practical win is at low values: 5% renders as `▎······` instead of an
  empty bar.

### Calibration (OUTSTANDING)

Limits are placeholders — `CCTOK_SESSION_LIMIT=2000000`,
`CCTOK_WEEK_LIMIT=40000000`. The bar *shape* is correct; the *scale* is
arbitrary until calibrated. In a Claude Code CLI session:

```
/usage                            # read the two percentages
~/bin/cctok -c <session%> <week%> # prints the two corrected limit lines
```

**Known weakness:** the weights above are published *pricing* ratios used as a
proxy for the undocumented *limit* weights. Calibration fixes the scale, but if
the true limit weights differ in shape (e.g. cache reads counted heavier than
0.1x), the two bars will drift apart at different workload mixes. Two `/usage`
readings taken at very different mixes — one heavy-output, one heavy-context —
would allow solving for the real weights instead of assuming them.

### Test coverage

`/hermes/scratch/cctok_test.sh` — 17/17 passing. Covers dedup, window filter,
non-object `.message`, truncated tail, empty result (awk `END` on empty input),
bash/fish parity, and calibration round-trip.

Two real bugs caught by those tests:

- `%d` truncated weighted values (23.8 -> 23), losing fractional weight on every
  call. Fixed to `%.0f`.
- The first shell-parity test was **vacuous**: both shells expanded `~` to the
  fixture `HOME`, so neither actually executed the script and it passed while
  testing nothing. Fixed to an absolute path.

---

## 3. Deployment implications for this repo

**None of the following has been implemented — flagged only.**

### 3.1 `~/bin` is outside the payload

`tools/build-payload.sh` ships `.local/bin`. `cctok` was installed to **`~/bin`**,
which is a different directory and is not in the tarball's include set. If
`cctok` should travel with the desktop, either move it to `.local/bin` or extend
the payload. `bigmode` lives in `.local/bin` and would travel today.

### 3.2 `cctok` is machine-personal, and arguably should be scrubbed

`build-payload.sh` already strips AI tooling (`claude`, `terminalgpt`) and
personal alerting (`slack_alarm.py`). `cctok` reads `~/.claude/projects` and
carries hand-calibrated account-specific limits. By the existing scrub policy
it looks like a scrub candidate rather than a shipped desktop feature. **This is
a judgement call for the repo owner, not a defect.**

### 3.3 The waybar config now assumes both modules exist

`~/.config/waybar/config` references `custom/cctok` and `custom/cctok-week` in
`modules-left`, replacing `niri/workspaces`. On a target machine without
`~/bin/cctok` those modules render empty. The `niri/workspaces` module
definition is still present in the config but is no longer listed in
`modules-left` — re-adding it is a one-line change.

### 3.4 EDID-less displays are a fleet-wide concern

Any deployment target driving a TV may hit the same 0-byte EDID and silently get
`scale 1` with unreadable text. Worth a preflight note: if
`physical_size: null`, scale cannot be auto-derived and must be set from the
known panel size. The `bigmode` arcminute math generalizes — only the
diagonal and viewing distance change.

### 3.5 Font dependency

`c3` requires `otf-atkinson-hyperlegible` (official repo) and
`otf-atkinsonhyperlegiblemono-nerd`. The latter was already installed on the
source machine; **the former was installed during this session** and may not be
in `pkglist-native.txt` yet.

---

## 4. Process note

Mid-task I corrupted all four waybar CSS files by using a file-reading helper
that returns line-numbered content (`1|* {`) and writing that result straight
back. waybar hit `style.css:1:0 Expected a valid selector` and died.

Recovery was clean — the user's original was restored byte-for-byte
(sha256 `088bd3001fb5b906`, matching the session-start capture) — but **only
because `.pre-cctok` copies had been made before the backups themselves were
refreshed**. Refreshing `pristine/` to include new work is correct; doing it
without first preserving the untouched original would have overwritten the only
good copy with corrupted content.

Rules adopted: **append (`>>`) or `sed -i` for edits to user config files; never
read-modify-write through a helper that decorates its output.** Verify a restore
with a checksum rather than trusting that the copy happened.
