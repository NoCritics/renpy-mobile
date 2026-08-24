# Project state — resume here

Last updated: 2026-08-24. **Milestone B is complete** — all six tasks, including the
first hardware install, confirmed on a physical iPhone.

## Read this first if you are resuming after a machine restart

Branch **`milestone-b`** holds all Milestone B work, pushed to origin. `main` is
untouched at `f253aad` — nothing has been merged yet. The branch's final whole-branch
review verdict was "fit to merge once `docs/STATE.md` is refreshed" — this file is that
refresh.

**There is a working unsigned `.ipa` on disk at `build/dl/VNPlayer.ipa`** (27 MB, git-ignored,
so it survives a checkout but not a `git clean -fdx`). It is also downloadable from the
**Artifacts** section of the most recent successful run of the
[iOS build workflow](https://github.com/NoCritics/renpy-mobile/actions/workflows/ios-build.yml),
artifact `VNPlayer-ipa`. No GitHub Release has been published yet — no tag has been
pushed, so the release-attachment path in Task 6 remains unexercised by a real run (see
`docs/IOS-BUILD.md`'s Task 6 section).

The SDD ledger — every ruling, every deferred finding, what is done and what is not — is at
`.superpowers/sdd/2026-08-24-milestone-b-ios-pipeline/progress.md`. **Read it before
re-dispatching anything.**

## What this is

A free, open-source iOS player for Ren'Py 8 visual novels. No ads, no purchases, no time
limits. Built for one specific reader (computer-competent, not a developer); public so anyone
can build or fork it.

Repo: https://github.com/NoCritics/renpy-mobile (public — this matters: macOS CI runners are
free and unlimited on public repos, and bill at 10x on private ones).
Local: the working directory this file sits in.

## Read these, in this order

1. `docs/superpowers/specs/2026-08-24-renpy-ios-player-design.md` — the design. **The
   authority.**
2. `docs/BUILD.md` — Milestone A's measured record. Authoritative for every figure there.
3. `docs/IOS-BUILD.md` — **Milestone B's measured record.** Written from real CI runs and
   the real device install; authoritative for the iOS toolchain, the build pipeline, and
   what the hardware install actually showed. Covers Tasks 1-6.
4. `docs/INSTALL.md` — the Sideloadly walkthrough for a non-developer reader.
5. `docs/2026-08-24-milestone-a-decision-log.md` — 26 rulings from Milestone A.
6. `docs/2026-08-24-research-renpy-ios-player.md` — market and licensing research.

## Status

**Milestone A — COMPLETE.** The Python engine layer (`shell/main.py`, `shell/vnshell/*`).
19/19 tests via `bash scripts/run_tests.sh`. Proven over 200 launches: in-process game
switching, `sys.modules` hygiene, save isolation. Ren'Py's own source is never modified.

**Milestone B — COMPLETE. All six tasks, confirmed on a physical iPhone.** The pipeline
runs end to end in about 60-75 seconds for the CI portion and needs no Mac, no Apple
Developer Program membership, and no secrets of any kind:

- CI fetches and SHA-256-verifies the Ren'Py 8.5.3 SDK and renios.
- Ren'Py's own `ios_create` / `ios_populate` run **headlessly** on `macos-15`.
- `xcodebuild` archives unsigned; the `.ipa` is packaged by hand from `Payload/`.
- **Milestone A's shell layer reaches the `.ipa` unchanged** — `base/main.py` is our
  2,698-byte file, not the 8,922-byte one `ios_populate` generates, and all seven `vnshell`
  modules are present with no `__pycache__`. Verified independently by downloading the
  artifact rather than trusting the CI log.
- **Installed via Sideloadly on a physical iPhone and confirmed running.** The app
  launches, renders our diagnostic screen, the interaction loop stays alive (`alive for
  Ns`, counting up — not a single static frame), and `vnshell: imported OK`. Milestone
  A's shell layer is proven portable to iOS at runtime, not just present on disk in the
  bundle. This was the milestone's central unproven claim.
- Release automation (tag-triggered `.ipa` upload to a GitHub Release) is wired into
  `ios-build.yml` but **not yet exercised by a real tag push** — that is the repository
  owner's decision, not this milestone's.

**The shell project currently renders a diagnostic screen** — engine and Python
versions, container paths, and a live seconds counter — **not** a black screen and not
yet a visual novel reader. A wall of text with a ticking counter is the correct,
expected result right now; see `docs/INSTALL.md` step 8.

**`VNPlayer` is the settled product name**, not a placeholder — it is the Xcode
project/scheme/target name, the `.ipa` filename, and appears in the overridden bundle
identifier `io.github.nocritics.vnplayer`.

**Interface orientation is landscape-only**, inherited unmodified from Ren'Py's shipped
`Info.plist`. Treated as a **settled decision for now** — revisit only if a future
milestone needs portrait support.

`TODO(device): the iPhone model and iOS version used for the Task 5 hardware
confirmation are not yet recorded` — see `docs/IOS-BUILD.md`'s Task 5 section for the
exact placeholder. Do not assume which models or iOS versions this has run on beyond
"at least one physical iPhone, model and OS version unrecorded."

**Known constraint, unchanged:** ~22 MB leaked per game switch, native, inside Ren'Py's
C/GL/SDL layer. Decided mitigation: watch and warn. Spec §14. Milestone B did **not**
re-measure it on device and must not be read as having done so — that needs
`task_info(TASK_VM_INFO).phys_footprint` and belongs to Milestone C.

**Two real bugs the device install found, both open, both Milestone C's first job — see
`docs/IOS-BUILD.md`'s Task 5/6 sections ("What will actually work, and why it is
Milestone C's first job") for the full evidence:**

1. **`path_to_saves()` (`shell/main.py`) cannot write on iOS.** Its fallback path is
   inside the read-only app bundle; the sandbox denies the write outright — confirmed
   live in the device log: `deny(1) file-write-create .../VNPlayer.app/base/game/saves`.
   Harmless today only because the shell project never saves anything; a real game's
   first autosave would hit this.
2. **The fix for that, and for on-device log retrieval, is the same change.** Point
   `path_to_logdir()` and `path_to_saves()` at the app's writable **Data** container
   (confirmed to exist at
   `/private/var/mobile/Containers/Data/Application/<uuid>/Documents`), detecting iOS
   via `renpy.ios` — never `sys.platform`, which reads `"darwin"` on iOS, not `"ios"`.
   That also lets logs and saves be pulled off the device via `afcclient` or the Files
   app, with no console tool required.

## Facts worth not re-deriving

- **Two interpreters.** The SDK's bundled CPython 3.12 runs Ren'Py; its stdlib is stripped and
  has no `unittest`. Tests run on a system CPython via `scripts/run_tests.sh`. Never install
  anything into `vendor/` — it is SHA-256-verified and `fetch_deps.sh` deletes it on repair.
- **The renios zip unpacks to `vendor/renios`**, not `vendor/renpy-8.5.3-renios`.
- **`ios_create` / `ios_populate` take POSITIONAL arguments**, not `--destination`, and the
  destination IS the Xcode project directory, not a parent. `ios_create` already calls
  `ios_populate` internally.
- **The interpreter you run them with is load-bearing:** `renios/buildlib/renios/create.py`
  rewrites the link flag to `-lpython{major}.{minor}` of the *running* Python. Only 3.12
  matches the shipped `libpython3.12.a`. The device confirmed the on-device interpreter is
  **Python 3.12.8** (the SDK's bundled build is 3.12.7 — same minor, different patch release;
  don't pin an exact patch version anywhere).
- **`renios/buildlib/renios/image.py` silently no-ops on a missing `ios-icon.png`** — the app
  currently ships Ren'Py's stock prototype icon. Deliberate; deferred, not forgotten.
- **Generated names:** project and scheme `VNPlayer`. Ren'Py rewrites the bundle id to the
  placeholder `com.domain.VNPlayer`, which the build overrides on the `xcodebuild` command
  line to `io.github.nocritics.vnplayer`. Sideloadly rewrites it again at install time to
  include the signing team suffix from the installer's own Apple ID — never publish a real
  suffix value (`docs/INSTALL.md` uses a placeholder `XXXXXXXXXX` for exactly this reason).
- **Runner:** macOS 15.7.7, Xcode 16.4, iOS SDK 18.5. Deployment target 13.0 (an Xcode
  project build setting, not `Info.plist`). Orientation is landscape-only in Ren'Py's
  shipped `Info.plist` — kept as a settled decision for now, see Status above.
- **On iOS, `sys.platform` reports `"darwin"`, not `"ios"`.** Any iOS-specific runtime
  detection must use `renpy.ios` (`renpy/__init__.py:167`,
  `os.environ.get("RENPY_PLATFORM", "").startswith("ios")`), never `sys.platform`.
  Confirmed live on device.
- **On iOS, Ren'Py never opens `log.txt`; every log line goes to stdout**, which the
  renios shell routes into the iOS system log via `prototype/Log.m`'s `NSLog` call. The
  `%{public}s` patch (`scripts/ios/enable_public_log.sh`) changes **redaction, not
  deliverability** — it does **not** make the log readable over the USB relay this
  project's own `device_log.sh` uses (`idevicesyslog`); the relay never delivers the
  argument payload for a third-party binary's log entries regardless of the format
  specifier. The patch is only useful with Console.app attached on an actual Mac.
- **Hook timing is load-bearing** (Milestone A): `select_next_basedir` runs *after*
  `reload_all()`, so live teardown must happen in `lifecycle._restart()` before the exception.
- **`ru_maxrss` is peak RSS** and can never decrease; the iOS re-measurement must use
  `phys_footprint`, which is also what Jetsam meters.
- **No secrets in CI, ever.** Any step that appears to need one is a design failure.
- **`path_to_saves()` cannot write inside the read-only app bundle on iOS** — see the
  open bugs in Status above. Do not assume saves work on-device just because the .ipa
  builds and boots.

## Open decisions

- Whether to pursue the native memory leak upstream.
- The display icon (currently Ren'Py's stock prototype icon, see the `image.py` fact
  above) — deferred, not forgotten.
