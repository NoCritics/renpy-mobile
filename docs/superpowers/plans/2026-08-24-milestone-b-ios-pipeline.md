# Milestone B — iOS Build Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove that a GitHub Actions macOS runner can turn Ren'Py's prebuilt iOS artifacts into an unsigned `.ipa` that installs on a real iPhone via Sideloadly and boots **our** shell layer — with no Mac, no Apple Developer Program membership, and no signing secrets anywhere in CI.

**Architecture:** CI fetches the pinned Ren'Py SDK and `renios` package, verifies both by SHA-256, drives Ren'Py's own registered `ios_create` / `ios_populate` CLI commands headlessly to generate an Xcode project, overlays the `shell/` layer proven in Milestone A into the generated `base/`, archives with code signing disabled, and packages the result by hand into a `Payload/` zip. Sideloadly signs it locally with the user's free Apple ID.

**Tech Stack:** GitHub Actions `macos-15`, Xcode 16.x, Ren'Py 8.5.3 SDK + renios, `xcodebuild`, bash. No fastlane, no certificates, no App Store Connect API key.

**Spec:** `docs/superpowers/specs/2026-08-24-renpy-ios-player-design.md`

## Scope of this plan

This is **the pipeline only**. It deliberately does not build the native Swift shell, the library UI, the importer, or the touch overlay — those are Milestone C, and writing them before we know CI can build *anything* would be stacking work on an unproven foundation.

**Milestone B is done when:** a GitHub Actions run on a clean checkout produces a downloadable `.ipa`, the user installs it with Sideloadly, and the app launches and shows the shell project's screen on a real device — proving Milestone A's Python layer runs unchanged on iOS.

If CI cannot drive Xcode unattended, that is a successful outcome for this milestone: we learn it before any Swift exists, and the fallback (a rented cloud Mac for the Xcode-integration phase) is a known, costed option rather than a surprise.

## Global Constraints

- **Ren'Py 8.5.3 pinned.** SHA-256 of `renpy-8.5.3-sdk.zip` is
  `ff57648f9c04f27e381c48af6d8e3ee3cdec296bed4d3831f47f09b0a71b505e`;
  of `renpy-8.5.3-renios.zip`,
  `c4fae153e8276ed0faed5e84ea3e0b7c4bf337f0e3208e9130c6a41748a83b2b`.
- **No secrets in CI, ever.** No certificates, no provisioning profiles, no App Store Connect key, no repository secrets of any kind. The build must work identically on any fork. If a step appears to need a secret, stop and report it — that is a design failure, not a configuration gap.
- **Never modify Ren'Py's source.** The `shell/` layer is the only customization, exactly as in Milestone A.
- **The `shell/` layer ships unchanged.** If iOS requires an edit to `shell/main.py` or `shell/vnshell/*`, that is a finding to report — Milestone A's entire premise is that this layer is portable. Report it before changing it.
- **Public repo.** `github.com/NoCritics/renpy-mobile`. macOS runners are free and unlimited here; they would bill at 10× on a private repo.
- Working name `VNPlayer`; environment variables use the `VNPLAYER_` prefix. The bundle identifier is settled in Task 3 and is painful to change afterwards.

---

## File Structure

```
.github/workflows/
  ios-build.yml          the whole pipeline
scripts/ios/
  fetch_ios_deps.sh      download + SHA-256 verify SDK and renios
  generate_xcode.sh      headless ios_create + ios_populate
  overlay_shell.sh       copy shell/ into the generated base/
  package_ipa.sh         unsigned archive -> Payload/ -> .ipa
docs/
  INSTALL.md             Sideloadly walkthrough — a release blocker, not a footnote
  IOS-BUILD.md           recorded facts about renios internals (written by Task 1)
```

Everything under `scripts/ios/` must run identically on a developer's Mac and on CI. No step may depend on GitHub Actions specifics beyond what `ios-build.yml` passes in.

---

### Task 1: Discover what `renios` actually contains

**Files:**
- Create: `scripts/ios/fetch_ios_deps.sh`, `.github/workflows/ios-build.yml` (discovery-only at this stage), `docs/IOS-BUILD.md`

