# Design: Open-source iOS Ren'Py visual novel player

Date: 2026-08-24
Status: Approved design, pre-implementation
Working name: `VNPlayer` (final name is an open question, see §14)

## 1. Purpose

An iOS app that plays user-imported Ren'Py 8 visual novels. Free, open source, no ads,
no purchases, no time limits.

The immediate user is one specific person — computer-competent, not a developer — who
reads visual novels downloaded as `.zip` files, mostly Steam-era Ren'Py 8 titles. The
repository is public so anyone else can build, fork, or sideload it.

The three existing iOS players are all closed source. Two are paywalled; the free one
gates play behind escalating ad cooldowns. Their user complaints are almost entirely
about monetization friction rather than missing features, which is the gap this fills.

## 2. Scope

### v1 — what ships

- Import a `.zip` containing a PC Ren'Py 8 distribution
- A library: list of imported games with cover, title, size, last played
- Tap to play; the game runs full-screen
- A native touch overlay: quick save, quick load, back/rollback, skip, hide, magnifier,
  quit to library
- A pinch/pan magnifier over the rendered frame
- Return to library and launch a different game without restarting the app
- Delete a game; saves survive re-import

### v2 and later — explicitly deferred

Ren'Py 7 support (needs a second, Python 2 engine framework), 7z and apk import,
gallery/CG viewer, variable editor, on-device translation, iCloud save sync,
game controller support, Live2D.

## 3. Non-goals

- **The app never downloads a game.** No in-app browser, no catalogue, no URL import,
  no network game acquisition of any kind. This is a hard architectural rule, not a
  preference: it is the compliance posture that keeps App Store guideline 2.5.2
  arguable, and it is what every approved player in this category does.
- Not a Ren'Py development environment. No editing, no console, no launcher features.
- Not a content host or index. We ship zero game content.

## 4. Constraints

| Constraint | Consequence |
|---|---|
| No Mac available | All builds run on GitHub Actions `macos-15` runners. No step may require a local Xcode. |
| No Apple Developer Program membership | No TestFlight, no App Store. Distribution is an unsigned `.ipa` signed locally by the user with a free Apple ID via Sideloadly/SideStore. |
| Free-tier signing expires every 7 days | The app must survive being reinstalled frequently. Saves and library data must never live anywhere a reinstall can clear. |
| iOS forbids spawning processes | One process for the whole app lifetime. Game switching happens in-process. |
| Target user is not a developer | Errors must be legible and actionable. Install docs are a tracked deliverable. |

Pinned engine: **Ren'Py 8.5.3** (CPython 3.12.7, SDL3, MetalANGLE, FFmpeg 4.3.1).
Device: arm64 only. The minimum iOS version is inherited from the `renios` prototype
project's deployment target rather than chosen by us; we adopt whatever it sets and
record the value in M0. For reference, the comparable shipping apps require iOS 15.5
and 15.6, so expect something in that range.

## 5. Architecture

One process. Three `UIWindow`s. Ren'Py runs stock — the engine is never forked.

```
 iOS main thread
 ├─ main.c            SDL_RunApp(argc, argv, launcher_main, NULL)      [unmodified]
 │
 ├─ LibraryWindow     windowLevel .normal + 2   opaque    SwiftUI
 ├─ OverlayWindow     windowLevel .normal + 1   passthrough hitTest
 ├─ SDL game window   windowLevel .normal       MetalANGLE / CAMetalLayer
 │
 └─ Embedded CPython 3.12.7
    ├─ base/main.py            ours — monkey-patches, then boots Ren'Py
    ├─ base/shell/             ours — mailbox, purge, launcher project
    └─ renpy/                  stock Ren'Py 8.5.3
```

### 5.1 Why SDL keeps `main()`

`SDL_RunApp` calls `UIApplicationMain` and installs SDL's own app delegate, which owns
lifecycle, orientation, URL handling and event plumbing. Replacing that delegate means
reimplementing all of it. We layer above it instead. Ren'Py's own iOS prototype already
mixes `Age.swift`, `VideoPlayer.m` and `IAPHelper.m` over SDL this way, so the pattern
is established in-tree.

### 5.2 Why there is no engine fork

