# M2 — Library and Import: design

**Status:** draft for review
**Date:** 2026-08-25
**Parent spec:** [`2026-08-24-renpy-ios-player-design.md`](2026-08-24-renpy-ios-player-design.md) §6, §7, §9, §13
**Depends on:** M0 (pipeline, complete), M1 (switching harness, complete on desktop),
the Swift-overlay spike (`spike/FINDINGS.md`, answered 2026-08-25)

---

## 1. What M2 delivers

The app currently boots Ren'Py and shows a diagnostic screen. M2 makes it hold games:

1. Import a Ren'Py 8 game from a `.zip` the user already has on their phone.
2. List imported games in a native library.
3. Launch one, and come back to the library from it.

After M2 the user's sister can put a game on the phone and read it. Everything M3 adds
(in-game overlay controls, magnifier, quick save) is comfort on top of a working reader.

## 2. What is already proven, and therefore not at risk here

These are device-measured, not assumed. Each one removes a design question M2 would
otherwise have to hedge against.

| Fact | Evidence |
|---|---|
| A second `UIWindow` composites over SDL's window | Pure-UIKit control rendered on device, 2026-08-25 |
| SwiftUI hosts inside that window | Red panel rendered alongside the UIKit control |
| Touches reach SwiftUI controls in it | `posted: 0 -> 1` on tap |
| Swift can hand data to Python | `from Swift: 1 received` in Ren'Py, same tap |
| The engine keeps running underneath | `alive for 2s -> 8s` across the interaction |
| Saves and logs can be written | `vnshell.platform`, this branch; device-confirm pending |
| Game switching does not leak Python state | M1, 200 desktop switches, zero contamination |

**Not proven, and M2 must not assume it:** that Ren'Py still receives touches *outside*
the overlay's controls. The passthrough `hitTest` is written but untested, because the
shell project sits in `renpy.pause(hard=True)` and ignores clicks by design. M2 produces
the first build where a real game is running underneath, so M2 is where this gets
verified — see §11.

## 3. Constraints

Inherited, unchanged:

- **No secrets in CI, ever.** No certificates, no provisioning profiles, no repository
  secrets. The build must work identically on any fork.
- **Never modify Ren'Py's source.** Nothing under `vendor/` is edited in place.
- **The app must never download a game.** Import is from local files only (App Store
  2.5.2 posture), even though this build ships outside the App Store.
- **MIT licence; GPLv3 forbidden.** This governs the zip decision in §7.1.
- **Never raise a threshold or weaken an assertion to make a check pass.**

Lifted, deliberately, and this needs to be stated plainly because it was a hard rule
until now:

- **"The `shell/` layer ships unchanged"** was a *Milestone B* constraint. Its purpose
  was to stop the iOS pipeline milestone from hacking the engine shell to paper over
  platform problems, and to force them to be reported instead. That worked: the
  `path_to_saves` defect was reported rather than patched around. M2 is the milestone
  that *acts* on those reports, so `shell/` is now in scope for change. It is not a
  free-for-all: changes to `shell/` must keep desktop behaviour identical, which is
  what `vnshell.platform`'s fallback-passthrough design enforces and what the desktop
  test suite checks.

New for M2:

- **Third-party code is vendored as source, never fetched at build time.** See §7.1.
  The earlier draft said "no third-party runtime dependencies" and that turned out to be
  the wrong rule — what the project actually needs is reproducibility on any fork, and a
  pinned copy in-repo delivers that better than a fetch does.
- **Every extractor rejection must be a distinct, user-readable reason.** A generic
  "import failed" is a defect, not a fallback.

## 4. Architecture

**Two** windows on one `UIWindowScene`, and one engine process.

```
 .normal + 1   VNPlayerWindow   one window, a container VC that swaps between:
                                  LibraryView  (SwiftUI, opaque)
                                  OverlayView  (SwiftUI, transparent)  — M3
 .normal       SDL's window     Ren'Py renders here
```

This is a **change from the parent spec**, which called for the library at `.normal + 2`
as a second window above the overlay. Both reviewers argued against it independently
(§15), and the deciding reason is modal presentation: `UIDocumentPickerViewController`
has to be presented from the window that owns the interaction, and our overlay window
deliberately does *not* take key status from SDL. One window that can take key while the
library is up, and give it back when the library is dismissed, is both simpler and the
only version where the picker is on firm ground.

