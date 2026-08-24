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

Pinned engine: **Ren'Py 8.5.3** (CPython 3.12.7, SDL3, MetalANGLE, FFmpeg 4.3.1). The
CPython 3.12.7 figure is confirmed for the desktop SDK build (`vendor/renpy-8.5.3-sdk/`,
per `docs/BUILD.md`); the iOS/`renios` build's bundled interpreter version has not been
separately confirmed and must not be assumed identical.
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

`base/main.py` is loaded by Ren'Py as `renpy.__main__` — this is Ren'Py's own documented
seam for distributor customization, not an ad hoc hook we invented. Two more
overrides belong here, verified on the desktop harness (`docs/BUILD.md`) rather than
assumed: `path_to_saves`, which is how per-game save isolation is actually achieved
(§6 — superseding an earlier, incorrect assumption that `config.save_directory` was the
right seam), and `path_to_gamedir`, overridden deliberately strictly so that a basedir
without a proper `game/` subdirectory fails fast instead of Ren'Py silently searching
elsewhere for one (this is also why §7's import pipeline treats "no `game/` found" as a
hard rejection, not a fallback).

### 5.3 The bundled launcher project

`base/launcher-shell/` is a minimal Ren'Py project — it creates the window, draws
nothing meaningful, and idles. It is the default basedir at cold launch and the return
target when a game exits.

Like every basedir Ren'Py boots into, it must ship a real `game/` subdirectory:
`bootstrap.py:334` calls `path_to_gamedir()` *before* the restart loop even starts, so
this is a hard requirement of the very first cold launch, not only of later switches.

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
                                 teardown_live_engine()        ← ours, outgoing engine still live
                                 raise UtterRestartException
                                    │
                                 bootstrap loop catches it
                                 renpy.reload_all()
                                 purge_engine_state()          ← ours, sys.modules only (§8)
                                 get_alternate_base()          ← ours, returns next_basedir
                                 renpy.main.main()
 LibraryWindow.isHidden = true ◀─ bridge callback: gameDidStart
