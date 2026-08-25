# Where this project is

**Read this first.** Last updated 2026-08-25.

## In one paragraph

VNPlayer is a free, open-source iOS player for Ren'Py 8 visual novels. Milestone B is
merged and released as **v0.1.0**. **M2 (library and import) is done and device-confirmed**:
a 1.2 GB commercial game imports from a `.zip`, launches, and is playable by touch on an
iPhone 13 Pro Max. **M3 (in-game overlay) is on a device and working** — roll back, skip and the
control strip are confirmed; the three icons that open the game's own Save, Load and
Preferences pages are built and green in CI but untested on hardware. Everything lives on `milestone-c/library-and-import`; `main` is still at the
Milestone B merge.

## The build to install

**Run `32852419754`**, branch `milestone-c/library-and-import`, artifact `VNPlayer-ipa`
(28,733,222 bytes). Sideloadly as usual — `docs/INSTALL.md`.

## What to check, in order

Confirmed on device: roll back works, skip works, the strip looks right. The
`renpy.exports` bugs are closed. **What has never run on hardware is the three new icons
that open the game's own menu pages.**

1. **The strip now has nine icons in three groups**, separated by hairlines: roll back,
   quick save, quick load, skip ┊ save, load, settings ┊ magnify, library. It is about
   396pt tall against 428pt of landscape screen — if it feels cramped, quick load is the
   one to drop, since the Load page covers it.
2. **Save, Load and Settings open the game's OWN pages** — every slot with its
   thumbnails, and the game's real preferences. Not ours.
3. **Tapping a second one while a page is already open switches pages**, and a single
   dismissal returns to the game. If it takes two dismissals, the in-menu branch is not
   firing and it is stacking contexts.
4. **On a menu page, roll back and skip go grey** (the new `inMenu` state), and quick
   save is already greyed there by `canSave`.
5. **Library from inside a menu page.** `quitToLibrary` raises through the nested menu
   context. `call_in_new_context` pops in a `finally`, so it should unwind clean — but
   that is reasoning, not evidence, and this is the check that turns it into evidence.
6. **Preferences at a game's title screen** should work (Ren'Py allows it), and **Save
   there should refuse in words** — "you cannot save from the main menu".
7. **Magnifier**: zoom, pan, Done. Watch whether the game still responds correctly after
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

- The three menu icons have not been on a device; items 1-6 above are their first pass.
- Whether the magnifier leaves SDL in a good state after exiting.
- **Cover art**, re-import/update, rename, app settings: not built.
- **Export saves** deferred, by your call. Saves already sit in `Documents/Saves/<gameId>/`
  and are visible in the Files app, so the manual route works today. The open question
  that decides its urgency: **does a Sideloadly re-sign at the 7-day expiry preserve the
  Data container, or wipe it?** Worth answering on the next expiry cycle.
- Ren'Py 7 support: refused with a message, by design.
- `device_log.sh` should pass `-a` to grep; game output can be non-UTF-8 and the summary
  currently warns "binary file matches".

## Layout

```
shell/            the engine shell that ships inside the app (Python)
  vnshell/        lifecycle, purge, transports, platform, mailbox
  vnplayer_hook.rpe.py   loaded by Ren'Py for EVERY game; keeps the command channel alive
swift/VNPlayerCore/    pure logic + vendored ZIPFoundation, tested headlessly (90 tests)
spike/            the iOS app layer (windows, SwiftUI, overlay) and its XcodeGen project
scripts/ios/      fetch, generate, overlay, patch, package, device log
tests/            Python suite (76 tests), including the protocol contract fixtures
docs/superpowers/specs/   M2 and M3 designs, both consultation-reviewed
harness/          desktop cycling rig
```