Ren'Py's root `main.py` is a stub that calls `renpy.bootstrap.bootstrap()`. Because the
iOS build looks for `<exedir>/base/main.py`, and we ship `base/`, we own that file. All
our engine-side behaviour is monkey-patching from a file we control:

```python
import renpy.bootstrap
import shell.lifecycle
renpy.bootstrap.get_alternate_base = shell.lifecycle.select_next_basedir
renpy.bootstrap.bootstrap(renpy_base)
```

Stock Ren'Py, patched at one seam, in one file. This keeps upgrades to new Ren'Py
releases cheap and keeps the door open to upstreaming proper multi-game support later.

### 5.3 The bundled launcher project

`base/launcher-shell/` is a minimal Ren'Py project — it creates the window, draws
nothing meaningful, and idles. It is the default basedir at cold launch and the return
target when a game exits.

This exists so that Ren'Py and SDL are **always in their normal operating mode**. The
alternative — parking Python in a hand-rolled `CFRunLoopRunInMode` loop before SDL has
initialised — was rejected: it is reentrant by construction (UIKit callbacks running
while Python sits inside a C extension frame), it risks GIL deadlock if any callback
touches Python, pumping only the default mode misbehaves for document-picker and
scroll tracking, and running UIKit's runloop is not the same as SDL doing a frame pump.

With the launcher project, idling is just a Ren'Py game sitting idle. SDL already
handles that correctly.

### 5.4 Game switching

```
 Swift                          Python
 ─────                          ──────
 user taps a game
 mailbox.post(.launch(path)) ──▶ periodic_callback drains mailbox
                                 sets shell.state.next_basedir
                                 raise UtterRestartException
                                    │
                                 bootstrap loop catches it
                                 renpy.reload_all()
                                 purge_engine_state()          ← ours
                                 get_alternate_base()          ← ours, returns next_basedir
                                 renpy.main.main()
 LibraryWindow.isHidden = true ◀─ bridge callback: gameDidStart
```

Quit-to-library is identical with `next_basedir` set back to the launcher project.

`get_alternate_base` is a **pure selector**: it reads state and returns a path. It never
waits for input and never performs cleanup. Waiting belongs to the running launcher
project; cleanup belongs to the purge step.

### 5.5 The bridge

A small C extension module, `shellbridge`, plus a Swift counterpart.

- **Swift → Python** is a mailbox, never a direct call. While a game runs, Python is
  inside Ren'Py's loop and cannot be called into. Swift appends commands to a queue; a
  `config.periodic_callbacks` handler drains it each frame.
- **Python → Swift** is a direct call, since Swift is always callable.
- Both sides touch the mailbox only on the main thread, so no locking is required.
  This invariant is asserted in debug builds.

Commands (Swift → Python): `launch(basedir)`, `quitToLibrary`, `quickSave`, `quickLoad`,
`rollback`, `toggleSkip`, `clearImageCache`.

Callbacks (Python → Swift): `gameDidStart(title)`, `gameDidExit`, `gameDidFail(traceback)`,
`progress(message)`.

## 6. Data and storage

```
Documents/
  Games/<gameId>/       basedir handed to Ren'Py as --basedir
  Saves/<gameId>/       config.save_directory override — outside the game tree
  Imports/<uuid>/       extraction staging; atomically moved or deleted
  library.json          library index
Library/Caches/covers/  derived, disposable
```

`Documents/` is exposed via `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`
so the Files app can manage games directly — useful for large sideloads and for manual
recovery.

**Saves live outside the game tree, deliberately.** Deleting or re-importing a game must
never destroy progress. Re-importing the same game offers *update in place, keep saves*
rather than orphaning them.

`gameId` is a slug, and it must be derivable **natively, before Ren'Py has ever run** —
we cannot boot the engine just to read `config.name`. It is derived from the archive's
top-level directory name with version and platform suffixes stripped (Ren'Py's own
distribution naming is `Title-1.2.3-pc`, `-mac`, `-linux`, `-market`), lowercased and
non-alphanumerics collapsed to hyphens. If the archive has no single top-level directory,
the archive filename is used the same way. The displayed title is the same string before
slugging, and the user can rename it; renaming changes the display title only, never the
`gameId`, so saves stay bound. Slug collisions between genuinely different games get a
numeric suffix, and the import sheet shows which existing game a re-import would update
so a false match can be declined.