**Interfaces:**
- Produces: `docs/IOS-BUILD.md`, recording the **real** contents of the renios package. Tasks 2-4 are written against this file, so its accuracy is the deliverable.

This task exists because nobody working on this plan has seen inside `renpy-8.5.3-renios.zip`. Everything downstream depends on its actual layout, the Xcode project's scheme name, its deployment target, and its bundle identifier. **Do not guess any of these — record what is there.**

- [ ] **Step 1: Write `scripts/ios/fetch_ios_deps.sh`**

```bash
#!/usr/bin/env bash
# Downloads and SHA-256-verifies the pinned Ren'Py SDK and renios package.
# Idempotent. Safe to run on CI or a developer machine.
set -euo pipefail

RENPY_VERSION="8.5.3"
SDK_SHA256="ff57648f9c04f27e381c48af6d8e3ee3cdec296bed4d3831f47f09b0a71b505e"
RENIOS_SHA256="c4fae153e8276ed0faed5e84ea3e0b7c4bf337f0e3208e9130c6a41748a83b2b"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VENDOR="$ROOT/vendor"
mkdir -p "$VENDOR"

# sha256sum on Linux, shasum -a 256 on macOS.
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

fetch() {
    local name="$1" expected="$2" marker="$3"
    local zip="$VENDOR/renpy-$RENPY_VERSION-$name.zip"
    local dir="$VENDOR/renpy-$RENPY_VERSION-$name"

    if [ -e "$dir/$marker" ]; then
        echo "$name already present at $dir"
        return 0
    fi

    if [ ! -f "$zip" ]; then
        echo "Downloading $name..."
        curl -fL --progress-bar -o "$zip.part" \
            "https://www.renpy.org/dl/$RENPY_VERSION/renpy-$RENPY_VERSION-$name.zip"
        mv "$zip.part" "$zip"
    fi

    local actual
    actual="$(sha256_of "$zip")"
    if [ "$actual" != "$expected" ]; then
        echo "CHECKSUM MISMATCH for $name" >&2
        echo "  expected: $expected" >&2
        echo "  actual:   $actual" >&2
        rm -f "$zip"
        exit 1
    fi

    echo "Unpacking $name..."
    rm -rf "$dir"
    unzip -qo "$zip" -d "$VENDOR"

    if [ ! -e "$dir/$marker" ]; then
        echo "Unpack did not produce $dir/$marker" >&2
        exit 1
    fi
}

fetch sdk    "$SDK_SHA256"    "renpy/bootstrap.py"
fetch renios "$RENIOS_SHA256" "buildlib"

echo "iOS dependencies ready under $VENDOR"
```

Note the `renios` marker is `buildlib` — a directory known to exist from the upstream repository layout. If the unpack fails on that assertion, the package layout differs from expectation and **that is itself the finding**: report it rather than weakening the check.

- [ ] **Step 2: Write a discovery-only workflow**

`.github/workflows/ios-build.yml`:

```yaml
name: iOS build

on:
  workflow_dispatch:
  push:
    branches: [main]

jobs:
  discover:
    runs-on: macos-15
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v4

      - name: Record toolchain
        run: |
          sw_vers
          xcodebuild -version
          xcode-select -p
          ls /Applications | grep -i xcode || true

      - name: Cache Ren'Py downloads
        uses: actions/cache@v4
        with:
          path: vendor/*.zip
          key: renpy-8.5.3-archives

      - name: Fetch dependencies
        run: bash scripts/ios/fetch_ios_deps.sh

      - name: Inventory renios
        run: |
          RENIOS=vendor/renpy-8.5.3-renios
          echo "=== top level ==="
          ls -la "$RENIOS"
          echo "=== depth 2 ==="
          find "$RENIOS" -maxdepth 2 -type d | sort
          echo "=== xcode projects ==="
          find "$RENIOS" -name "*.xcodeproj" -maxdepth 3
          echo "=== prebuilt libraries ==="
          find "$RENIOS" -name "*.a" | head -50
          echo "=== library count and total size ==="
          find "$RENIOS" -name "*.a" | wc -l
          du -sh "$RENIOS"
          echo "=== does base/ ship, or is it generated? ==="
          ls -la "$RENIOS"/prototype/base 2>&1 || echo "no prototype/base — generated by ios_populate"
          echo "=== Info.plist ==="
          find "$RENIOS" -name "Info.plist" -maxdepth 3 -exec cat {} \;
          echo "=== schemes in the prototype project ==="
          find "$RENIOS" -name "*.xcodeproj" -maxdepth 3 -exec xcodebuild -list -project {} \; 2>&1 || true

      - name: Upload inventory
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: renios-inventory
          path: |
            vendor/renpy-8.5.3-renios/**/Info.plist
            vendor/renpy-8.5.3-renios/**/*.pbxproj
          if-no-files-found: warn
```

