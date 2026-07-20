# hevenos Deployer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A git-hosted, two-stage installer that turns a freshly partitioned/mounted Arch Linux target (any x86_64 machine, BIOS or UEFI) into <user>'s niri Wayland desktop with minimal prompting.

**Architecture:** All guessable logic (firmware/CPU/GPU/RAM detection, package-list filtering) lives in small, dependency-free, unit-tested helper libraries under `lib/`. `install.sh` (stage 1, run from the live ISO) sources those helpers, detects the hardware, does pacstrap + chroot config + bootloader + tolerant package install + graphics driver + config payload, then hands off to `stage2.sh` (run as the user after first boot) for AUR packages. A separate `tools/build-payload.sh` produces the scrubbed config tarball. Tests are plain-bash assertions (no bats dependency) plus `shellcheck`; integration is a documented VM/hardware ladder.

**Tech Stack:** bash (scripts + tests), fish (login shell + banner), pacman/pacstrap/arch-chroot, systemd-boot (UEFI) / GRUB i386-pc (BIOS), paru-bin (AUR), shellcheck.

## Global Constraints

- **Target arch:** x86_64 only. Abort on 32-bit/i686 (`uname -m` ≠ `x86_64`).
- **No `sudo` in scripts.** Stage 1 runs as root in the live ISO; stage 2 runs as the user and refuses to run as root. Root-required lines only where the stage is already root.
- **Fish syntax for user-facing/interactive helper commands; bash for the installer scripts themselves** (`#!/usr/bin/env bash`, `set -euo pipefail`).
- **Tolerant package install:** intersect the wanted list against `pacman -Slq`; never abort on a missing/renamed package — record it in a report. `--needed` everywhere ⇒ idempotent.
- **tar:** always `cd ~` + relative paths, never `-C $HOME`. `tar xzf` overwrites idempotently. "Cannot stat" warnings are benign — check exit code, not stderr volume.
- **Secrets:** the repo must never contain the live `OPENAI_API_KEY`. Verified by `grep -r OPENAI_API_KEY` finding nothing in `payload/`.
- **AUR helpers are never pacman-installable** — bootstrap `paru-bin` via git clone + `makepkg` (never as root).
- **Bootloader split:** UEFI ⇒ systemd-boot; BIOS ⇒ GRUB (`--target=i386-pc`, whole disk).
- **Only one network daemon:** enable NetworkManager + wpa_supplicant; ensure `iwd` stays disabled.
- **Banner is ASCII-only** (Linux VT font has no emoji/CJK) and uses `uname -n` (not the `hostname` binary).

---

## File Structure

- `install.sh` — stage 1 orchestrator (live ISO). Sources `lib/*.sh`. Supports `--detect` (print detection results and exit; non-destructive) for testing.
- `stage2.sh` — stage 2 (booted system, as user): paru bootstrap + AUR + conditional Broadcom/ASUS.
- `lib/detect.sh` — pure hardware-detection helpers (arch, firmware, ucode, GPU vendor→packages, Broadcom, RAM→swap). All accept injectable inputs for testing.
- `lib/packages.sh` — pure package-list helpers (available/missing filters).
- `lib/ui.sh` — tiny logging/prompt helpers (`say`, `warn`, `die`, `ask_yes_no`, `ask_default`).
- `packages/core.txt`, `packages/aur.txt`, `packages/optional/{fonts-extra,security-tools,asus}.txt` — curated data lists.
- `overlay/fish_greeting.fish` — console login banner (already created).
- `tools/build-payload.sh` — scrub the source tarball → `payload/desktop-env.tar.gz`.
- `payload/desktop-env.tar.gz` — scrubbed config tarball (build artifact, committed).
- `tests/assert.sh` — dependency-free assertion helpers.
- `tests/run.sh` — test runner (sources every `tests/test_*.sh`, reports pass/fail, non-zero on failure).
- `tests/test_detect.sh`, `tests/test_packages.sh`, `tests/test_build_payload.sh`, `tests/test_lists.sh` — unit tests.
- `README.md` — usage + the VM validation ladder.
- `.gitignore` — `scratchpad/`, `tb/`, `*.tmp`.

---

## Task 1: Repo scaffolding + test harness

**Files:**
- Create: `tests/assert.sh`, `tests/run.sh`, `.gitignore`, `lib/.gitkeep`
- Test: `tests/run.sh` itself (self-checks the harness)

**Interfaces:**
- Produces: `assert_eq <actual> <expected> <msg>`, `assert_true <cmd...>`, `assert_false <cmd...>`, `assert_contains <haystack> <needle> <msg>`; a `run.sh` that discovers `tests/test_*.sh`, runs every function named `test_*` they define, and exits non-zero if any assertion failed.

- [ ] **Step 1: Write the assertion library**

Create `tests/assert.sh`:
```bash
# Dependency-free assertion helpers. Sourced by test files.
# On failure, increments FAILED and prints a diagnostic; never exits (so all
# tests run). run.sh inspects FAILED.
: "${FAILED:=0}"
: "${PASSED:=0}"

assert_eq() { # actual expected msg
    if [[ "$1" == "$2" ]]; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        printf 'FAIL: %s\n  expected: %q\n  actual:   %q\n' "$3" "$2" "$1" >&2
    fi
}

assert_contains() { # haystack needle msg
    if [[ "$1" == *"$2"* ]]; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        printf 'FAIL: %s\n  %q does not contain %q\n' "$3" "$1" "$2" >&2
    fi
}

assert_true() { # cmd...
    if "$@"; then PASSED=$((PASSED + 1));
    else FAILED=$((FAILED + 1)); printf 'FAIL: expected success: %q\n' "$*" >&2; fi
}

assert_false() { # cmd...
    if "$@"; then FAILED=$((FAILED + 1)); printf 'FAIL: expected failure: %q\n' "$*" >&2;
    else PASSED=$((PASSED + 1)); fi
}
```

- [ ] **Step 2: Write the test runner**

Create `tests/run.sh`:
```bash
#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
source ./assert.sh

shopt -s nullglob
for f in test_*.sh; do
    # shellcheck disable=SC1090
    source "./$f"
done

# Run every function named test_*
for fn in $(declare -F | awk '{print $3}' | grep '^test_'); do
    "$fn"
done

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
```