`config.save_directory` is overridden per game. Ren'Py's default derives from the game's
own configured name, and generically-named games would otherwise share and overwrite each
other's saves.

`library.json` holds: `id`, `title`, `path`, `coverPath`, `sizeBytes`, `addedAt`,
`lastPlayedAt`, `detectedEngine`, `importedComplete`, `crashCount`. It is written
atomically and is rebuildable by rescanning `Games/` if lost.

## 7. Import pipeline

Entirely native Swift. No Python involvement. Streaming throughout — a multi-gigabyte
archive is never held in memory.

1. **Receive** via `UIDocumentPickerViewController`, share sheet, or Files "Open In".
2. **Check free space** for staging plus destination before writing anything.
3. **Stream-extract** to `Imports/<uuid>/` with hardening. Reject: `..` path traversal,
   absolute paths, symlinks resolving outside the root, encrypted entries, entry counts
   or total uncompressed sizes beyond configured caps, and per-entry sizes that are
   implausible relative to the archive.
4. **Locate the basedir** — the directory containing `game/`. If none, fail with
   *"This doesn't look like a Ren'Py game."*
5. **Prune during extraction, not after.** A denylist of platform cruft is never written
   in the first place: `lib/`, `renpy/`, `*.exe`, `*.app/`, `*.sh`. Everything else is
   extracted, including anything unrecognised. There is no destructive delete step.
   A per-import *import complete folder* toggle disables pruning entirely.
   Rationale: a PC distribution ships Windows, Linux and macOS binaries the phone can
   never execute — commonly 100–200 MB per game of dead weight.
6. **Detect the engine** from `.rpyc` magic — v1 is Ren'Py 7, v2 is Ren'Py 8. A v1 game
   is refused with *"This game needs Ren'Py 7, which isn't supported yet"* rather than
   being allowed to fail as a black screen at launch.
7. **Extract a cover** if one is present (`game/gui/window_icon.png`, `icon.png`).
8. **Atomically move** into `Games/<gameId>/` and write the library entry.

Progress is live and the operation is cancellable at every stage. This is the single
most-complained-about part of the competing apps and is treated as a first-class feature,
not plumbing.

## 8. Engine lifecycle and purge

Verified against `renpy/bootstrap.py` at 8.5.3:

- The restart loop is at line 355; the `finally` that calls `im.cache.quit()`,
  `draw.quit()` and `audio.audio.quit()` is at line 409, **outside** the loop. Nothing
  is torn down between games. Cleanup is entirely our responsibility.
- `except QuitException: exit_status = e.status` at line 393 exits the loop and reaches
  `sys.exit()` at line 407. **A game's own Quit button would terminate the app.** We hook
  `config.quit_action` to route to quit-to-library instead.

`base/shell/purge.py` runs between games. This is a **hypothesis list**, and the test
harness in §10 is what converts it into a verified list. Implementation proceeds by
running the harness and adding only what it proves necessary:

- stop audio and video playback
- `renpy.display.im.cache.clear()`, `renpy.display.render.free_memory()`
- drop every `sys.modules` entry whose `__file__` resolves under the previous basedir.
  This is deliberately scoped by path rather than by module-name prefix, so a game's
  `utils.py` cannot leak into the next game's `utils.py`
- determine empirically what `reload_all()` already resets — styles and stores in
  particular — and only add what it misses
- `gc.collect()`; log RSS before and after each cycle

Memory policy, given non-Pro iPhones are killed by Jetsam around 1.4–1.8 GB and a
4K RGBA8 background is roughly 33 MB of texture:

- `config.image_cache_size_mb` capped at 128 (the desktop default is far higher)
- Swift subscribes to `didReceiveMemoryWarningNotification` and posts `clearImageCache`
- the A→B transition is the peak, since MetalANGLE does not always release `MTLTexture`
  promptly on GLES delete; purge runs before the next game loads, not after

## 9. Native UI

**LibraryWindow** — SwiftUI, opaque, `.normal + 2`. Game grid, import button, per-game
detail (size, last played, delete, re-import, export saves), settings.