- [ ] **Step 3: Commit, push, and run it**

```bash
git add scripts/ios/fetch_ios_deps.sh .github/workflows/ios-build.yml
git commit -m "ci: renios discovery workflow"
git push
gh workflow run "iOS build" || echo "trigger from the Actions tab if gh is unavailable"
```

Watch the run. If `gh` is available, `gh run watch`.

- [ ] **Step 4: Record the findings in `docs/IOS-BUILD.md`**

Write down, from the actual log output — not from expectation:

- Xcode version and macOS version on the runner
- the runner's default iOS SDK version
- the renios top-level layout, and where the `.xcodeproj` lives
- the scheme name(s) `xcodebuild -list` reports
- the deployment target and bundle identifier from `Info.plist`
- how many `.a` files ship, and their combined size
- **whether `prototype/base/` ships or must be generated** — this determines whether Task 2 is required at all
- anything that contradicts this plan's assumptions

Commit it. Tasks 2-4 are written against this file.

**If the workflow fails to even reach the inventory step**, that is important: record the failure verbatim and report it. A macOS runner that cannot fetch or unpack is a different problem from one that cannot build.

---

### Task 2: Generate the Xcode project headlessly

**Files:**
- Create: `scripts/ios/generate_xcode.sh`
- Modify: `.github/workflows/ios-build.yml`

**Interfaces:**
- Consumes: `vendor/renpy-8.5.3-sdk`, `vendor/renpy-8.5.3-renios`, `shell-project/`
- Produces: `build/xcode/<name>/` — a generated Xcode project with `base/` populated, ready to archive.

Ren'Py registers `ios_create` and `ios_populate` as CLI commands (`launcher/game/ios.rpy`), so no GUI launcher is needed. `ios_create` copies the prototype project and rewrites the bundle identifier; `ios_populate` runs Ren'Py's `Distributor` with `packages=['ios']` to build `base/` — the Python runtime, the engine, and the game.

**The renios package must sit inside the SDK directory** — the launcher looks for `<sdk>/renios` and refuses if it is absent.

- [ ] **Step 1: Write `scripts/ios/generate_xcode.sh`**

```bash
#!/usr/bin/env bash
# Generates an Xcode project from the Ren'Py SDK + renios, headlessly.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SDK="$ROOT/vendor/renpy-8.5.3-sdk"
RENIOS="$ROOT/vendor/renpy-8.5.3-renios"
PROJECT="${1:-$ROOT/shell-project}"
DEST="$ROOT/build/xcode"

[ -f "$SDK/renpy/bootstrap.py" ] || { echo "SDK missing; run fetch_ios_deps.sh" >&2; exit 1; }
[ -d "$RENIOS" ] || { echo "renios missing; run fetch_ios_deps.sh" >&2; exit 1; }

# The launcher looks for <sdk>/renios and will not proceed without it.
if [ ! -d "$SDK/renios" ]; then
    echo "Placing renios inside the SDK..."
    cp -R "$RENIOS" "$SDK/renios"
fi

PY="$SDK/lib/py3-mac-universal/python"
[ -x "$PY" ] || PY="$(find "$SDK/lib" -maxdepth 2 -name python -type f -perm +111 | head -1)"
[ -x "$PY" ] || { echo "No macOS Python found under $SDK/lib" >&2; exit 1; }

rm -rf "$DEST"
mkdir -p "$DEST"

# Ren'Py CLI commands other than "run" do not open a window, but force a
# headless video driver anyway so a runner without a display cannot surprise us.
export SDL_VIDEODRIVER=dummy
export SDL_AUDIODRIVER=dummy

echo "=== ios_create ==="
"$PY" "$SDK/renpy.py" "$SDK/launcher" ios_create "$PROJECT" --destination "$DEST"

echo "=== ios_populate ==="
"$PY" "$SDK/renpy.py" "$SDK/launcher" ios_populate "$PROJECT" --destination "$DEST"

echo "=== result ==="
find "$DEST" -maxdepth 2 | sort
```

