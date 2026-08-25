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

**Run `32849904189`**, branch `milestone-c/library-and-import`, artifact `VNPlayer-ipa`
(28,725,821 bytes). Sideloadly as usual — `docs/INSTALL.md`.

## What to check, in order

M3's first device pass found two bugs (both fixed, below). This build has the redesigned
controls and has NOT been tested on hardware.

1. **Launch a game.** A column of icons should sit on the right edge: roll back, quick
   save, quick load, skip, magnify, back to library. It fades to a quarter opacity after
   four seconds and wakes when touched.
2. **Roll back and Quick save should now be ENABLED** where the engine allows them. They
   were permanently greyed before — that was the `renpy.exports` bug, not the engine
   refusing.
3. **Skip should no longer report an AttributeError.**
4. **Roll back and Quick load actually work.** Both were previously guaranteed to throw
   uncaught into Ren'Py's frame loop; neither had been tapped yet.
5. **Refusal messages** appear as a caption beside the strip. A control that does nothing
   and says nothing is the finding.
6. **Magnifier**: zoom, pan, Done. Watch whether the game still responds correctly after
   exiting, and whether panning ever scrolls dialogue backwards (it must not).

## The bug worth remembering

**`renpy` inside a `.rpy` file is `renpy.exports`, not the `renpy` package.**
`renpy/defaultstore.py:481` does `globals()["renpy"] = renpy.exports`. So every example in
Ren'Py's documentation writes `renpy.save(...)`, and the same line fails from a plain
Python module: `import renpy` yields the package, which has `config`, `game` and
`loadsave` but none of `save`, `load`, `rollback`, `can_rollback`, `restart_interaction`
or `music`.

It produced two symptoms that looked unrelated — skip working while reporting
AttributeError, and Roll back plus Quick save permanently greyed — and would have thrown
uncaught from rollback and quickLoad. All call sites now go through `lifecycle._api()`.
`tests/test_renpy_api.py` guards it against the real SDK export list, because a mocked
`renpy` cannot: the first version had passing tests whose fake was built to match the
same wrong assumption.

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
be a real UIKit view. This is why the control strip is `OverlayControlStrip` in UIKit and
not SwiftUI: it is on screen permanently, so touches must pass around it permanently.
SwiftUI is used only for the magnifier, where the window absorbs everything anyway.

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
4. **The M3 controls are a permanent right-edge icon strip** that dims rather than hides
   — your call, and it removed the summon-gesture problem entirely.

## Still open

- The redesigned strip has not been on a device yet; items 1-6 above are its first pass.
- Whether the magnifier leaves SDL in a good state after exiting.
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