**OverlayWindow** — `.normal + 1`, transparent, scene-bound and strongly retained.
Its root view overrides `hitTest(_:with:)` to return `nil` outside the controls, so every
other touch reaches the game. Without this, a plain `UIWindow` swallows all input and
the game receives nothing.

Controls: quick save, quick load, back/rollback, skip toggle, hide UI, magnifier toggle,
quit to library. Summoned by a small floating handle — it must never permanently occlude
the game's own UI.

**Magnifier** — a `CATransform3D` scale and translate applied to the SDL view. It never
touches Ren'Py, so it cannot break any game's layout. This replaces text-size scaling,
which was cut because Ren'Py games position UI with hardcoded pixel geometry; changing
font size clips dialogue out of its box and breaks custom screens.

**Orientation** — secondary windows must be constructed with the active `UIWindowScene`.
The overlay view controller's supported-orientation mask must agree with SDL's, or iOS
raises `UIApplicationInvalidInterfaceOrientation`.

**Rendering while in the library** — SDL's `CADisplayLink` must be paused when
LibraryWindow is shown, or it keeps presenting into a stale MetalANGLE context.

### Error surfaces and recovery

Ren'Py's built-in error screen is laid out for a desktop and is effectively unusable at
phone scale, so engine errors are surfaced natively instead.

**Game exceptions.** An uncaught exception is caught at the bootstrap seam and reported
through `gameDidFail(traceback)`. Swift presents a sheet containing the traceback, a
*Copy Log* button and *Return to Library*. Ren'Py still writes `traceback.txt` into the
game directory; the sheet reads it when available, since it carries more context than the
exception alone. The app returns to the library rather than terminating.

**Import failures are specific, never generic.** Each failure mode from §7 maps to its
own message and its own suggested action: insufficient free space (with the shortfall
stated), not a Ren'Py game, this needs Ren'Py 7, corrupt archive, password-protected
archive, unsafe paths in archive. A cancelled or failed import removes its staging
directory and leaves no library entry.

**Repeated launch crashes.** `crashCount` in `library.json` increments when a game fails
before reaching its first interaction and resets on a successful session. At two, the
launch sheet offers a reduced-cache safe mode — smaller `image_cache_size_mb`, video
disabled — and a *Report* action that copies a sanitised diagnostic (engine version,
device model, free memory, traceback) to the clipboard for a GitHub issue.

**Memory pressure.** `didReceiveMemoryWarningNotification` triggers `clearImageCache`
immediately. A game killed by Jetsam leaves no in-process trace, so the next launch
detects the unclean shutdown from a launch marker file and offers safe mode directly.

**Failure to purge.** If the purge step in §8 raises, the error is logged and the game
switch is aborted back to the library rather than proceeding into a known-dirty engine
state. Reaching this path in the wild indicates the §10.1 harness has a gap.

## 10. Testing

### 10.1 Engine cycling harness — the load-bearing test

Runs headless on the iOS Simulator (`sim-arm64`, matching the Apple Silicon `macos-15`
runners) via `xcodebuild test`. The `renios` prebuilts include simulator libraries, so
this needs neither a Mac nor a device.

Two sentinel games, cycled 50–100 times:

- **Game A** ships `sentinel.py` with `VALUE = "A"`, overrides `style.default.font`,
  loads a large image, plays audio, writes a save, sets a store variable.
- **Game B** ships its own `sentinel.py` with `VALUE = "B"` and asserts: it reads `"B"`;
  `style.default.font` is the default; its save directory is its own; Game A's store
  variable is absent.

The run fails on module contamination, wrong save directory, crash, or monotonic RSS
growth beyond a threshold across cycles.

This test is what validates §8. The purge list is derived from its failures, not from
speculation.

### 10.2 Extractor unit tests

Swift tests over crafted archives: zip-slip, symlink escaping the root, encrypted entry,
entry-count bomb, uncompressed-size bomb, missing `game/`, Ren'Py 7 `.rpyc` magic,
nested basedir, archive with no top-level directory.

### 10.3 Not in v1

UI automation tests. The surface is small and the harness covers the genuinely risky part.

