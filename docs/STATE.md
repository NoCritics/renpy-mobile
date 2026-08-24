# Project state — resume here

Last updated: 2026-08-24, mid Milestone B (Tasks 1-4 done, Task 5 is the device install).

## Read this first if you are resuming after a machine restart

Branch **`milestone-b`** holds all Milestone B work, pushed to origin, working tree clean.
`main` is untouched at `f253aad` — nothing has been merged.

**There is a working unsigned `.ipa` on disk at `build/dl/VNPlayer.ipa`** (27 MB, git-ignored,
so it survives a checkout but not a `git clean -fdx`). It is also downloadable from GitHub
Actions run 32749876704, artifact `VNPlayer-ipa`.

The SDD ledger — every ruling, every deferred finding, what is done and what is not — is at
`.superpowers/sdd/2026-08-24-milestone-b-ios-pipeline/progress.md`. **Read it before
re-dispatching anything.** It is the only record that Task 4's review package was written but
never dispatched.

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
3. `docs/IOS-BUILD.md` — **Milestone B's measured record.** Written from real CI runs;
   authoritative for the iOS toolchain and the build pipeline.
4. `docs/2026-08-24-milestone-a-decision-log.md` — 26 rulings from Milestone A.
5. `docs/2026-08-24-research-renpy-ios-player.md` — market and licensing research.

## Status

**Milestone A — COMPLETE.** The Python engine layer (`shell/main.py`, `shell/vnshell/*`).
19/19 tests via `bash scripts/run_tests.sh`. Proven over 200 launches: in-process game
switching, `sys.modules` hygiene, save isolation. Ren'Py's own source is never modified.

**Milestone B — Tasks 1-4 COMPLETE, Task 5 is the blocker.** The pipeline runs end to end in
about 60 seconds and needs no Mac, no Apple Developer Program, and no secrets of any kind:

- CI fetches and SHA-256-verifies the Ren'Py 8.5.3 SDK and renios.
- Ren'Py's own `ios_create` / `ios_populate` run **headlessly** on `macos-15` — the plan's
  designated most-likely-to-fail assumption, retired on the first attempt.
- `xcodebuild` archives unsigned; the `.ipa` is packaged by hand from `Payload/`.
- **Milestone A's shell layer reaches the `.ipa` unchanged** — `base/main.py` is our
  2,698-byte file, not the 8,922-byte one `ios_populate` generates, and all seven `vnshell`
  modules are present with no `__pycache__`. Verified twice, independently, by downloading
  the artifact rather than trusting the CI log.

**Task 5 — the first device install — is the open item and cannot be done by an agent.** It
needs the physical iPhone, Sideloadly and a human. `docs/INSTALL.md` is not written yet.
Task 6 (releases, README) is gated behind Task 5 and has not started.

**Not proven: that the app boots on a real device.** Everything above is build-time evidence.
The shell project renders a black screen, so on the device a black screen that *stays* is
success, not a hang.

**Known constraint, unchanged:** ~22 MB leaked per game switch, native, inside Ren'Py's
C/GL/SDL layer. Decided mitigation: watch and warn. Spec §14. Milestone B did **not**
re-measure it on device and must not be read as having done so — that needs
`task_info(TASK_VM_INFO).phys_footprint` and belongs to Milestone C.

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
  matches the shipped `libpython3.12.a`.
- **`renios/buildlib/renios/image.py` silently no-ops on a missing `ios-icon.png`** — the app
  currently ships Ren'Py's stock prototype icon. Deliberate; deferred, not forgotten.
- **Generated names:** project and scheme `VNPlayer`. Ren'Py rewrites the bundle id to the
  placeholder `com.domain.VNPlayer`, which we override on the `xcodebuild` command line to
  `io.github.nocritics.vnplayer`. Sideloadly rewrites it again at install time to the user's
  own free-Apple-ID team, so the value is low-stakes.
- **Runner:** macOS 15.7.7, Xcode 16.4, iOS SDK 18.5. Deployment target 13.0. Orientation is
  landscape-only in Ren'Py's shipped `Info.plist` — a Milestone C decision, not yet made.
- **Hook timing is load-bearing** (Milestone A): `select_next_basedir` runs *after*
  `reload_all()`, so live teardown must happen in `lifecycle._restart()` before the exception.
- **`ru_maxrss` is peak RSS** and can never decrease; the iOS re-measurement must use
  `phys_footprint`, which is also what Jetsam meters.
- **No secrets in CI, ever.** Any step that appears to need one is a design failure.
- Working name `VNPlayer` is still a placeholder the user has not settled.

## Open decisions

- The product name and the display name under the icon.
- Whether to pursue the native memory leak upstream.