The library is opaque and covers everything, so while it is up the engine is not visible.
The engine is still *running* — it sits in the shell project's idle loop, which is what
receives the launch command. See §9 on why it must keep running.

Control flow for a launch, end to end:

```
LibraryView (Swift)
  writes Commands/<uuid>.json  (temp name, then renamed — see §10)
  {"command":"launch","commandId":...,"basedir":...,"gameId":...}
        |
        v
vnshell.lifecycle.tick()  (config.periodic_callbacks, every frame)
  FileTransport drains the line
        |
        v
_handle_launch -> STATE.next_basedir / current_game_id -> UtterRestartException
        |
        v
Ren'Py's bootstrap restart loop -> get_alternate_base -> select_next_basedir
  purges the outgoing game, returns the new basedir
        |
        v
the game reaches its first interaction; Python writes Events/<uuid>.json {"event":"gameReady"}
        |
        v
Swift sees gameReady for ITS commandId, and only then hides the library
```

**The library is hidden on `gameReady`, never on the write.** If it were hidden when the
command was written, a game that fails to boot — a syntax error, a missing dependency, a
Ren'Py 7 archive that slipped through — would leave the user staring at whatever SDL last
drew, with no way back. Both reviewers raised this independently and both were right: the
write is a request, not an outcome. A watchdog (§10) covers the case where `gameReady`
never arrives.

**All of the Python half of this already exists and is desktop-tested** (M1: `launch` and
`quitToLibrary` handlers, `select_next_basedir`, `purge`). M2 writes the Swift half and
the storage underneath it. That is the main reason M2 is tractable in one milestone.

### 4.1 Who owns what

| Concern | Owner | Why |
|---|---|---|
| Reading the archive | Swift | Streaming, cancellable, progress; Python is busy being an engine |
| Deciding `gameId` | Swift | Must be known before Ren'Py has ever run (§6) |
| `library.json` | Swift | The library UI is the only reader |
| Which basedir to load | Python (`vnshell.state`) | It is engine state, and survives the restart |
| Purging between games | Python (`vnshell.purge`) | Only Python can see Python's leaks |
| Save isolation | Python (`path_to_saves`) | Ren'Py asks for it by calling us |

## 5. Storage layout

Per parent spec §6, with the concrete on-device paths now known:

```
<Data container>/Documents/                    EXPOSED to the Files app
  Games/<gameId>/                              basedir handed to Ren'Py
  Saves/<gameId>/                              path_to_saves target — outside the game tree

<Data container>/Library/Application Support/VNPlayer/    HIDDEN from the Files app
  library.json                                 the index
  Commands/                                    Swift -> Python spool (§10)
  Events/                                      Python -> Swift spool (§10)
  Imports/<uuid>/                              staging; moved or deleted, never left behind
  Trash/<uuid>/                                deferred deletion (§8)

<Data container>/Library/Caches/covers/        derived, disposable
```

**Only `Games/` and `Saves/` are exposed.** The earlier draft put the index and the IPC
files in `Documents/` too, which would have shown the user `library.json` and
`vnplayer-commands.jsonl` in the Files app and let a curious tap break the app's control
plane. The exposure is there so saves can be backed up and a broken game can be removed
by hand; neither of those needs the state machine's files to be visible. Both reviewers
raised this independently.

`Imports/` moving out of `Documents/` also matters for a second reason: staging a
multi-gigabyte extraction somewhere the user can watch it appear and "tidy it up"
mid-import is a support problem waiting to happen.

`<Data container>` is `os.path.expanduser("~")` in Python and `NSHomeDirectory()` in
Swift; both resolve to `/var/mobile/Containers/Data/Application/<uuid>/`, which is a
different filesystem location from the read-only bundle at
`/var/containers/Bundle/Application/<uuid>/VNPlayer.app/`. Confusing the two is what
caused the sandbox denials this branch fixes.

**Saves live outside the game tree deliberately.** Deleting or re-importing a game must
never destroy progress.