- [ ] **Step 3: Add a self-check test and .gitignore**

Create `tests/test_harness.sh`:
```bash
test_harness_eq() {
    assert_eq "abc" "abc" "identical strings are equal"
    assert_contains "hello world" "world" "substring match"
    assert_true true
    assert_false false
}
```
Create `.gitignore`:
```
scratchpad/
tb/
*.tmp
```
Create empty `lib/.gitkeep`.

- [ ] **Step 4: Run the harness**

Run: `bash tests/run.sh`
Expected: `4 passed, 0 failed` and exit code 0.

- [ ] **Step 5: Commit**

```bash
git add tests/ .gitignore lib/.gitkeep
git commit -m "test: add dependency-free assertion harness and runner"
```

---

## Task 2: Detection library (`lib/detect.sh`)

**Files:**
- Create: `lib/detect.sh`
- Test: `tests/test_detect.sh`

**Interfaces:**
- Produces (all pure; each takes injectable input as `$1`, falling back to live probes):
  - `is_x86_64 [arch]` → exit 0 if `x86_64`
  - `detect_firmware [efi_size_path]` → prints `uefi` | `bios`
  - `ucode_for_vendor <vendor_id>` → prints `intel-ucode` | `amd-ucode` | `` (empty)
  - `detect_gpu_vendor <lspci_text>` → prints `nvidia` | `amd` | `intel` | `other` (NVIDIA wins on hybrid)
  - `gpu_packages <vendor>` → prints space-separated package list
  - `has_broadcom_wifi <lspci_lsusb_text>` → exit 0 if a Broadcom BCM43xx wifi part is present
  - `needs_swap <ram_kb> [threshold_kb]` → exit 0 if `ram_kb ≤ threshold` (default 2 GiB = 2097152)

- [ ] **Step 1: Write failing tests**

Create `tests/test_detect.sh`:
```bash
source "$(dirname "$0")/../lib/detect.sh"

test_is_x86_64() {
    assert_true  is_x86_64 x86_64
    assert_false is_x86_64 i686
    assert_false is_x86_64 aarch64
}

test_detect_firmware() {
    tmp="$(mktemp)"; touch "$tmp"
    assert_eq "$(detect_firmware "$tmp")" "uefi" "existing efi size file => uefi"
    rm -f "$tmp"
    assert_eq "$(detect_firmware "/nonexistent/efi/size")" "bios" "missing => bios"
}

test_ucode_for_vendor() {
    assert_eq "$(ucode_for_vendor GenuineIntel)" "intel-ucode" "intel"
    assert_eq "$(ucode_for_vendor AuthenticAMD)" "amd-ucode" "amd"
    assert_eq "$(ucode_for_vendor SomethingElse)" "" "unknown => empty"
}

test_detect_gpu_vendor() {
    assert_eq "$(detect_gpu_vendor 'VGA compatible controller: Intel Corporation Atom')" intel "intel"
    assert_eq "$(detect_gpu_vendor 'VGA compatible controller: Advanced Micro Devices AMD/ATI Radeon')" amd "amd"
    assert_eq "$(detect_gpu_vendor 'VGA compatible controller: NVIDIA Corporation GK107')" nvidia "nvidia"
    # Hybrid Intel + NVIDIA laptop: NVIDIA wins
    assert_eq "$(detect_gpu_vendor 'Intel Corporation UHD Graphics
NVIDIA Corporation GP108M')" nvidia "hybrid => nvidia"
    assert_eq "$(detect_gpu_vendor 'Red Hat, Inc. Virtio GPU')" other "vm => other"
}

test_gpu_packages() {
    assert_eq "$(gpu_packages intel)"  "mesa vulkan-intel intel-media-driver" "intel pkgs"
    assert_eq "$(gpu_packages amd)"    "mesa vulkan-radeon libva-mesa-driver" "amd pkgs"
    assert_eq "$(gpu_packages nvidia)" "mesa" "nvidia default => nouveau via mesa"
    assert_eq "$(gpu_packages other)"  "mesa" "fallback => mesa"
}

test_has_broadcom_wifi() {
    assert_true  has_broadcom_wifi 'Network controller: Broadcom Inc. BCM4312 802.11b/g LP-PHY'
    assert_false has_broadcom_wifi 'Network controller: Intel Corporation Wireless 7260'
}

test_needs_swap() {
    assert_true  needs_swap 1048576          # 1 GiB
    assert_true  needs_swap 2097152          # exactly 2 GiB
    assert_false needs_swap 8388608          # 8 GiB
    assert_true  needs_swap 4194304 8388608  # custom threshold
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/run.sh`
Expected: FAIL — `lib/detect.sh` does not exist / functions undefined.

- [ ] **Step 3: Implement `lib/detect.sh`**

Create `lib/detect.sh`:
```bash
# Pure hardware-detection helpers. Each accepts an injectable argument (for
# tests) and falls back to a live probe when called with none.

is_x86_64() {
    local arch="${1:-$(uname -m)}"
    [[ "$arch" == "x86_64" ]]
}

detect_firmware() {
    local size_path="${1:-/sys/firmware/efi/fw_platform_size}"
    if [[ -e "$size_path" ]]; then echo uefi; else echo bios; fi
}

cpu_vendor() { awk -F': ' '/^vendor_id/{print $2; exit}' /proc/cpuinfo; }

ucode_for_vendor() {
    case "$1" in
        GenuineIntel) echo intel-ucode ;;
        AuthenticAMD) echo amd-ucode ;;
        *)            echo "" ;;
    esac
}

detect_gpu_vendor() {
    local out="$1"
    if   grep -qi 'nvidia' <<<"$out"; then echo nvidia
    elif grep -qiE 'amd|ati|radeon' <<<"$out"; then echo amd
    elif grep -qi 'intel' <<<"$out"; then echo intel
    else echo other; fi
}

gpu_packages() {
    case "$1" in
        intel)  echo "mesa vulkan-intel intel-media-driver" ;;
        amd)    echo "mesa vulkan-radeon libva-mesa-driver" ;;
        nvidia) echo "mesa" ;;   # nouveau (in-kernel DRM + mesa GL) is the default
        *)      echo "mesa" ;;
    esac
}

has_broadcom_wifi() {
    grep -qiE 'broadcom.*(bcm43|802\.11|wireless)|BCM43[0-9]' <<<"$1"
}

needs_swap() {
    local ram_kb="$1" threshold_kb="${2:-2097152}"
    [[ "$ram_kb" -le "$threshold_kb" ]]
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: all detect tests PASS, `... passed, 0 failed`.

- [ ] **Step 5: shellcheck + commit**

Run: `shellcheck lib/detect.sh tests/test_detect.sh`
Expected: no errors.
```bash
git add lib/detect.sh tests/test_detect.sh
git commit -m "feat: add unit-tested hardware detection helpers"
```

---

## Task 3: Package-list helpers (`lib/packages.sh`)

**Files:**
- Create: `lib/packages.sh`
- Test: `tests/test_packages.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `available_pkgs <repo_list_file> <wanted_list_file>` → prints wanted ∩ repo (one per line, sorted-unique)
  - `missing_pkgs <repo_list_file> <wanted_list_file>` → prints wanted − repo (the stragglers)