The `--destination` flag is taken from `ios.rpy`'s `ios_create_command`. **If the argument names differ from this, Task 1's inventory will have shown it — use what is actually there.**

- [ ] **Step 2: Add the generation step to the workflow**

Insert after "Fetch dependencies":

```yaml
      - name: Generate Xcode project
        run: bash scripts/ios/generate_xcode.sh

      - name: Inspect generated project
        run: |
          find build/xcode -maxdepth 3 | sort | head -60
          echo "=== base/ contents ==="
          ls -la build/xcode/*/base | head -30
          echo "=== is our game in base/? ==="
          ls -la build/xcode/*/base/game | head -20
          echo "=== schemes ==="
          xcodebuild -list -project build/xcode/*/*.xcodeproj
```

- [ ] **Step 3: Push and run**

Record in `docs/IOS-BUILD.md`: whether both commands completed, how long `ios_populate` took, the generated tree layout, and the scheme name — Task 3 needs it exactly.

**Two failure modes worth distinguishing in your report**, because they lead to different fixes:
- the commands are not registered / arguments differ → the launcher's CLI surface differs from `ios.rpy` as read; record the actual `--help` output
- the commands run but `base/` is empty or lacks `game/` → the Distributor path is the problem, not the CLI

---

### Task 3: Archive unsigned and package an `.ipa`

**Files:**
- Create: `scripts/ios/package_ipa.sh`
- Modify: `.github/workflows/ios-build.yml`

**Interfaces:**
- Consumes: `build/xcode/<name>/<name>.xcodeproj`
- Produces: `build/VNPlayer.ipa` — unsigned, installable via Sideloadly.

`xcodebuild -exportArchive` refuses to export without a signing identity, so we do not use it. An unsigned archive is packaged by hand: the archive's `Products/Applications` directory is renamed `Payload`, zipped, and given an `.ipa` extension. That is all an `.ipa` is.

- [ ] **Step 1: Write `scripts/ios/package_ipa.sh`**

```bash
#!/usr/bin/env bash
# Archives the generated Xcode project without code signing and packages the
# result as an unsigned .ipa.
#
# Deliberately does NOT use xcodebuild -exportArchive: that requires a signing
# identity, which would mean putting a certificate into CI. Sideloadly signs
# locally with the user's own free Apple ID instead, so CI holds no secrets.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="$ROOT/build"
ARCHIVE="$BUILD/VNPlayer.xcarchive"

PROJECT="$(find "$BUILD/xcode" -maxdepth 2 -name "*.xcodeproj" | head -1)"
[ -n "$PROJECT" ] || { echo "No .xcodeproj under $BUILD/xcode" >&2; exit 1; }

SCHEME="${VNPLAYER_SCHEME:-$(basename "$PROJECT" .xcodeproj)}"
echo "Project: $PROJECT"
echo "Scheme:  $SCHEME"

rm -rf "$ARCHIVE" "$BUILD/Payload" "$BUILD/VNPlayer.ipa"

xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=NO \
    archive

APP="$(find "$ARCHIVE/Products/Applications" -maxdepth 1 -name "*.app" | head -1)"
[ -n "$APP" ] || { echo "Archive produced no .app" >&2; ls -R "$ARCHIVE/Products" >&2; exit 1; }

mkdir -p "$BUILD/Payload"
cp -R "$APP" "$BUILD/Payload/"

( cd "$BUILD" && zip -qry VNPlayer.ipa Payload )
rm -rf "$BUILD/Payload"

echo "=== built ==="
ls -lh "$BUILD/VNPlayer.ipa"
unzip -l "$BUILD/VNPlayer.ipa" | head -20
```