## 11. Build and distribution

The repository contains our Xcode project, Swift sources, `base/` overlay files, the two
sentinel games and the CI workflow. It does **not** contain the 130 MB `renios` blob.

CI (`macos-15`):

1. Download `renpy-8.5.3-renios.zip` from renpy.org, verify against the published
   `renpy-8.5.3-renios.sums`
2. Unpack; copy prebuilt static libraries and the `base/` tree into the build
3. Overlay our `base/main.py`, `base/shell/` and `base/launcher-shell/`
4. Run extractor unit tests and the cycling harness on the simulator
5. Archive and emit an **unsigned `.ipa`**
6. Attach it to a GitHub Release

**Unsigned output is a deliberate choice.** Sideloadly signs locally with the user's own
free Apple ID, so CI holds **no secrets at all** — no certificates, no provisioning
profiles, no App Store Connect key. Any fork gets reproducible builds, and the entire
code-signing-in-CI problem disappears. Free-tier certificates expire after 7 days
regardless, so storing them in CI would buy nothing.

`INSTALL.md` — the Sideloadly walkthrough, with screenshots and the weekly re-sign
explanation — is a tracked deliverable and a release blocker.

## 12. Licensing and compliance

Our code: **MIT**. Explicitly not GPLv3, which conflicts with Apple's distribution terms
(the VLC precedent) and would foreclose any future App Store route.

Bundled components: Ren'Py is MIT with LGPL-derived portions; FFmpeg is LGPL; SDL3,
SDL3_image and freetype are Zlib; Python is PSF; harfbuzz is Old MIT; libpng, bzip2 and
zlib carry their own permissive licences. Static linking plus published corresponding
source satisfies the LGPL obligations, which being open source we meet inherently. We
ship the full licence set and Ren'Py's recommended attribution line: *"This program
contains free software licensed under a number of licenses, including the GNU Lesser
General Public License."*

Live2D Cubism Core is proprietary and cannot be redistributed here. It is excluded, and
Live2D games will not render their models.

App Store guideline 2.5.2 prohibits executing code that changes app functionality, and
the 4.7 carve-out covers only HTML5 mini-apps and emulators. Imported Ren'Py games are
executable Python, so a submission would be genuinely at risk. Four comparable apps are
nonetheless approved, and their common posture — the user supplies everything locally,
the app downloads nothing — is the one we adopt. This matters only if we later pursue
the App Store; it does not affect sideloaded v1.

## 13. Milestones

- **M0 — Pipeline spike.** Bare Xcode app plus renios libraries plus one hardcoded
  bundled game, built by CI into an unsigned `.ipa`, installed via Sideloadly, running on
  the device. Nothing else. Falsifies the riskiest infrastructure assumption first.
- **M1 — Cycling harness.** The §10.1 test, red, then the purge layer built until green.
  Validates the core architecture before any UI exists.
- **M2 — Library and import.** Extractor with its unit tests, storage layout, SwiftUI
  library, launch a chosen game.
- **M3 — Overlay.** Bridge mailbox, overlay window, controls, magnifier, quit-to-library.
- **M4 — Polish and ship.** Error sheets, memory handling, `INSTALL.md`, first release.

## 14. Risks and open questions

| Risk | Mitigation |
|---|---|
| CI cannot build the renios Xcode project unattended | M0 exists to find this out first, before anything is built on top of it |
| `reload_all()` cannot cleanly reset between different games | M1 measures it directly; if it proves unfixable, the fallback is one game per app launch with a native restart prompt — degraded, not fatal |
| MetalANGLE texture retention causes Jetsam kills on switching | Purge before load, cap image cache, memory-warning hook; the harness measures RSS across cycles |
| Debugging without a Mac | Harness runs in CI; a macOS VM or short cloud-Mac rental is available as an escalation, never a dependency |
| Case-sensitivity differences between simulator and device filesystems | Unverified. iOS device APFS is case-insensitive by default, so this is likely a non-issue; the harness will reveal it if not. Not designed around pre-emptively |

Open question: **the product name.** `VNPlayer` is a placeholder used throughout this
document and in module prefixes; it needs replacing before M2, since bundle identifiers
are awkward to change once installed.