`Documents/` is exposed with `UIFileSharingEnabled` and
`LSSupportsOpeningDocumentsInPlace`, so the Files app can manage games directly. This is
both a convenience and the manual-recovery path when something goes wrong — worth having
on a sideloaded app with no crash reporting.

## 6. `gameId`

Must be derivable **natively, before Ren'Py has ever run** — booting the engine to read
`config.name` is not available to us at import time.

Derivation, in order:

1. Take the archive's single top-level directory name. If the archive has no single top
   level directory, take the archive's filename without extension.
2. Strip Ren'Py's own distribution suffixes: `-pc`, `-mac`, `-linux`, `-market`,
   `-all`, and a trailing version like `-1.2.3`.
3. That string, unchanged, is the **display title**.
4. Lowercase it, collapse every run of non-alphanumeric characters to a single hyphen,
   and trim hyphens from both ends. That is the **`gameId`**.
5. If the id is empty after that, or collides with an existing *different* game, append
   `-2`, `-3`, and so on.

Renaming a game in the library changes the display title only, never the `gameId`, so
saves stay bound to it. A re-import that resolves to an existing `gameId` shows which
game it would update, so a false match can be declined.

## 7. Import pipeline

Entirely native Swift, streaming throughout, cancellable at every stage. A
multi-gigabyte archive is never held in memory.

### 7.1 Reading the archive: vendored ZIPFoundation

**Decision, REVERSED from this document's first draft: vendor ZIPFoundation as source
rather than hand-write a ZIP reader.**

The first draft argued for a hand-written reader on two grounds — hardening control and
fork-reproducibility. Both reviewers independently rejected it (§15), and on inspection
both of my grounds were weaker than they looked:

- **Hardening control survives the dependency.** ZIPFoundation exposes a consumer-closure
  form of `extract`, which hands us decompressed chunks and lets *us* decide the
  destination path, whether to write at all, and when to stop. Every §7.3 decision is
  still ours and still taken before a byte is written. The thing I thought required
  owning the read loop does not.
- **Reproducibility is better, not worse.** The library is 21 Swift files, 225 KB, MIT,
  with no dependencies of its own. Copied into `third_party/ZIPFoundation/` it is pinned
  by our own git history — strictly stronger than a fetch script, and it needs no network
  at build time at all.

Against that, a hand-rolled parser owns ZIP64 extra fields, data descriptors, multi-disk
detection and a decade of format corner cases, in the one component that parses hostile
input. That is a bad trade for a project with no Mac to debug on and one CI round-trip
per attempt.

**Pinned:** ZIPFoundation `0.9.19`, commit `02b6abe5f6eef7e3cbd5f247c5cc24e246efcfe0`,
MIT, upstream `https://github.com/weichsel/ZIPFoundation`. Deployment floor iOS 9 —
comfortably under our iOS 13. `third_party/ZIPFoundation/PROVENANCE.md` records this and
`scripts/verify_third_party.sh` re-checks our copy against upstream on demand.

**One claim checked rather than accepted.** One reviewer warned that Apple's
`COMPRESSION_ZLIB` expects RFC 1950 (zlib-wrapped) rather than the raw RFC 1951 DEFLATE
that ZIP method 8 contains, and that we would need to bridge to `zlib` with
`inflateInit2(-MAX_WBITS)`. That is **incorrect on Apple platforms**: ZIPFoundation's own
`Data+Compression.swift` uses `compression_stream_init(&stream, operation,
COMPRESSION_ZLIB)` for exactly this, and its `inflateInit2_(&stream, -MAX_WBITS, ...)`
path is the *non-Apple* fallback for platforms where `Compression` is unavailable. Acting
on the warning would have cost a pointless detour. Recorded here because the lesson
generalises: a confident, specific claim from a reviewer is still a claim to verify.

CRC32 is verified for every entry — ZIPFoundation returns it from `extract` — and a
mismatch fails the import. Encrypted entries and unsupported compression methods are
rejected with specific messages rather than skipped.

### 7.2 Stages

1. **Receive** via `UIDocumentPickerViewController`, the share sheet, or Files
   "Open In".