- [ ] **Step 2: Add packaging and artifact upload to the workflow**

```yaml
      - name: Package unsigned .ipa
        run: bash scripts/ios/package_ipa.sh

      - name: Upload .ipa
        uses: actions/upload-artifact@v4
        with:
          name: VNPlayer-ipa
          path: build/VNPlayer.ipa
          if-no-files-found: error
```

- [ ] **Step 3: Push, run, and record**

Record in `docs/IOS-BUILD.md`: whether the archive succeeded, the `.ipa` size, its internal structure from `unzip -l`, and the total wall-clock time of the run.

**If the archive fails**, the error matters more than the fact. Record it verbatim. Missing-architecture, missing-library and signing-related failures each point somewhere different, and a plan written against a guess would be worse than no plan.

---

### Task 4: Make the `.ipa` run our shell layer

**Files:**
- Create: `scripts/ios/overlay_shell.sh`
- Modify: `.github/workflows/ios-build.yml`

**Interfaces:**
- Consumes: the populated `build/xcode/<name>/base/`
- Produces: the same tree with `shell/main.py` and `shell/vnshell/` overlaid, exactly as `scripts/make_rig.sh` does for the desktop rig.

This is the point of the milestone. A stock `.ipa` proves CI works; an `.ipa` running **our** `main.py` proves Milestone A's layer is portable — the claim the whole architecture rests on.

The overlay mirrors the desktop rig exactly: on iOS, `librenpython.c` sets Python's home to `<exedir>/base` and runs `<exedir>/base/main.py`. `base/` also holds `renpy/` and the stdlib. That is the same relative layout `.rig/` reproduces, which is why the layer should transfer unchanged.

- [ ] **Step 1: Write `scripts/ios/overlay_shell.sh`**

```bash
#!/usr/bin/env bash
# Overlays the shell layer proven in Milestone A into the generated base/.
# Mirrors scripts/make_rig.sh, which does the same for the desktop rig.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$(find "$ROOT/build/xcode" -maxdepth 2 -type d -name base | head -1)"
[ -n "$BASE" ] || { echo "No base/ under build/xcode; run generate_xcode.sh first" >&2; exit 1; }

echo "Overlaying shell layer into $BASE"

# Ren'Py's distributor writes its own main.py; ours replaces it.
cp "$ROOT/shell/main.py" "$BASE/main.py"
rm -rf "$BASE/vnshell"
cp -R "$ROOT/shell/vnshell" "$BASE/vnshell"

echo "=== overlay result ==="
ls -la "$BASE/main.py" "$BASE/vnshell"
echo "=== base/game present? (required: bootstrap.py:334 needs it before the restart loop) ==="
ls -d "$BASE/game" || { echo "No base/game — the app will fail with NoGameDirectory" >&2; exit 1; }
```

- [ ] **Step 2: Insert the overlay between generation and packaging**

It must run **after** `ios_populate` (which writes its own `main.py`) and **before** `package_ipa.sh`:

```yaml
      - name: Overlay shell layer
        run: bash scripts/ios/overlay_shell.sh
```

- [ ] **Step 3: Guard against a silent no-op**

Add a workflow step after the overlay that fails loudly if our layer is not actually in the built app:

```yaml
      - name: Verify shell layer is in the .ipa
        run: |
          unzip -l build/VNPlayer.ipa | grep -E "vnshell/(lifecycle|purge|mailbox)\.py" \
            || { echo "shell layer missing from .ipa" >&2; exit 1; }
```

Place it after packaging. A build that quietly ships stock Ren'Py would pass every other check in this plan.

- [ ] **Step 4: Push, run, record**

Record whether the overlay survived packaging, and the final `.ipa` size.

---

### Task 5: Install on the device and prove it boots

**Files:**
- Create: `docs/INSTALL.md`
- Modify: `docs/IOS-BUILD.md`

**Interfaces:**
- Consumes: the `.ipa` artifact from Task 4
- Produces: a confirmed-working install, and instructions someone else can follow.

