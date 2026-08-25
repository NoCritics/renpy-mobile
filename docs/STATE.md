# Where this project is

**Read this first.** Last updated 2026-08-25, after an overnight M2 session.

## In one paragraph

VNPlayer is a free, open-source iOS player for Ren'Py 8 visual novels. Milestone B is
done, merged, and released as **v0.1.0** with an unsigned `.ipa`. Milestone C's first
half — the library and importer — is built and green on branch
`milestone-c/library-and-import`, **not merged**. `main` is untouched at the Milestone B
merge.

## The build to install

**Run `32796474638`**, branch `milestone-c/library-and-import`.
Artifact `VNPlayer-ipa`, 28,690,330 bytes. Install with Sideloadly as usual
(`docs/INSTALL.md`).

This is the first build that is meant to *do* something rather than prove something.

## What to check on the device, in order

1. **A library appears** — dark screen, "VNPlayer" heading, "Add game" button, and an
   empty state explaining where games come from. If instead you see the old diagnostic
   text with no library over it, the window did not install: look for
   `[vnplayer] overlay ...` in the log.
2. **Import a game.** Tap Add game, pick a Ren'Py 8 `.zip`. Progress should run, then the
   game appears as a tile. If it refuses, **the message is the finding** — every
   rejection has its own wording, so quote it verbatim.
3. **Launch it.** Tap the tile. The library shows "Starting …", then hides itself and the
   game should be there.
4. **Does the game respond to taps?** This is the one thing the spike could not test, and
   it is the highest-value observation in the list. The passthrough hit-test is written
   but has never had a real game underneath it.
5. **Read the top of the old diagnostic screen if you can still reach it** — it now
   reports `virtual:`, `physical:` and `aspect preserved:`. See "Open questions" below.

Capture the log with `bash scripts/ios/device_log.sh 30` — the summary no longer
truncates, and prints `[N readable, M undecodable, T total]` so you can see what it hid.

## What was done overnight

- **The sandbox denials are fixed.** `path_to_saves` and `path_to_logdir` now resolve to
  the app's Data container via a new `vnshell.platform`, which detects iOS from
  `RENPY_PLATFORM` — the same variable Ren'Py's own `renpy.ios` uses. Off iOS every
  function returns its fallback unchanged, so the desktop behaviour Milestone A verified
  over 200 switches is untouched.
- **An M2 spec**, reviewed by Codex and Antigravity. The review reversed three of my
  decisions and caught a design bug that was already written into the parent spec —
  see below.
- **`VNPlayerCore`**: extractor, hardening, library index, spool IPC, engine detection.
  67 Swift tests, headless, running on the CI macOS runner in about a second.
- **The library UI**, one window above SDL, with import, launch, and a launch handshake.
- **The per-game command channel** — the thing that made M2 possible at all.

## Three findings worth carrying forward

**Pausing SDL's `CADisplayLink` would have deadlocked the launch.** The parent spec §9
says to pause it while the library is shown. SDL drives Ren'Py's frame execution from
that callback, and the command spool is drained from a per-frame callback — so the launch
command would never be read, and the app would hang with the library up and no error at
all. It is not paused, and the invariant is now written down.

**The `.rpyc` magic does not distinguish Ren'Py 7 from 8.** Both specs said it did. Both
versions write `RENPY RPC2`. Implementing it as specified would have classified every
game as Ren'Py 8 and let Ren'Py 7 games through to fail as the black screen the check
exists to prevent. Real signals are `renpy/vc_version.py` and `lib/py3-` vs `lib/py2-`.

**The command mailbox loses messages.** `FileTransport.receive()` reads then deletes, so
anything written in between is destroyed unread. Replaced with a spool directory for the
native bridge; `FileTransport` is unchanged and still serves the desktop harness.

## Decisions taken without you, flagged for confirmation

1. **Vendored ZIPFoundation** (MIT, 21 files, in-repo) instead of hand-writing a ZIP
   reader, reversing my own spec. Both reviewers said so independently and both my
   arguments failed on inspection. `third_party/PROVENANCE.md` records the pin.
2. **Deployment target raised 13.0 → 15.0.** A product decision, not a technical one: at
   an iOS 13 floor SwiftUI has no `@StateObject`, `LazyVGrid`, or `.fileImporter`. 13.0
   was inherited from renios, never chosen. Reverting costs a UI rewrite, nothing deeper.
3. **`Documents/` is exposed to the Files app** — only `Games/` and `Saves/`. The index
   and IPC files moved to `Library/Application Support/VNPlayer` so a curious tap cannot
   break the control plane.
4. **The Milestone B rule "the `shell/` layer ships unchanged" is lifted for M2.** Its
   purpose was to force platform problems to be reported rather than patched around, and
   it worked — the `path_to_saves` defect was reported. M2 is the milestone that acts on
   those reports.

## Open questions

- **Does Ren'Py crop 16:9 games on a 19.5:9 screen?** Measured indirectly: our UIKit
  control centres correctly in a 1280×591 screen while Ren'Py's centred frame does not.
  If the engine fills to width and overflows height rather than letterboxing, every game
  loses the top and bottom of its screen — where dialogue boxes live. The diagnostic
  screen now reports the numbers. **This is the most important thing to read in the
  morning**, because it could make M2 unusable regardless of how well import works.
- **Do touches outside the overlay reach the game?** Never tested with a real game
  underneath. Step 4 above.
- **Native memory growth**, ~22 MB per switch on desktop, still unmeasured on device.
  Out of M2 by design.

## Not done in M2

Cover art extraction, re-import/update, export saves, rename, settings, and the in-game
overlay (M3). The library has no way back from a running game yet except relaunching the
app — `quitToLibrary` is implemented on both sides but has no button, because M3 owns the
in-game overlay that would carry it.

## Layout

```
shell/            the engine shell that ships inside the app (Python)
  vnshell/        lifecycle, purge, transports, platform
  vnplayer_hook.rpe.py   loaded by Ren'Py for EVERY game; keeps the command channel alive
swift/VNPlayerCore/    pure logic + vendored ZIPFoundation, tested headlessly
spike/            the iOS app layer (windows, SwiftUI) and its XcodeGen project
scripts/ios/      fetch, generate, overlay, patch, package, device log
docs/             IOS-BUILD.md (measured record), INSTALL.md (for the reader)
harness/          desktop cycling rig
```