```

Quit-to-library is identical with `next_basedir` set back to the launcher project.

`get_alternate_base` is a **pure selector**: it reads state and returns a path. It never
waits for input and never performs cleanup. Waiting belongs to the running launcher
project; cleanup belongs to the purge step — which, as measured on the desktop harness,
is split across two hook points rather than one; see §8 for why.

**In-process game switching works.** This was the single biggest open question in this
design and it is now measured, not assumed: on the desktop harness
(`docs/BUILD.md`), `UtterRestartException` raised from a `config.periodic_callbacks`
handler propagates out cleanly, `reload_all()` runs, and a different game loads — over
**100 consecutive switches**, with engine exit status 0 every time, no crash, no hang,
and no traceback. The fallback previously carried in §14 ("one game per app launch") is
**not needed** and has been removed from the open-risk table on that basis.

The one lesson from getting this working that is load-bearing enough to call out here:
**hook timing.** `select_next_basedir` (and therefore `get_alternate_base` and
`purge_engine_state`) runs *after* `renpy.reload_all()`, by which point the outgoing
game's renderer, audio subsystem and caches have already been replaced by freshly
constructed, still-empty objects. Teardown of the *outgoing* game's live native
resources has to happen earlier — before `UtterRestartException` is raised — or it is
operating on the wrong objects. See §8.

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
  Saves/<gameId>/       path_to_saves override (main.py) — outside the game tree
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

`path_to_saves` is overridden per game, in `main.py` (§5.2) — not `config.save_directory`,
which an earlier draft of this spec named and which is not the right seam. Ren'Py's
default save location derives from the game's own configured name, and generically-named
games would otherwise share and overwrite each other's saves; this was verified directly
on the desktop harness, not just reasoned about: both sentinel games declare an
*identical* `config.save_directory` and still land in separate, correctly isolated save
directories under the `path_to_saves` override.

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

- The restart loop is at line 373; the `finally` that calls `im.cache.quit()`,
  `draw.quit()` and `audio.audio.quit()` is at line 427, **outside** the loop. Nothing
  is torn down between games. Cleanup is entirely our responsibility.
- `except QuitException: exit_status = e.status` at line 411 exits the loop and reaches
  `sys.exit()` at line 425. **A game's own Quit button would terminate the app.** We hook
  `config.quit_action` to route to quit-to-library instead.

`base/shell/purge.py` runs between games, at two distinct hook points. What follows is
the **verified list** from the desktop harness (`docs/BUILD.md`, "Purge findings"),
not a hypothesis list — every line below was tried and its effect measured, over runs
up to 100 consecutive A→B/B→A switches.

**Hook timing is load-bearing.** `select_next_basedir` — and therefore anything called
from it, including `get_alternate_base` and the post-reload purge — runs *after*
`renpy.reload_all()`, by which point the outgoing game's renderer, audio subsystem and
caches have already been replaced by freshly constructed, empty objects. Cleanup at that
point has nothing live left to act on beyond `sys.modules`, which persists across
`reload_all()` regardless (`sys.path` is also filtered at this hook, but bootstrap.py
resets it unconditionally on every pass, so that filter has no observable effect — see
below). The outgoing game's actual GL surfaces, audio buffers
and font caches remain live and reachable only *before* `UtterRestartException` is
raised — measured on desktop as the call site that triggers the restart
(`lifecycle._restart()`). This is the single most transferable lesson from Milestone A:
anyone re-implementing this on iOS needs to put live-engine teardown at that earlier
point, not in the post-reload hook, or it silently does nothing.

**Post-reload hook** (`purge_engine_state()`, after `reload_all()`, before
`get_alternate_base()`):

- **Necessary** — the only step that measurably fixed a reported failure: purge every
  `sys.modules` entry whose `__file__` resolves under the previous game's
  `<basedir>/game` directory. Scoped to `<basedir>/game`, **not** `<basedir>` itself —
  the shell project's own basedir is the SDK/app root, and purging "everything under the
  previous basedir" measurably purges the running interpreter's own modules out from
  under itself on the very first shell→game switch (reproduced on desktop:
  `ModuleNotFoundError: No module named '__main__'`, engine exit status 1). Scoping to
  `game/` is not a weaker version of purging the whole basedir; it is the scope that
  actually matches how games load (`config.gamedir == basedir/game`, and every game does
  `sys.path.insert(0, renpy.config.gamedir)`). After this fix, `sys.modules`
  contamination was confirmed gone over 200 launches across two independent 100-cycle
  runs — zero contamination in either. (The implementation also strips the matching
  entries from `sys.path` at this same hook, but that is belt-and-braces, not part of
  the fix: `bootstrap.py:387` resets `sys.path = list(original_sys_path)`
  unconditionally, eight lines after it calls `get_alternate_base()`, in the same
  `try`, before any import happens — so whatever this hook does to `sys.path` has no
  observable effect on the running interpreter. Only the `sys.modules` purge is
  load-bearing.)
- **Measured unnecessary here:** `renpy.display.im.cache.clear()` and
  `renpy.text.font.free_memory()` ran cleanly but produced no measurable RSS effect;
  `renpy.display.render.free_memory()`, `renpy.audio.music.stop()` and
  `renpy.display.video.movie_stop()` raised (`AttributeError`/`IndexError`) on every
  call, because their owning subsystems (`renpy.game.interface` and friends) do not
  exist yet at this point in the restart loop; `gc.collect()` freed ~9,700 objects per
  switch with no measurable RSS effect. None of these are in `purge_engine_state`.

**Pre-restart hook** (`teardown_live_engine()`, called just before
`UtterRestartException` is raised, while the outgoing game's engine objects are still
live):

- **Necessary, if any per-switch teardown of live objects is to happen at all** — six
  calls, run mid-session instead of at process exit: stop audio (all channels), stop
  video, free fonts, quit the image cache, quit the renderer
  (`renpy.display.draw.quit()`), quit the audio subsystem. Only **three** of these six —
  quit the image cache, quit the renderer, quit the audio subsystem — actually appear in
  Ren'Py's own process-exit sequence (`bootstrap.py:427-438`); the other three (stop
  audio, stop video, free fonts) have no engine-authored counterpart there and are ours,
  added because the engine's own teardown, which only ever runs once at process exit,
  does not cover everything a live game leaves behind mid-session. All six were measured
  to succeed, every switch, over 100 consecutive switches, with zero tracebacks —
  including `renpy.display.draw.quit()` followed by the
  next restart pass re-initialising the renderer, which was the most uncertain of the six
  going in and turned out to be safe.
- **They do not fix the memory-growth failure** (below), and by the letter of "only add
  what a measured failure justifies" they have no such justification — they are kept
  anyway because they have now been measured safe over 100 consecutive switches (three of
  them additionally being Ren'Py's own documented teardown, the other three ours). The
  iOS port must **re-measure these six on-device rather than inherit this
  result in either direction**: RSS on Windows does not see driver-side GL allocations,
  and iOS runs a categorically different graphics stack (MetalANGLE over Metal, not
  Windows OpenGL) — a null effect here is not evidence they are safe to drop on iOS, and
  it would not have been evidence to keep them had the effect been positive here either.

**Measured clean, requiring no purge at all:** save-directory isolation (§6), store
variables, and per-game init-time declarations (`config.name`, verified both directions,
every launch — see §10.1). **Mutable style state remains untested, not clean** — three
canary attempts at it across this milestone failed as instruments before ever producing
a trustworthy result either way (§10.1) — and must not be assumed safe by the iOS plan.

**Memory: the important negative result.** Neither hook reduces the engine's per-switch
memory growth. RSS grows roughly linearly at **~22 MB per switch**, with no sign of a
plateau, confirmed over two independent 100-cycle runs on the desktop harness — one with
only the post-reload hook active (135.6 MB → 2,359.6 MB, ≈22.2 MB/switch), one with the
pre-restart teardown added (136.1 MB → 2,352.2 MB, ≈21.9 MB/switch). The growth rate is
unchanged between the two runs, which rules out "wrong hook" as the explanation: the leak
is native, inside Ren'Py's own C/GL/SDL layer, and is not reachable from either hook
point available to this shell layer. Fixing it would require modifying `renpy/`, which
this task was not permitted to do. From a ~200 MB baseline, this is on the order of
**54 switches** before reaching a 1.4 GB Jetsam ceiling — using minimal synthetic
sentinel games; real visual novels, with larger asset sets, would very likely reach it
sooner. This is recorded here as a hard constraint the iOS design must accommodate,
**not as a solved problem** — no mitigation is decided in this document (see §14); a
per-session switch limit is one candidate, but choosing one is a product decision this
milestone did not make.

Memory policy for the image cache specifically, given non-Pro iPhones are killed by
Jetsam around 1.4–1.8 GB and a 4K RGBA8 background is roughly 33 MB of texture — this is
an iOS-only design decision, not something the desktop harness could measure (no
MetalANGLE on desktop), and it addresses a different, narrower problem than the native
per-switch leak measured above:

- `config.image_cache_size_mb` capped at 128 (the desktop default is far higher)
- Swift subscribes to `didReceiveMemoryWarningNotification` and posts `clearImageCache`
- the A→B transition is the peak, since MetalANGLE does not always release `MTLTexture`
  promptly on GLES delete; purge runs before the next game loads, not after
- this mitigates image-cache-driven growth specifically; it does **not** address the
  ~22 MB/switch native leak above, which is orthogonal and currently unmitigated

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

Note for whoever builds this: the desktop version of this harness (`docs/BUILD.md`) had
to run against a separate, full-stdlib interpreter rather than the Ren'Py SDK's own
bundled one, because the SDK ships a stripped, `.pyc`-only standard library with no
`unittest` module. The `renios` build is likely to have the same property; plan the iOS
harness's Python-side assertions (if any run inside the embedded interpreter rather than
purely as XCTest/Swift checks) accordingly.

**The memory instrument must not be ported as-is.** The desktop harness's POSIX RSS
fallback (`shell/vnshell/harness.py:_rss_bytes`) reads `resource.getrusage(...).ru_maxrss`
— *peak* resident set size since process start, not current RSS. It can only ever
increase, so it cannot distinguish "teardown is releasing memory" from "teardown is
doing nothing": both would read the same monotonically non-decreasing curve. That
happens not to matter for what the desktop harness needed to prove (that unbounded
growth exists at all), but it would silently defeat the entire purpose of an on-device
run, which is to find out whether the purge steps in §8 actually help. The iOS harness
must instead read `task_info(TASK_VM_INFO).phys_footprint` — *current* memory, and the
same figure the kernel's Jetsam mechanism itself uses to decide whether to kill the
process, making it the more meaningful number on this platform even setting the
peak-vs-current issue aside.

Two sentinel games, cycled 50–100 times:

- **Game A** ships `sentinel.py` with `VALUE = "A"`, declares `config.name = "Sentinel A"`
  in its own init-time declarations, loads a large image, plays audio, writes a save,
  sets a store variable.
- **Game B** ships its own `sentinel.py` with `VALUE = "B"` and its own
  `config.name = "Sentinel B"`, and asserts: it reads `"B"`; `config.name` reads
  `"Sentinel B"`, never `"Sentinel A"`; its save directory is its own; Game A's store
  variable is absent.

`config.name` was chosen after two earlier canaries built around `style.default.font`
and `style.default.size` both turned out to be broken instruments rather than clean
results — the font canary matched Ren'Py's own engine-wide default
(`00style.rpy:139`) and so could not discriminate contamination from a clean reset, and
the size canary's own marker was never read back because mutating a style outside an
`init` block requires an explicit `style.rebuild()` that the fixture never called.
`config.name` tests per-game **init-time declarations** — a value re-evaluated as part
of each game's own init phase on restart — and it produced the first trustworthy
pass-or-fail result of the three attempts. It is **not** the same claim as "styles don't
bleed": mutable style objects (`style.default` and similar) are a different surface, one
this harness has not yet exercised successfully, and the iOS plan should treat that
surface as untested rather than clean.

The run fails on module contamination, wrong save directory, crash, or monotonic RSS
growth beyond a threshold across cycles.

This test is what validates §8. The purge list is derived from its failures, not from
speculation. On the desktop harness, the module-contamination and save-isolation halves
of this test now pass cleanly (200 launches, zero failures); the RSS-growth half does
not, and is not expected to pass without either an iOS-specific mitigation or a relaxed
threshold that reflects the accepted switch limit — see §8 and §14.

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
- **M1 — Cycling harness.** The §10.1 test, red, then the purge layer built to close
  every failure it can close. On the desktop harness (`docs/BUILD.md`) this fully closed
  the module-contamination and save-isolation failures (zero failures over 200 switches)
  but did **not** close the memory-growth failure, which was traced to a native leak
  outside the reach of either purge hook (§8). M1 on iOS should expect the same split
  result — treat contamination as fixable to green, and treat memory growth as a
  constraint to design around (§14), not a bug this layer can fix. Validates the core
  architecture before any UI exists.
- **M2 — Library and import.** Extractor with its unit tests, storage layout, SwiftUI
  library, launch a chosen game.
- **M3 — Overlay.** Bridge mailbox, overlay window, controls, magnifier, quit-to-library.
- **M4 — Polish and ship.** Error sheets, memory handling, `INSTALL.md`, first release.

## 14. Risks and open questions

| Risk | Mitigation |
|---|---|
| CI cannot build the renios Xcode project unattended | M0 exists to find this out first, before anything is built on top of it |
| `reload_all()`-based switching leaves stale Python-level state between games | **Resolved on desktop**, not just mitigated: scoping the `sys.modules` purge to `<basedir>/game` (§8) eliminates it, verified over 100 consecutive switches with zero contamination across two independent 100-cycle runs, engine exit 0 every time. The earlier fallback of "one game per app launch" is **not needed** and is removed. One caveat carried forward: mutable style state (`style.default` and similar) was never successfully exercised as a contamination surface and remains untested, not confirmed clean (§8, §10.1) |
| Native per-switch memory growth causes Jetsam kills on switching | **Not resolved.** Measured on the desktop harness at ~22 MB/switch, linear, no plateau, across two independent 100-cycle runs and both available teardown hook points (§8) — moving teardown to the theoretically-correct pre-restart hook did not change the rate. The leak is native (inside Ren'Py's own C/GL/SDL layer) and unreachable from the shell layer at either hook point available to it; fixing it would require modifying `renpy/`, which is out of scope. From a ~200 MB baseline this is on the order of 54 switches before a 1.4 GB Jetsam ceiling, using minimal synthetic games — real visual novels would likely reach it sooner. The app cannot currently switch games freely for an unbounded session; some form of switch limit or other mitigation is needed, but which one is a product decision not made in this document. The harness must be re-run on-device before trusting this number either way, since MetalANGLE/Metal is a categorically different graphics stack from the Windows/OpenGL driver this was measured against |
| Debugging without a Mac | Harness runs in CI; a macOS VM or short cloud-Mac rental is available as an escalation, never a dependency |
| Case-sensitivity differences between simulator and device filesystems | Unverified. iOS device APFS is case-insensitive by default, so this is likely a non-issue; the harness will reveal it if not. Not designed around pre-emptively |
| iOS/`renios` bundled CPython version assumed identical to the desktop SDK's (3.12.7) | Unverified (§4). Confirmed only for the desktop SDK inspected in `docs/BUILD.md`; must be checked against the actual `renios` build rather than assumed |

Open question: **the product name.** `VNPlayer` is a placeholder used throughout this
document and in module prefixes; it needs replacing before M2, since bundle identifiers
are awkward to change once installed.