2. **Check free space** for staging plus destination before writing anything.
3. **Stream-extract** to `Imports/<uuid>/`, applying §7.3 per entry.
4. **Locate the basedir** — the directory containing `game/`. If none, fail with
   *"This doesn't look like a Ren'Py game."*
5. **Detect the engine** from `.rpyc` magic — v1 is Ren'Py 7, v2 is Ren'Py 8. A Ren'Py 7
   game is refused up front rather than being allowed to fail as a black screen later.
6. **Extract a cover** if present (`game/gui/window_icon.png`, `icon.png`).
7. **Atomically move** `Imports/<uuid>/<basedir>` to `Games/<gameId>/`, then write the
   library entry. Order matters: an entry must never name a directory that is not there.

### 7.3 Hardening, and pruning

Rejected outright, each with its own message:

- `..` path traversal, absolute paths, Windows drive paths (`C:\...`), backslash
  separators used as traversal, and any entry whose resolved path escapes the staging root
- symlinks (we never need them, and they are the classic escape)
- encrypted entries
- unsupported compression methods, named explicitly rather than skipped
- multi-disk archives
- duplicate entries after path normalisation — on iOS's case-insensitive filesystem
  `Game/x.png` and `game/X.png` collide, and silently letting the second win is how a
  malicious archive overwrites a validated file
- entry count, total uncompressed size, or single-entry uncompressed size beyond caps
- a compression ratio implausible enough to indicate a zip bomb

**Caps, stated rather than left to implementation:** 100,000 entries, 8 GB total
uncompressed, 4 GB per entry, and a per-entry compression ratio above 1000:1.

**Filename encoding.** If the UTF-8 flag (bit 11) is set, decode UTF-8. If it is not —
common, because Windows packing tools frequently omit it — try UTF-8 anyway (most modern
archives are UTF-8 regardless of the flag), then Shift-JIS/CP932, then CP437. Japanese
visual novels are a large fraction of what this app will ever be pointed at, and a
mojibake asset path becomes a `FileNotFoundError` deep inside a game rather than an
import error the user can act on. Raised by one reviewer; it would not have occurred to
me.

**Pruned during extraction, never written in the first place:** a top-level `lib/`,
a top-level `renpy/`, and `*.exe`, `*.dll`, `*.so`, `*.dylib`, `*.app/`, `*.sh`,
`*.bat`, `*.command`.

**Only at the distribution root, and never inside `game/`.** The first draft would have
pruned any directory named `lib` at any depth, which would silently gut a game that
happens to ship `game/lib/`. Pruning is scoped to the basedir's own top level, and
`game/` is untouchable. A PC distribution ships Windows, Linux and macOS binaries the
phone can never execute — commonly 100–200 MB of dead weight per game. There is no
destructive delete step; a per-import *import complete folder* toggle disables pruning
entirely for the user who wants everything.

Everything not on the denylist is extracted, **including anything unrecognised**. An
allowlist would silently break games that ship assets we did not anticipate.

### 7.4 Failure surfaces

Every failure names its cause and a next action. From §7.3 plus:

| Failure | Message |
|---|---|
| insufficient space | states the shortfall in MB |
| no `game/` directory | "This doesn't look like a Ren'Py game." |
| Ren'Py 7 detected | "This game needs Ren'Py 7, which isn't supported yet." |
| CRC mismatch / truncated | "This archive appears to be damaged." |
| encrypted | "This archive is password-protected." |
| unsafe paths | "This archive contains unsafe file paths." |

A cancelled or failed import removes its staging directory and leaves no library entry.

## 8. `library.json`

Fields per parent spec §6: `id`, `title`, `path`, `coverPath`, `sizeBytes`, `addedAt`,
`lastPlayedAt`, `detectedEngine`, `importedComplete`, `crashCount`.

Written atomically (temp file plus `replaceItemAt`), and **rebuildable by rescanning
`Games/`** if lost or corrupt — the file is an index, never the source of truth. A
corrupt `library.json` triggers a rescan rather than an error.

## 9. Library UI

`LibraryWindow`, SwiftUI, `.normal + 2`, opaque.