- [ ] **Step 1: Write failing tests**

Create `tests/test_packages.sh`:
```bash
source "$(dirname "$0")/../lib/packages.sh"

_mkfile() { local f; f="$(mktemp)"; printf '%s\n' "$@" > "$f"; echo "$f"; }

test_available_pkgs() {
    repo="$(_mkfile niri kitty fish mesa nmap)"
    want="$(_mkfile kitty fish bogus-pkg nmap)"
    got="$(available_pkgs "$repo" "$want" | tr '\n' ' ')"
    assert_eq "$got" "fish kitty nmap " "intersection, sorted"
    rm -f "$repo" "$want"
}

test_missing_pkgs() {
    repo="$(_mkfile niri kitty fish mesa nmap)"
    want="$(_mkfile kitty fish bogus-pkg nmap)"
    got="$(missing_pkgs "$repo" "$want" | tr '\n' ' ')"
    assert_eq "$got" "bogus-pkg " "only the straggler"
    rm -f "$repo" "$want"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/run.sh`
Expected: FAIL — `available_pkgs` undefined.

- [ ] **Step 3: Implement `lib/packages.sh`**

Create `lib/packages.sh`:
```bash
# Pure package-list filtering. Ignores blank lines and '#' comments in the
# wanted list so the curated files can be annotated.

_clean_list() { grep -vE '^\s*(#|$)' "$1" | sort -u; }

available_pkgs() { # repo_list wanted_list
    comm -12 <(sort -u "$1") <(_clean_list "$2")
}

missing_pkgs() {   # repo_list wanted_list
    comm -13 <(sort -u "$1") <(_clean_list "$2")
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: all PASS.

- [ ] **Step 5: shellcheck + commit**

Run: `shellcheck lib/packages.sh tests/test_packages.sh`
```bash
git add lib/packages.sh tests/test_packages.sh
git commit -m "feat: add tolerant package-list filter helpers"
```

---

## Task 4: Curated package lists

**Files:**
- Create: `packages/core.txt`, `packages/aur.txt`, `packages/optional/fonts-extra.txt`, `packages/optional/security-tools.txt`, `packages/optional/asus.txt`
- Test: `tests/test_lists.sh`

**Interfaces:**
- Consumes: `_clean_list` semantics from Task 3 (comment/blank tolerant).
- Produces: the data the installer reads. Invariants enforced by tests below.

- [ ] **Step 1: Write the invariant tests**

Create `tests/test_lists.sh`:
```bash
_root="$(dirname "$0")/.."
_has() { grep -qxF "$2" "$_root/$1"; }   # file pkg

test_core_keeps_required() {
    for p in niri waybar mako swaybg fuzzel kitty fish nano vim nmap \
             pipewire wireplumber pavucontrol sof-firmware alsa-utils \
             networkmanager wpa_supplicant wireguard-tools bluez \
             vulkan-icd-loader swaylock playerctl cmatrix keyd \
             xdg-desktop-portal xdg-desktop-portal-gtk firefox \
             ttf-jetbrains-mono-nerd ttf-nerd-fonts-symbols \
             ttf-nerd-fonts-symbols-mono; do
        assert_true _has packages/core.txt "$p"
    done
}

test_core_excludes_dropped() {
    for p in steam discord waydroid rpi-imager greetd greetd-tuigreet \
             paru yay alacritty cool-retro-term xterm starship \
             blackarch-mirrorlist bully reaver wifite pixiewps \
             mesa vulkan-intel lib32-mesa; do
        assert_false _has packages/core.txt "$p"
    done
}

test_optional_lists_content() {
    assert_true  _has packages/optional/security-tools.txt aircrack-ng
    assert_false _has packages/optional/security-tools.txt nmap   # nmap is core
    assert_true  _has packages/optional/asus.txt asusctl
    assert_true  _has packages/optional/fonts-extra.txt ttf-iosevka-nerd
}

