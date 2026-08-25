# Where this project is

**Read this first.** Last updated 2026-08-25.

## In one paragraph

VNPlayer is a free, open-source iOS player for Ren'Py 8 visual novels. Milestone B is
merged and released as **v0.1.0**. **M2 (library and import) is done and device-confirmed**:
a 1.2 GB commercial game imports from a `.zip`, launches, and is playable by touch on an
iPhone 13 Pro Max. **M3 (in-game overlay) is implemented and green in CI but has never run
on a device.** Everything lives on `milestone-c/library-and-import`; `main` is still at the
Milestone B merge.

## The build to install

**Run `32840376120`**, branch `milestone-c/library-and-import`, artifact `VNPlayer-ipa`
(28,725,459 bytes). Sideloadly as usual — `docs/INSTALL.md`.

## What to check, in order

M3 is untested on hardware, so this is the first pass over it.

1. **Launch a game.** On the *first* game after installing, the overlay opens by itself
   with a one-line hint — that is deliberate, so the handle is discoverable.
2. **The handle.** A narrow tab on the right edge, vertically centred. Tapping it opens
   the control strip. It should not interfere with playing.
3. **Each control**: Roll back, Quick save, Quick load, Skip, Magnify, Back to library,
   Close. Greyed-out controls are the engine saying it will not accept them right now —
   that is the `engineState` event working, not a bug.
4. **Refusal messages.** If a control does nothing, the strip should say why in a
   sentence ("there is nothing to roll back to"). **A control that silently does nothing
   is the finding** — quote what you saw.
5. **Magnifier**: pinch/step the zoom, drag to pan, Done to exit. Two things to watch —
   does the game still respond correctly *after* exiting, and does panning ever scroll the
   dialogue backwards (it must not; that would mean touches are reaching SDL).
6. **Back to library**, then launch again. Saves must survive.

Log capture: `bash scripts/ios/device_log.sh 30`. Add `-a` to greps if it reports
"binary file matches" — game output can contain non-UTF-8 bytes.

## Settled by measurement

- **Games are not cropped** on a 19.5:9 screen. A real game's bottom menu bar and centred
  choices are fully visible. The earlier clipping was the old diagnostic screen's own
  frame being taller than the display.
- **Memory: ~8 MB per game switch**, against the desktop harness's 22 MB. With ~2.6 GB of
  headroom that is on the order of 300 switches per session. **No design change needed**,
  and the parent spec's rejection of a hard cap now rests on evidence. Warning threshold
  is 500 MB of remaining headroom.
- **Touch passthrough works** with a real game underneath.

## Four findings worth carrying forward

**Never pause SDL's `CADisplayLink`.** The parent spec said to, while the library is up.
SDL drives Ren'Py's frame execution from it and the command spool is drained per frame, so
pausing means commands are never read — the app hangs with no error at all.

**`UIHostingController`'s view answers every hit test itself.** A SwiftUI `Button` is not a
separate `UIView`, so a passthrough window cannot tell "over a control" from "over empty
space" by identity. Any control that must be tappable *while touches pass through* has to
be a real UIKit view. This cost a round-trip and would have cost another in M3.

**The `.rpyc` magic does not distinguish Ren'Py 7 from 8.** Both write `RENPY RPC2`. Real
signals are `renpy/vc_version.py` and `lib/py3-` vs `lib/py2-`.

**Exception base classes are not what you would guess.** `RollbackException` and
`UnfreezeException` derive from `BaseException`; `UtterRestartException` derives from
`Exception`. So a blanket `except Exception` around command dispatch leaves rollback
working and silently breaks quit-to-library. There is deliberately no such wrapper.

## Decisions taken without you

1. **Vendored ZIPFoundation** rather than hand-writing a ZIP reader — reversing my own
   spec after both reviewers disagreed with it. `third_party/PROVENANCE.md` has the pin.
2. **Deployment target 13.0 → 15.0.** A product decision: at an iOS 13 floor SwiftUI has
   no `@StateObject`, `LazyVGrid` or `.fileImporter`. Reverting costs a UI rewrite.
3. **`Documents/` exposed to Files** — only `Games/` and `Saves/`; the index and IPC files
   live in `Library/Application Support/VNPlayer`.
4. **The M3 summon gesture is a handle, not an edge swipe** — you confirmed this one.

## Still open

- M3 has no device testing at all yet.
- **Cover art**, re-import/update, export saves, rename, settings: not built.
- Ren'Py 7 support: refused with a message, by design.
- `device_log.sh` should pass `-a` to grep; game output can be non-UTF-8 and the summary
  currently warns "binary file matches".

## Layout

```
shell/            the engine shell that ships inside the app (Python)
  vnshell/        lifecycle, purge, transports, platform, mailbox
  vnplayer_hook.rpe.py   loaded by Ren'Py for EVERY game; keeps the command channel alive
swift/VNPlayerCore/    pure logic + vendored ZIPFoundation, tested headlessly (87 tests)
spike/            the iOS app layer (windows, SwiftUI, overlay) and its XcodeGen project
scripts/ios/      fetch, generate, overlay, patch, package, device log
tests/            Python suite (60 tests), including the protocol contract fixtures
docs/superpowers/specs/   M2 and M3 designs, both consultation-reviewed
harness/          desktop cycling rig
```