- **Grid** of games: cover (or a generated placeholder from the title), title, size.
- **Import button** opening the document picker.
- **Per-game detail**: size, last played, delete, re-import/update, export saves.
- **Empty state** that says how to add a game, because the first run is always empty and
  a blank grid teaches nothing.
- **Import progress**: live, with a cancel button that actually cancels.

### 9.1 Do NOT pause SDL's `CADisplayLink` — it would deadlock the launch

The parent spec §9 says to pause SDL's `CADisplayLink` while the library is shown, so it
does not keep presenting into a stale MetalANGLE context. **Following that would break
the launch path**, and this is the single most valuable finding from the review.

The reasoning, which holds up: SDL drives Ren'Py's frame execution from the
`CADisplayLink` callback. `vnshell.lifecycle.tick()` — the thing that drains the command
spool — runs from `config.periodic_callbacks`, which runs per frame. Pause the display
link and Ren'Py stops executing; the user taps Play, Swift writes the command, and
**nothing ever reads it.** The app would hang with the library up and no error, which is
about the worst failure shape available.

So: M2 does not pause it. The library is opaque, so the engine renders invisibly at
idle — it is the shell project's idle loop, which is cheap. If battery measurement later
shows this matters, the fix is to *throttle* the display link rather than stop it, or to
resume it before writing a command; both are M4 concerns, and both must preserve the
invariant that **the engine keeps ticking whenever a command may be pending.**

### 9.2 Orientation

The container view controller's supported-orientation mask must agree with SDL's, or iOS
raises `UIApplicationInvalidInterfaceOrientation`. The app is landscape-only for now, so
both are landscape. Collapsing to one window (§4) removes the multi-window version of
this problem entirely.

### 9.3 Audio

Returning to the library does not stop the game's audio by itself; SDL keeps playing.
`quitToLibrary` stops music and sound on the Python side before restarting.

## 10. The Swift/Python protocol

### 10.1 A spool directory, not one append-only file

The first draft kept the proven design from the spike: one newline-delimited JSON file
that Swift appends to and Python drains. **It has a data-loss race**, which both
reviewers found independently and which is real in the code as written today —
`FileTransport.receive()` does `read()` then `os.remove()`, so anything Swift appends
between those two calls is deleted unread. A partially-written line is also discarded
permanently, because the JSON parse fails and the loop moves on.

It never bit us because the spike wrote one command per tap, by hand. Under a launch
flow with retries and events in both directions it would.

**Replaced by a spool directory.** One message per file:

```
Commands/<uuid>.json     Swift -> Python
Events/<uuid>.json       Python -> Swift
```

The writer writes `<uuid>.json.tmp` and then renames it to `<uuid>.json`. Rename within a
directory is atomic, so a reader sees a file either not at all or complete — there is no
partial state to parse and no window in which a message can be dropped. The reader
processes each file and deletes it. Ordering is by filename, which carries a monotonic
prefix.

`vnshell.transports.FileTransport` keeps working unchanged for the desktop harness; the
spool is a new `SpoolTransport` alongside it, so M1's verified desktop path is not
disturbed.

### 10.2 Messages

```json
Commands/  {"commandId": "...", "command": "launch", "basedir": "...", "gameId": "..."}
           {"commandId": "...", "command": "quitToLibrary"}

Events/    {"commandId": "...", "event": "launchAccepted"}
           {"commandId": "...", "event": "gameReady",  "gameId": "..."}
           {"commandId": "...", "event": "launchFailed", "reason": "...", "gameId": "..."}
           {"event": "shellReady"}
```

Every event carries the `commandId` it answers, and **Swift discards events whose
`commandId` is not the launch it is currently waiting on.** Without that, an event from
an abandoned launch arrives late and dismisses the library out from under a different
one.

Launch controls are disabled while a launch is pending, so repeated taps cannot enqueue
several launches.

### 10.3 The watchdog

If no `gameReady` arrives within **60 seconds**, Swift shows "This game is taking longer
than usual to start" with *Keep waiting* and *Return to library*. Not an error: a large
game compiling `.rpy` files on first run genuinely can take a while, and treating slow as
failed would make big games unusable. But an unbounded silent wait is not acceptable
either, and today's code has no bound at all.

### 10.4 Python revalidates the basedir