**This task cannot be completed by an agent.** It requires the physical iPhone. The agent's job is to write instructions precise enough that the human succeeds on the first attempt, and to specify exactly what evidence to bring back.

- [ ] **Step 1: Write `docs/INSTALL.md`**

Cover, in order: downloading the `.ipa` from the GitHub Actions run's artifacts; installing Sideloadly on Windows; connecting the iPhone and trusting the computer; signing in with a free Apple ID and what that account is used for; dragging the `.ipa` in and starting the install; **trusting the developer certificate** on the device under Settings → General → VPN & Device Management, which the app will not launch without and which is the step people miss; and the 7-day expiry with how to refresh.

State the free-tier limits plainly: 7 days, maximum 3 sideloaded apps per device.

- [ ] **Step 2: Hand off to the human with a precise ask**

Report to the human and request:
1. Does the app install?
2. Does it launch, or does iOS refuse it? If refused, the exact wording.
3. What appears on screen — the shell project renders a black screen, so "a black screen that stays" is **success**, not a hang. Say this explicitly or it will be reported as a failure.
4. Their iPhone model and iOS version.
5. If it crashes on launch: Settings → Privacy & Security → Analytics & Improvements → Analytics Data, find the entry named after the app, and share it.

- [ ] **Step 3: Record the outcome**

Whatever happens, record it in `docs/IOS-BUILD.md` under `## First device install`, including the device model and iOS version — the deployment target recorded in Task 1 is only a claim until something actually runs.

---

### Task 6: Make the pipeline releasable

**Files:**
- Modify: `.github/workflows/ios-build.yml`, `README.md`

Only after Task 5 confirms a working install. Building this earlier would be automating a pipeline not yet known to produce something that runs.

- [ ] **Step 1: Attach the `.ipa` to a GitHub Release on tags**

```yaml
      - name: Attach to release
        if: startsWith(github.ref, 'refs/tags/')
        uses: softprops/action-gh-release@v2
        with:
          files: build/VNPlayer.ipa
          body: |
            Unsigned build. Install with Sideloadly using your own Apple ID —
            see docs/INSTALL.md. No Apple Developer Program membership required.
```

- [ ] **Step 2: Cache the toolchain download**

Task 1 already caches `vendor/*.zip`. Confirm from the run logs that the cache is actually hitting, and record the cached versus uncached run times.

- [ ] **Step 3: Update `README.md`**

Status, a link to the latest release, a pointer to `docs/INSTALL.md`, and one line stating the project is not affiliated with the Ren'Py project.

---

## Self-Review

**Spec coverage.** This plan implements spec §11 (build and distribution) and the `INSTALL.md` deliverable. It deliberately does not touch §7 (import), §9 (native UI) or §5.5 (the bridge) — those are Milestone C.

**Known gap, accepted:** this plan proves the Python layer boots on iOS. It does **not** re-measure the ~22 MB/switch memory leak on device, and it must not be read as having done so. Spec §14 requires that re-measurement using `task_info(TASK_VM_INFO).phys_footprint` — `ru_maxrss` is peak RSS and can never decrease, so it would fail as an instrument exactly as three canaries did in Milestone A. That work belongs to Milestone C, where a native layer exists to measure from.

**Placeholder scan.** No TBDs. Task 1 deliberately defers concrete values — scheme name, deployment target, bundle identifier, whether `base/` ships — to discovery, because nobody involved has seen inside the renios package. The plan names exactly what to record and which later tasks consume it.

**Type consistency.** `scripts/ios/*.sh` all derive `ROOT` identically and all operate on `vendor/renpy-8.5.3-*` and `build/xcode`. `generate_xcode.sh` produces the tree `overlay_shell.sh` and `package_ipa.sh` consume; the scheme name flows from Task 1's inventory into `package_ipa.sh`'s `VNPLAYER_SCHEME`.

**The riskiest assumption**, restated so it is not lost: that `ios_create` and `ios_populate` run correctly headless on a CI runner. Ren'Py's iOS documentation assumes a developer at a Mac with the GUI launcher. Task 2 is where this plan most plausibly fails, and its failure would be the signal to rent a cloud Mac for the Xcode-integration phase rather than to keep pushing at CI.