test_aur_curation() {
    assert_true  _has packages/aur.txt paru-bin  # NOT part of list -> see note
    :
}
```
Note: `paru-bin` is bootstrapped by stage 2, NOT listed in `aur.txt`. Replace the `test_aur_curation` body with the real invariants:
```bash
test_aur_curation() {
    for p in battop byobu ipscan-bin elio; do assert_true _has packages/aur.txt "$p"; done
    for p in neofetch-git asusctl rog-control-center; do
        assert_false _has packages/aur.txt "$p"
    done
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/run.sh`
Expected: FAIL — list files absent.

- [ ] **Step 3: Create `packages/core.txt`**

Derive from the source `pkglist-native.txt` (187 entries) applying the spec's curation rules. Create `packages/core.txt` (one package per line; the exhaustive kept set):
```
7zip
acpid
alsa-utils
base
base-devel
bluez
bluez-utils
brightnessctl
broot
btop
chrony
cmatrix
cpupower
firefox
fish
fuzzel
git
jq
keyd
kitty
libnotify
linux
linux-firmware
linux-headers
mako
man-db
man-pages
nano
networkmanager
niri
nmap
openssh
pavucontrol
picocom
pipewire
playerctl
power-profiles-daemon
powertop
python-pip
python-pipx
rsync
sof-firmware
swaybg
swaylock
tmux
ttf-jetbrains-mono-nerd
ttf-nerd-fonts-symbols
ttf-nerd-fonts-symbols-mono
unrar
unzip
vim
vulkan-icd-loader
waybar
wayland
wayland-protocols
wget
wireguard-tools
wireplumber
wpa_supplicant
xdg-desktop-portal
xdg-desktop-portal-gtk
xorg-xwayland
xwayland-satellite
zoxide
```
(Note: `mesa`/`vulkan-intel` are intentionally absent — installed by the graphics-detection step. `wpa_supplicant` is listed explicitly though it also comes as an NM dependency.)

- [ ] **Step 4: Create the optional lists**

Create `packages/optional/security-tools.txt`:
```
aircrack-ng
hashcat
hcxdumptool
hcxtools
hostapd
macchanger
netdiscover
python-scapy
termshark
```
Create `packages/optional/asus.txt`:
```
asusctl
asusctl-debug
rog-control-center
```
Create `packages/optional/fonts-extra.txt` — the ~78 remaining Nerd Font packages from `pkglist-native.txt` (every `ttf-*-nerd` / `otf-*-nerd` EXCEPT the three in core). Generate with:
```bash
grep -E '^(ttf|otf)-.*-nerd' /mnt/saves/arthurcomp/pkglist-native.txt \
  | grep -vxE 'ttf-jetbrains-mono-nerd|ttf-nerd-fonts-symbols|ttf-nerd-fonts-symbols-mono' \
  | sort -u > packages/optional/fonts-extra.txt
```
Verify it contains `ttf-iosevka-nerd` and NOT `ttf-jetbrains-mono-nerd`.

- [ ] **Step 5: Create `packages/aur.txt`**

Create `packages/aur.txt`:
```
battop
byobu
elio
ipscan-bin
```
(Dropped: `neofetch-git` dead; `asusctl*`/`rog-control-center` → `optional/asus.txt`. `paru-bin` is bootstrapped by stage 2, not listed here.)

- [ ] **Step 6: Fix the test file per the Step-1 note, then run**

Apply the corrected `test_aur_curation` body from Step 1's note.
Run: `bash tests/run.sh`
Expected: all list tests PASS.

- [ ] **Step 7: Commit**

```bash
git add packages/ tests/test_lists.sh
git commit -m "feat: add curated core/aur/optional package lists"
```

---

## Task 5: Payload build tool (`tools/build-payload.sh`)

**Files:**
- Create: `tools/build-payload.sh`
- Test: `tests/test_build_payload.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `build-payload <source_tarball> <output_tarball>` — extracts source, removes the OpenAI key line from `.config/fish/fish_variables`, deletes the `fish_variables*` temp file, and the `.local/bin/{claude,terminalgpt,uv,uvx}` entries, then rebuilds with `cd <root>` + relative paths. Prints a summary. Exit non-zero if the key survives.

- [ ] **Step 1: Write the failing test (with a synthetic fixture)**

Create `tests/test_build_payload.sh`:
```bash
source "$(dirname "$0")/../tools/build-payload.sh" 2>/dev/null || true

test_build_payload_scrubs() {
    work="$(mktemp -d)"
    src_root="$work/src"
    mkdir -p "$src_root/.config/fish" "$src_root/.local/bin"
    printf 'SETUVAR --export OPENAI_API_KEY:sk\\x2dproj\\x2dLEAK\n' \
        > "$src_root/.config/fish/fish_variables"
    printf 'SETUVAR __fish_initialized:4300\n' \
        >> "$src_root/.config/fish/fish_variables"
    : > "$src_root/.config/fish/fish_variablescV1lM2c1Kr"
    ln -s /nonexistent/claude      "$src_root/.local/bin/claude"
    ln -s /nonexistent/terminalgpt "$src_root/.local/bin/terminalgpt"
    printf 'binary' > "$src_root/.local/bin/uv"
    printf 'binary' > "$src_root/.local/bin/uvx"
    printf '#!/bin/sh\n' > "$src_root/.local/bin/lid-handler"
    ( cd "$src_root" && tar czf "$work/src.tar.gz" . )

    build_payload "$work/src.tar.gz" "$work/out.tar.gz"

    listing="$(tar tzf "$work/out.tar.gz")"
    assert_false grep -q 'OPENAI_API_KEY' <(tar xzf "$work/out.tar.gz" -O ./.config/fish/fish_variables)
    assert_false grep -q 'claude'        <<<"$listing"
    assert_false grep -q 'terminalgpt'   <<<"$listing"
    assert_false grep -q '/uv$'          <<<"$listing"
    assert_false grep -q '/uvx$'         <<<"$listing"
    assert_false grep -q 'fish_variablescV1lM2c1Kr' <<<"$listing"
    assert_contains "$listing" 'lid-handler' "keeps unrelated files"
    assert_contains "$(tar xzf "$work/out.tar.gz" -O ./.config/fish/fish_variables)" '__fish_initialized' "keeps other setuvars"
    rm -rf "$work"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — `build_payload` undefined.

- [ ] **Step 3: Implement `tools/build-payload.sh`**

Create `tools/build-payload.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

# Rebuild the config tarball with all AI credentials/tooling scrubbed out.
# Usage: build-payload <source.tar.gz> <output.tar.gz>
build_payload() {
    local src="$1" out="$2"
    local work root
    work="$(mktemp -d)"; root="$work/root"
    mkdir -p "$root"
    tar xzf "$src" -C "$root"

    # 1. Strip the live OpenAI key line (keep every other SETUVAR).
    local fv="$root/.config/fish/fish_variables"
    if [[ -f "$fv" ]]; then
        grep -v 'OPENAI_API_KEY' "$fv" > "$fv.new" && mv "$fv.new" "$fv"
    fi
    # 2-4. Remove temp file, AI symlinks, vendored uv/uvx.
    rm -f "$root/.config/fish/"fish_variables?*   # atomic-write leftovers only
    rm -f "$root/.local/bin/claude" "$root/.local/bin/terminalgpt" \
          "$root/.local/bin/uv" "$root/.local/bin/uvx"

    # Rebuild with relative paths (never -C $HOME semantics on real home).
    ( cd "$root" && tar czf "$out" . )
    rm -rf "$work"

    # Fail loud if the key somehow survived.
    if tar xzf "$out" -O ./.config/fish/fish_variables 2>/dev/null | grep -q OPENAI_API_KEY; then
        echo "ERROR: OPENAI_API_KEY still present in $out" >&2
        return 1
    fi
    echo "Scrubbed payload written to $out"
}

# Allow running as a script as well as sourcing for tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    build_payload "$@"
fi
```
Note on the glob: `fish_variables?*` matches the temp leftover `fish_variablescV1lM2c1Kr` but NOT the exact-named `fish_variables`. Enable `shopt -s nullglob` at top if the glob may not match; here `rm -f` tolerates a literal no-match, but add `shopt -s nullglob` to avoid removing a file literally named `fish_variables?*`. Update the script: add `shopt -s nullglob` after `set -euo pipefail`.

- [ ] **Step 4: Apply the nullglob fix and run the test**

Add `shopt -s nullglob` under the `set` line in `tools/build-payload.sh`.
Run: `bash tests/run.sh`
Expected: all build-payload assertions PASS.

- [ ] **Step 5: Build the real payload + shellcheck + commit**

```bash
mkdir -p payload
bash tools/build-payload.sh /mnt/saves/arthurcomp/desktop-env.tar.gz payload/desktop-env.tar.gz
grep -rq OPENAI_API_KEY payload/ && echo "LEAK" || echo "clean"   # expect: clean
shellcheck tools/build-payload.sh
git add tools/build-payload.sh tests/test_build_payload.sh payload/desktop-env.tar.gz
git commit -m "feat: add payload scrub tool and build the clean tarball"
```

---

## Task 6: UI helpers (`lib/ui.sh`)

**Files:**
- Create: `lib/ui.sh`
- Test: `tests/test_ui.sh`

**Interfaces:**
- Produces:
  - `say <msg>` / `warn <msg>` / `die <msg>` (die exits 1) — to stderr, prefixed.
  - `ask_default <prompt> <default>` → echoes user input or the default (reads from stdin; honors a non-tty by returning the default).
  - `ask_yes_no <prompt> <default:y|n>` → exit 0 for yes, 1 for no; default used on empty/non-tty input.

- [ ] **Step 1: Write failing tests**

Create `tests/test_ui.sh`:
```bash
source "$(dirname "$0")/../lib/ui.sh"

test_ask_default_uses_default_on_empty() {
    assert_eq "$(printf '\n' | ask_default 'Host?' 'archbox')" "archbox" "empty => default"
    assert_eq "$(printf 'myhost\n' | ask_default 'Host?' 'archbox')" "myhost" "input wins"
}

test_ask_yes_no_default() {
    assert_true  bash -c 'source lib/ui.sh; printf "\n" | ask_yes_no "OK?" y'
    assert_false bash -c 'source lib/ui.sh; printf "\n" | ask_yes_no "OK?" n'
    assert_true  bash -c 'source lib/ui.sh; printf "y\n" | ask_yes_no "OK?" n'
    assert_false bash -c 'source lib/ui.sh; printf "n\n" | ask_yes_no "OK?" y'
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/run.sh`  → FAIL (functions undefined).

- [ ] **Step 3: Implement `lib/ui.sh`**

Create `lib/ui.sh`:
```bash
# Minimal logging + prompt helpers. Prompts read stdin so they are testable
# and degrade to the default on EOF / non-interactive input.

say()  { printf '\033[1;36m::\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

ask_default() { # prompt default
    local prompt="$1" default="$2" reply
    printf '%s [%s]: ' "$prompt" "$default" >&2
    IFS= read -r reply || true
    [[ -n "$reply" ]] && echo "$reply" || echo "$default"
}

ask_yes_no() { # prompt default(y|n)
    local prompt="$1" default="$2" reply
    printf '%s [%s/%s]: ' "$prompt" \
        "$([[ $default == y ]] && echo Y || echo y)" \
        "$([[ $default == n ]] && echo N || echo n)" >&2
    IFS= read -r reply || true
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy] ]]
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh`  → all PASS.

- [ ] **Step 5: shellcheck + commit**

```bash
shellcheck lib/ui.sh tests/test_ui.sh
git add lib/ui.sh tests/test_ui.sh
git commit -m "feat: add logging and prompt UI helpers"
```

---

## Task 7: Stage 1 installer (`install.sh`)

**Files:**
- Create: `install.sh`
- Test: manual `--detect` run + `shellcheck` (end-to-end needs a VM; covered in Task 9)

**Interfaces:**
- Consumes: all of `lib/detect.sh`, `lib/packages.sh`, `lib/ui.sh`; reads `packages/*.txt`, `overlay/fish_greeting.fish`, `payload/desktop-env.tar.gz`.
- Produces: a configured system under `/mnt` and a `stage2.sh` copy plus marker files (`/mnt/home/<user>/.hevenos-broadcom`, `.hevenos-asus`) consumed by stage 2.

- [ ] **Step 1: Write `install.sh` — header, sourcing, `--detect` mode**

Create `install.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/ui.sh"
source "$HERE/lib/detect.sh"
source "$HERE/lib/packages.sh"

MNT="${HEVENOS_MNT:-/mnt}"

detect_all() {
    is_x86_64 || die "This machine is not x86_64; mainline Arch is x86_64-only."
    FIRMWARE="$(detect_firmware)"
    UCODE="$(ucode_for_vendor "$(cpu_vendor)")"
    GPU="$(detect_gpu_vendor "$(lspci 2>/dev/null || true)")"
    GPU_PKGS="$(gpu_packages "$GPU")"
    RAM_KB="$(awk '/MemTotal/{print $2; exit}' /proc/meminfo)"
    if has_broadcom_wifi "$(lspci 2>/dev/null; lsusb 2>/dev/null)"; then
        BROADCOM=yes; else BROADCOM=no; fi
    ROOT_SRC="$(findmnt -no SOURCE "$MNT" 2>/dev/null || echo '?')"
    DISK="/dev/$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -1)"
}

print_detection() {
    cat >&2 <<EOF
  firmware : $FIRMWARE
  ucode    : ${UCODE:-<none>}
  gpu      : $GPU  ->  $GPU_PKGS
  ram (kB) : $RAM_KB  (swap: $(needs_swap "$RAM_KB" && echo yes || echo no))
  broadcom : $BROADCOM
  target   : $MNT on $ROOT_SRC (disk $DISK)
EOF
}

if [[ "${1:-}" == "--detect" ]]; then
    detect_all; print_detection; exit 0
fi
```

- [ ] **Step 2: Verify `--detect` runs non-destructively**

Run: `bash install.sh --detect`
Expected: prints the six detection lines and exits 0 (values reflect the dev/VM host; `target`/`disk` may show `?` if `/mnt` isn't mounted — that's fine here).
Run: `shellcheck install.sh`
Expected: clean (or only benign SC2034 for later-used vars).

- [ ] **Step 3: Add preflight + base install**

Append to `install.sh` (before the `--detect` early-exit block; move the early-exit to the very end, or guard the main flow under `else`). Add:
```bash
preflight() {
    [[ $EUID -eq 0 ]] || die "Stage 1 must run as root in the live ISO."
    mountpoint -q "$MNT" || die "$MNT is not mounted. Partition/format/mount first."
    if [[ "$FIRMWARE" == uefi ]]; then
        mountpoint -q "$MNT/boot" || die "UEFI: mount the ESP at $MNT/boot before running (avoids kernel shadowing)."
    fi
    ping -c1 -W3 archlinux.org >/dev/null 2>&1 || warn "Network check failed; continuing but pacstrap may fail."
    say "Target disk for bootloader: $DISK"
    ask_yes_no "Install bootloader to $DISK?" y || die "Aborted at disk confirmation."
}

base_install() {
    say "Refreshing package databases"
    pacman -Sy --noconfirm
    say "pacstrap base system + microcode ($UCODE)"
    # shellcheck disable=SC2086
    pacstrap "$MNT" base base-devel linux linux-firmware linux-headers \
        git networkmanager wpa_supplicant sudo vim nano $UCODE
    genfstab -U "$MNT" >> "$MNT/etc/fstab"
}
```

- [ ] **Step 4: Add chroot config (users, locale, path fix)**

Append helper that runs inside the chroot via a heredoc. Add to `install.sh`:
```bash
configure_system() {
    local host tz user
    host="$(ask_default 'Hostname' 'archbox')"
    tz="$(ask_default 'Timezone (Region/City)' 'America/New_York')"
    user="$(ask_default 'Username' '<user>')"
    say "Set the ROOT password:"; local rootpw; rootpw="$(_read_secret)"
    say "Set the password for $user:"; local userpw; userpw="$(_read_secret)"

    HEVENOS_USER="$user"   # exported for later steps

    arch-chroot "$MNT" /bin/bash -euo pipefail <<CHROOT
ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime
hwclock --systohc || true
sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf
echo '$host' > /etc/hostname
mkinitcpio -P
echo 'root:$rootpw' | chpasswd
id -u '$user' >/dev/null 2>&1 || useradd -m -G wheel -s /usr/bin/fish '$user'
echo '$user:$userpw' | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
CHROOT

    # Username path fix across the (soon-to-be-extracted) config; done post-extract.
}

_read_secret() { local a b; read -rs a >&2; echo >&2; read -rs b >&2; echo >&2;
    [[ "$a" == "$b" ]] || die "Passwords did not match."; echo "$a"; }
```

- [ ] **Step 5: Add bootloader (firmware split), services, swap**

Append to `install.sh`:
```bash
install_bootloader() {
    local root_uuid; root_uuid="$(findmnt -no UUID "$MNT")"
    if [[ "$FIRMWARE" == uefi ]]; then
        arch-chroot "$MNT" bootctl install
        cat > "$MNT/boot/loader/loader.conf" <<EOF
default arch
timeout 3
EOF
        {
            echo "title   Arch Linux (hevenos)"
            echo "linux   /vmlinuz-linux"
            [[ -n "$UCODE" ]] && echo "initrd  /$UCODE.img"
            echo "initrd  /initramfs-linux.img"
            echo "options root=UUID=$root_uuid rw"
        } > "$MNT/boot/loader/entries/arch.conf"
    else
        arch-chroot "$MNT" grub-install --target=i386-pc "$DISK"
        arch-chroot "$MNT" grub-mkconfig -o /boot/grub/grub.cfg
    fi
}

enable_services() {
    arch-chroot "$MNT" systemctl enable NetworkManager wpa_supplicant chrony bluetooth acpid
    arch-chroot "$MNT" systemctl disable iwd 2>/dev/null || true
}

setup_swap() {
    needs_swap "$RAM_KB" || return 0
    say "Low RAM detected; creating 2 GiB swapfile"
    arch-chroot "$MNT" /bin/bash -euo pipefail <<'CHROOT'
fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
chmod 600 /swapfile
mkswap /swapfile
echo '/swapfile none swap defaults 0 0' >> /etc/fstab
CHROOT
}
```
Note: `chrony`/`bluetooth`/`acpid` units exist only after their packages are installed. Order: run `enable_services` AFTER `install_packages`. Reflect this in the `main` ordering (Step 8).

- [ ] **Step 6: Add package install + graphics driver**

Append to `install.sh`:
```bash
install_list() { # path-to-list  label
    local list="$1" label="$2" repo avail
    repo="$(mktemp)"; arch-chroot "$MNT" pacman -Slq | sort -u > "$repo"
    avail="$(available_pkgs "$repo" "$list" | tr '\n' ' ')"
    say "Installing $label: $(wc -w <<<"$avail") packages"
    # shellcheck disable=SC2086
    [[ -n "${avail// }" ]] && arch-chroot "$MNT" pacman -S --needed --noconfirm $avail
    missing_pkgs "$repo" "$list" >> "$MNT/root/missing.txt"
    rm -f "$repo"
}

install_packages() {
    arch-chroot "$MNT" pacman -Sy --noconfirm
    : > "$MNT/root/missing.txt"
    install_list "$HERE/packages/core.txt" "core desktop"

    say "Graphics: $GPU"
    if [[ "$GPU" == nvidia ]]; then
        if ask_yes_no "NVIDIA: install proprietary driver instead of nouveau?" n; then
            GPU_PKGS="nvidia nvidia-utils"
            # kms modules for early modeset
            arch-chroot "$MNT" sed -i 's/^MODULES=(\(.*\))/MODULES=(\1 nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
        fi
    fi
    # shellcheck disable=SC2086
    arch-chroot "$MNT" pacman -S --needed --noconfirm $GPU_PKGS

    for opt in fonts-extra security-tools asus; do
        if ask_yes_no "Install optional list '$opt'?" n; then
            install_list "$HERE/packages/optional/$opt.txt" "$opt"
            [[ "$opt" == asus ]] && touch "$MNT/home/$HEVENOS_USER/.hevenos-asus"
        fi
    done
}
```

- [ ] **Step 7: Add payload extract, banner, path fix, shell, handoff**

Append to `install.sh`:
```bash
deploy_payload() {
    local home="$MNT/home/$HEVENOS_USER"
    cp "$HERE/payload/desktop-env.tar.gz" "$home/"
    arch-chroot "$MNT" /bin/bash -euo pipefail <<CHROOT
cd /home/$HEVENOS_USER
sudo -u $HEVENOS_USER tar xzf desktop-env.tar.gz
rm -f desktop-env.tar.gz
CHROOT
    # Username path fix (three hardcoded /home/<user> paths).
    if [[ "$HEVENOS_USER" != <user> ]]; then
        arch-chroot "$MNT" /bin/bash -euo pipefail <<CHROOT
sed -i "s|/home/<user>|/home/$HEVENOS_USER|g" \
    /home/$HEVENOS_USER/.config/niri/config.kdl \
    /home/$HEVENOS_USER/.config/fish/config.fish
CHROOT
    fi
    # Verify no stragglers remain.
    if arch-chroot "$MNT" grep -rl /home/<user> "/home/$HEVENOS_USER/.config" 2>/dev/null | grep -q .; then
        warn "Some /home/<user> paths remain — check manually."
    fi

    # Console login banner.
    install -Dm644 "$HERE/overlay/fish_greeting.fish" \
        "$home/.config/fish/functions/fish_greeting.fish"
    arch-chroot "$MNT" chown -R "$HEVENOS_USER:$HEVENOS_USER" "/home/$HEVENOS_USER/.config"
    arch-chroot "$MNT" chsh -s /usr/bin/fish "$HEVENOS_USER"
    arch-chroot "$MNT" sudo -u "$HEVENOS_USER" fc-cache -f || true
}

handoff() {
    cp "$HERE/stage2.sh" "$MNT/home/$HEVENOS_USER/"
    mkdir -p "$MNT/home/$HEVENOS_USER/hevenos/packages/optional"
    cp "$HERE/packages/aur.txt" "$MNT/home/$HEVENOS_USER/hevenos/packages/"
    cp "$HERE/packages/optional/asus.txt" "$MNT/home/$HEVENOS_USER/hevenos/packages/optional/"
    [[ "$BROADCOM" == yes ]] && touch "$MNT/home/$HEVENOS_USER/.hevenos-broadcom"
    arch-chroot "$MNT" chown -R "$HEVENOS_USER:$HEVENOS_USER" "/home/$HEVENOS_USER"
    say "Stage 1 complete."
    cat >&2 <<EOF

  Reboot, remove install media, log in as $HEVENOS_USER, then:
      ./stage2.sh        # installs AUR packages
      niri               # starts the desktop
EOF
}
```

- [ ] **Step 8: Add `main` ordering and wire the entrypoint**

Append to `install.sh` and replace the earlier `--detect` early-exit with a dispatch:
```bash
main() {
    detect_all
    print_detection
    preflight
    base_install
    configure_system
    install_packages
    enable_services
    setup_swap
    install_bootloader
    deploy_payload
    handoff
}

case "${1:-}" in
    --detect) detect_all; print_detection ;;
    *)        main ;;
esac
```
Ensure the standalone `if [[ "${1:-}" == "--detect" ]]` block from Step 1 is removed so there is exactly one entrypoint dispatch.

- [ ] **Step 9: shellcheck + `--detect` smoke test + commit**

Run: `shellcheck install.sh`
Expected: clean (disable justified SC2086 where word-splitting is intentional).
Run: `bash install.sh --detect`
Expected: detection block prints, exit 0.
```bash
git add install.sh
git commit -m "feat: stage 1 installer (detect, base, chroot, bootloader, packages, payload)"
```

---

## Task 8: Stage 2 installer (`stage2.sh`)

**Files:**
- Create: `stage2.sh`
- Test: `shellcheck` + `bash -n`; behavioral run happens on the booted target (Task 9).

**Interfaces:**
- Consumes: `~/hevenos/packages/aur.txt`, `~/hevenos/packages/optional/asus.txt`, marker files `~/.hevenos-asus`, `~/.hevenos-broadcom`.
- Produces: installed AUR + conditional packages on the booted system.

- [ ] **Step 1: Write `stage2.sh`**

Create `stage2.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -ne 0 ]] || { echo "Run stage 2 as your normal user, not root." >&2; exit 1; }
HOME_DIR="$HOME"
PKGS="$HOME_DIR/hevenos/packages"

bootstrap_paru() {
    if command -v paru >/dev/null 2>&1; then return 0; fi
    echo ":: Bootstrapping paru-bin (prebuilt; source paru compiles Rust for hours)"
    local tmp; tmp="$(mktemp -d)"
    git clone https://aur.archlinux.org/paru-bin.git "$tmp/paru-bin"
    ( cd "$tmp/paru-bin" && makepkg -si --noconfirm )
    rm -rf "$tmp"
}

install_aur() { # list
    [[ -f "$1" ]] || return 0
    paru -S --needed --noconfirm - < "$1"
}

main() {
    bootstrap_paru
    install_aur "$PKGS/aur.txt"
    [[ -f "$HOME_DIR/.hevenos-asus" ]] && install_aur "$PKGS/optional/asus.txt"
    if [[ -f "$HOME_DIR/.hevenos-broadcom" ]]; then
        echo ":: Broadcom wifi detected; installing broadcom-wl-dkms"
        paru -S --needed --noconfirm broadcom-wl-dkms
    fi
    fc-cache -f || true
    echo ":: Done — type 'niri' to start the desktop."
}
main
```

- [ ] **Step 2: Lint**

Run: `shellcheck stage2.sh && bash -n stage2.sh`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add stage2.sh
git commit -m "feat: stage 2 AUR installer with paru bootstrap and conditional fixes"
```

---

## Task 9: README + validation ladder

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write `README.md`**

Create `README.md` documenting: the two-stage flow, the exact live-ISO entry commands (`pacman -Sy git; git clone <repo>; cd hevenos; ./install.sh`), the assumption that disks are already partitioned/mounted (with the UEFI ESP-at-`/mnt/boot` warning), the optional lists, the post-boot `./stage2.sh` + `niri` steps, and the maintainer note that `tools/build-payload.sh` must be rerun (and the OpenAI key rotated) whenever the source tarball changes. Include the VM validation ladder:
```
1. Static:  shellcheck *.sh lib/*.sh tools/*.sh && bash tests/run.sh
2. Detect:  bash install.sh --detect   (on each VM/host)
3. UEFI VM: OVMF firmware, ESP at /mnt/boot -> systemd-boot path
4. BIOS VM: seabios, MBR -> GRUB i386-pc path
5. GPU:     virtio (generic mesa) + at least one Intel target (the netbook)
6. 32-bit:  i686 VM -> install.sh aborts at the x86_64 assertion
7. Real:    HP netbook, BIOS/GRUB/Intel, disposable
```

- [ ] **Step 2: Run the full static suite**

Run: `shellcheck ./*.sh lib/*.sh tools/*.sh && bash tests/run.sh`
Expected: shellcheck clean; `N passed, 0 failed`.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add README and VM validation ladder"
```

---

## Task 10: Integration validation (VM + netbook)

**Files:** none (execution/verification task).

- [ ] **Step 1: BIOS/GRUB VM dry run**

Boot the Arch ISO in a SeaBIOS VM, partition (MBR, one root partition, bootable flag), format ext4, mount at `/mnt`, run the full flow. Verify it reboots into a tty showing the banner, login works, `stage2.sh` completes, `niri` starts.

- [ ] **Step 2: UEFI/systemd-boot VM dry run**

Repeat in an OVMF VM with an ESP mounted at `/mnt/boot`. Verify `bootctl` entry boots and the ucode initrd line is present.

- [ ] **Step 3: 32-bit abort check**

Boot an i686 environment (or fake `uname`); confirm `install.sh` dies at the x86_64 assertion with the clear message.

- [ ] **Step 4: Netbook run**

Run on the HP netbook (BIOS/GRUB/Intel). Confirm GPU is GMA 3150 (not GMA500) via `lspci`, no Broadcom flag fires (or the stage-2 fix works if it does), swapfile is created, banner shows, `niri` starts with waybar/kitty/wallpaper.

- [ ] **Step 5: Record results**

Note any package stragglers from `/root/missing.txt` and update `packages/core.txt` if a rename is found. Commit any list corrections:
```bash
git add packages/core.txt
git commit -m "fix: correct package names found during netbook validation"
```

---

## Self-Review

**Spec coverage:**
- Repo shape → Tasks 1,4,5,7,8,9. ✓
- Blocking tarball scrub (key + claude/terminalgpt/uv/uvx + temp) → Task 5 (tested). ✓
- x86_64 assertion / 32-bit abort → Task 2 (`is_x86_64`), Task 7 (`detect_all` die), Task 10 step 3. ✓
- Firmware/ucode/GPU/Broadcom/RAM detection → Task 2 (unit-tested), Task 7 (`detect_all`). ✓
- Preflight (mount, ESP, network, disk confirm) → Task 7 step 3. ✓
- pacstrap + genfstab → Task 7 step 3. ✓
- chroot config + user + 3-path sed fix → Task 7 steps 4,7. ✓
- Bootloader split (systemd-boot/GRUB) → Task 7 step 5. ✓
- Services (NM+wpa_supplicant, iwd off) → Task 7 step 5. ✓
- Swap (≤2 GiB) → Task 2 (`needs_swap`), Task 7 step 5. ✓
- Tolerant native install + missing.txt + optional lists → Task 3, Task 7 step 6. ✓
- Graphics driver detection incl. NVIDIA nouveau-default/proprietary-prompt → Task 7 step 6. ✓
- Payload extract + fc-cache → Task 7 step 7. ✓
- Console banner (VT-gated) install → Task 7 step 7 (file from prior work). ✓
- Shell = fish, manual niri, no autologin/greetd → Task 7 steps 4,7,8. ✓
- Handoff + markers → Task 7 step 7. ✓
- Stage 2 paru-bin bootstrap + aur + Broadcom + ASUS → Task 8. ✓
- Curation rules (drops/adds/opt-in, nmap+JetBrains in core) → Task 4 (invariant tests). ✓
- Testing ladder → Task 9, Task 10. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code. The one forward-note (Task 4 Step 1 `test_aur_curation`) is corrected within the same task (Step 6) before its test run. ✓

**Type/name consistency:** `available_pkgs`/`missing_pkgs` (Task 3) used verbatim in Task 7. `gpu_packages`/`detect_gpu_vendor`/`needs_swap`/`ucode_for_vendor` (Task 2) used verbatim in Task 7. `build_payload` (Task 5) matches its test. `ask_yes_no`/`ask_default`/`say`/`warn`/`die` (Task 6) used in Task 7. Marker files `.hevenos-asus`/`.hevenos-broadcom` written in Task 7, read in Task 8. ✓

**Ordering note enforced:** `enable_services` runs after `install_packages` (units exist only post-install) — encoded in Task 7 Step 8 `main`. ✓