`Documents/` is user-visible and the command spool, though not exposed, is still a file
on disk. Python does not launch whatever path it is handed: it canonicalises the basedir
and requires it to be a direct child of `Documents/Games/`, refusing anything else with
`launchFailed`. Cheap, and it means a malformed or stale command cannot point the engine
at an arbitrary directory.

### 10.5 Crash-loop protection

If a game fails hard enough during `init`, Ren'Py can terminate the process rather than
return control to the shell — the app disappears to the home screen. On the next launch
there is nothing in memory to tell us that happened.

So before writing a launch command, Swift writes a **launch sentinel** naming the
`gameId`, and clears it on `gameReady`. Finding a sentinel at startup means the last
launch of that game killed the app: increment `crashCount`, do not auto-launch anything,
and open the library with an explanation. Without this a game that crashes on boot is
unrecoverable without deleting the app.

## 11. Testing

### 11.1 Swift, headless, in CI

The extractor is the riskiest component and the most testable. It runs on the macOS
runner with no device and no signing.

- **Fixture archives are generated by Python's `zipfile`**, not by our own writer. This
  is the point: a second, independent implementation produces the input, so a shared
  misreading of the format cannot pass unnoticed. Fixtures cover stored and deflated
  entries, nested directories, UTF-8 names, ZIP64, an empty archive, a truncated
  archive, a CRC-corrupted archive, and each §7.3 rejection case.
- **Round-trip assertion**: extract, then compare every file's bytes and the full path
  set against what Python wrote.
- **Every rejection case asserts the specific error**, not merely that an error occurred.
- **`gameId` derivation** gets a table test over real Ren'Py distribution names.

### 11.2 Python

The existing 35-test suite continues to run. New tests cover any `shell/` change,
following the rule already applied on this branch: **a new regression test is run against
the pre-fix code and observed to fail before it is trusted.**

### 11.3 On device

M2's device test is the first one where a real game runs, so it settles the question §2
left open:

1. Import a game from Files.
2. It appears in the library.
3. Launch it; it plays.
4. **Touches outside any overlay control reach the game** — advancing dialogue works.
5. Return to the library; launch a second game; saves from the first are intact and not
   visible to the second.

## 12. Risks

| Risk | Standing |
|---|---|
| Hand-written ZIP reader mis-parses a real archive | Mitigated by CRC32 on every entry and by fixtures generated by an independent implementation. Residual risk is real and accepted; the failure mode is a rejected import, not a corrupted one |
| Ren'Py crops 16:9 games on a 19.5:9 screen | **Open, and possibly serious.** Measured indirectly on 2026-08-25: our UIKit control is centred correctly in a 1280x591 screen while Ren'Py's centred frame is not. If the engine fills to width and overflows height rather than letterboxing, every game loses the top and bottom of its screen — where dialogue boxes live. The diagnostic screen now reports virtual size, physical size and whether the aspect is preserved; the next device run settles it. **This is not an M2 deliverable but it may block M2 being usable**, and it is the first thing to read in the morning |
| Native memory growth per switch (~22 MB on desktop) | Unresolved by design; parent spec §14 decided watch-and-warn. Needs on-device re-measurement with `phys_footprint` before a threshold can be set. Out of M2 |
| Import of a very large archive is killed by Jetsam | Streaming extraction keeps peak memory flat; to be checked with a multi-GB fixture on device |
| Ren'Py 7 games are common in the wild | Detected and refused with a specific message, rather than failing as a black screen |

## 13. Explicitly out of scope for M2

The in-game overlay window and its controls, the magnifier, quick save/load, memory
watch-and-warn, the app icon, and Ren'Py 7 support. All are M3 or M4.

## 14. The four open questions, answered

**1. Hand-written ZIP reader, or vendored ZIPFoundation?** — **Vendor it.** Reversed from
the draft; reasoning in §7.1. Both reviewers said the same thing for the same reason, and
on inspection my two arguments for hand-writing were weaker than they looked: the
consumer-closure API preserves every hardening decision, and an in-repo copy is *more*
reproducible than a fetch, not less.

**2. Separate library window, or one window with swapped content?** — **One window.**
Also reversed from the draft, and from the parent spec. The deciding argument is
`UIDocumentPickerViewController`: presenting a modal from a window that deliberately does
not hold key status is asking for the blank-sheet and dead-dismissal failures. One window
that takes key while the library is up and gives it back afterwards is fewer moving parts
and removes the multi-window orientation problem outright. The reviewers split on this —
one said keep two windows because the spike proved them, one said collapse to one — and
the spike's evidence applies either way: it proved *a* window above SDL works, not that
two do.

**3. Prune by default?** — **Yes, with a visible toggle**, and narrower than the draft
had it: only at the distribution root, never inside `game/`, extended to `.dll`, `.so`,
`.dylib`, `.bat`, `.command`. Both reviewers agreed on pruning and both independently
warned that a blanket `lib/` rule would eventually eat a real game's assets.

**4. Expose `Documents/` via Files?** — **Yes for `Games/` and `Saves/`, no for
everything else.** The draft exposed the index and the IPC files too. Both reviewers
objected; moving them to `Library/Application Support/VNPlayer/` keeps the user's ability
to back up saves and hand-remove a broken game, without putting the control plane where a
curious tap can break it.

## 15. What the review changed

Two independent reviews (Codex and Antigravity/Gemini), 2026-08-25. Recorded because
several findings reversed decisions in the draft, and because one did not survive
checking.

**Adopted — would have been bugs:**

| Finding | Both? | Why it mattered |
|---|---|---|
| Pausing `CADisplayLink` deadlocks the launch | one | The command spool is drained per frame. Pausing the display link stops Ren'Py, so the launch command is never read and the app hangs silently with the library up. The parent spec explicitly called for the pause |
| The mailbox loses commands | both | `read()` then `os.remove()` — a real race in today's code, plus permanent loss of any partially-written line |
| Hide the library on `gameReady`, not on write | both | A game that fails to boot would otherwise strand the user with no way back |
| `moveItem` fails when the destination exists | both | Re-import and update would fail on the happy path |
| Move the index and IPC out of `Documents/` | both | Files-app exposure would show the user the control plane |
| Vendor ZIPFoundation | both | §7.1 |
| One window, not two | one | Modal presentation from a non-key window |
| Shift-JIS filenames | one | Japanese VNs are a large fraction of the target corpus; mojibake becomes a `FileNotFoundError` deep in a game |
| `Documents/Inbox/` copies double storage | one | "Open in..." copies the archive in; not deleting it can fill the disk |
| Security-scoped URLs need `startAccessingSecurityScopedResource` | one | Reads from iCloud Drive silently return nothing without it |
| Crash-loop sentinel | one | A game that kills the process on boot is otherwise unrecoverable |
| Python must revalidate the basedir | one | Do not launch an arbitrary path handed in by a file |
| Per-game manifest so the index is rebuildable *with* metadata | one | Rescanning `Games/` alone loses title, cover, crashCount |
| Deferred deletion via `Trash/` | one | Avoids half-deleted games if the app is killed mid-delete |
| Narrow the prune rules | both | A blanket `lib/` rule would eventually eat a real game's assets |
| Audio keeps playing on return to library | one | Needs an explicit stop |

**Checked and rejected:**

- *"`COMPRESSION_ZLIB` expects RFC 1950, so you must bridge to zlib with
  `inflateInit2(-MAX_WBITS)`."* Incorrect on Apple platforms. ZIPFoundation uses
  `COMPRESSION_ZLIB` for exactly this case, and its `inflateInit2` path is the non-Apple
  fallback. Verified by reading the library rather than by reasoning about the docs.

**Already handled, raised anyway:**

- *"Games override `config.save_directory` in their scripts, defeating save isolation."*
  A real hazard, and the reason `path_to_saves` was chosen over `config.save_directory`
  in the first place. The parent spec records it as verified on the desktop harness: two
  sentinel games declaring an *identical* `config.save_directory` still landed in
  separate, correctly isolated save directories.

**Not adopted for M2:**

- Full `commandId` sequencing with turn-taking beyond what §10.2 specifies. The spool's
  atomic-rename semantics plus `commandId` matching cover M2's traffic, which is one
  command at a time. Revisit if M3's overlay makes the channel chatty.
