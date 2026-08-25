# Where this project is

**Read this first.** Last updated 2026-08-25.

## In one paragraph

VNPlayer is a free, open-source iOS player for Ren'Py 8 visual novels. Milestone B is
merged and released as **v0.1.0**. **M2 (library and import) is device-confirmed.**
**M3 (in-game overlay)** — roll back, skip, the control strip, and the three icons that
open the game's own Save, Load and Preferences pages — is device-confirmed except for
three small checks noted below that were never closed out. **M4 (save export and import)
is code-complete and green in CI, and has not touched a device at all.** Everything lives
on `milestone-d/save-transfer`; `main` is still at the Milestone B merge.

## The build to install

**Run `32892531756`**, branch `main`, artifact `VNPlayer-ipa` (28,810,491 bytes).
Sideloadly as usual — `docs/INSTALL.md`.

That size is worth knowing: a `main` build that comes back around **27.5 MB** is stock
Ren'Py with none of our Swift compiled in. Three workflow steps used to be gated to
feature branches only, so `main` and release tags produced an app-shaped file containing
none of the app. Fixed, but the size is the tell if it ever regresses.

## What M4 added

Each game can now export its own saves to a `.zip` file that a PC can open directly — no
special tool needed on the desktop side. There's also a whole-library backup, which does
the same thing for every game at once. Both can be imported back: either that `.zip`, or a
bare Ren'Py `.save` file with nothing else around it. Before anything is actually imported
or exported, a confirmation screen previews exactly what is about to happen — which saves,
how many, for which game — so nothing moves without you seeing it first. If a file being
imported can't say for itself which game it belongs to (a bare `.save`, or a hand-made
`.zip` with no VNPlayer manifest inside it), the app asks you to pick from your installed
games instead of guessing.

The in-game control strip changed too: quick save and quick load are gone from it, and
export and import take their place.

## Device checklist for M4 — nothing below has been checked on a phone yet

This is code that has only ever run in GitHub's CI, never on real hardware, never against
a real file system, real iCloud, or a real second device. Everything here needs someone
with an iPhone to actually try it. Run these in order — each one only assumes the ones
before it.

1. **Export a game that already has real saves on it**, using two different destinations
   in turn: AirDrop to a PC, and Save to Files (into iCloud Drive). Wait for each transfer
   to fully finish on the receiving end before judging it.
   - *Baseline:* unzip the AirDropped file into the folder named inside its own
     `WHERE-TO-PUT-THESE.txt`. The desktop game should then list those same save slots.
   - *Note:* this was flagged in review and fixed before merge. The app used to delete its
     own temporary copy of the export the moment you dismiss the share sheet — not when
     the transfer had actually finished — and AirDrop and iCloud both keep copying in the
     background after that sheet closes, so a too-early delete could have truncated the
     file. It no longer deletes on dismiss; a startup sweep removes the temporary copy on
     the next launch instead. Still worth checking on device: both destinations should
     arrive whole, and the temporary file should be gone after relaunching the app once
     the transfer is well clear.
2. **Export a game that has never been launched**, so it has no saves at all. This should
   be refused with a plain sentence explaining why. It must not hand you an empty `.zip`
   file as if that were a normal export — an empty file that *looks* successful is the
   failure mode to watch for.
3. **On a computer, by hand, make a `.zip`** from a copy of a real Ren'Py desktop save
   folder — not one exported from the phone. Send it to the phone and use Import saves.
   The save slots from that `.zip` should appear in the phone's library, against the right
   game. Because this file did not come from VNPlayer, a one-time warning should appear
   saying so. Check that it shows exactly once for this import, not again on every screen
   after.
4. **Using that same import from check 3:** compare the numbers shown on the confirmation
   screen before you tapped Import (how many saves, which slots) against the sentence
   shown afterward describing what happened. They should describe the same thing.
5. **With two or more games installed, import a bare `.save` file** — not a `.zip`, just
   the single file Ren'Py writes directly into its own save folder. The app has no way to
   tell which game that file belongs to, so it should ask you to choose from your
   installed games, then show the ordinary import confirmation for the game you picked.
   - *Extra care needed here:* the "which game" chooser and the import confirmation are
     two separate popups controlled by the same piece of code. Watch this handoff
     closely — the chooser should fully close before the confirmation appears, the
     confirmation should name the game you actually picked, and the two should never
     appear stacked on top of each other or flash into one another.
6. **Back up the whole library** (every game in one go). Then remove one game from the
   library completely, add it back as if it were new, and restore from that backup. That
   game's saves should reappear.
7. **Import that same whole-library backup a second time**, without changing anything
   first. It should tell you it's already here and add nothing new — no duplicated save
   slots, and no error.
8. **While a game is actually running**, use Import saves from the control strip along the
   edge of the screen — not from the library list. It should leave the running game and
   return you to the library first, then open the file picker. It must not try to import
   while a game is still on screen underneath.
9. **Revisit any import above that used a file stored in iCloud** rather than fully
   downloaded onto the phone (this can apply to checks 3, 5, 6, or 7). Deliberately pause
   for a while on the confirmation screen before tapping Import — long enough that iOS
   could reasonably decide it's done handing the file over. If that pause breaks the
   import, the failure should look like a plain message — something like "That file could
   not be opened" — never a crash. Separately, note whether a `.save` file that didn't
   arrive through the Files app in the first place (for example, AirDropped straight to the
   phone rather than saved into Files first) even shows up in the picker at all. Some
   sources won't offer it the file type the picker is asking for — that's expected
   behaviour to note, not a bug to chase.

None of these nine checks is about anything your sister would normally do by accident —
export and import are both deliberate actions behind their own buttons, with a
confirmation in front of each. But checks 3 and 5 are exactly what would happen if she,
or you, ever had to rebuild her phone from an old backup made on a PC, so they're worth
taking seriously rather than treating as edge cases.

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

- **All nine checks above.** M4 has never run outside CI.
- **Whether a Sideloadly re-sign at the 7-day expiry preserves `Documents/Saves/`, or wipes
  it, is still unanswered.** It needs a real expiry cycle to test: re-sign, then look. M4's
  export/backup feature now gives you a way to protect saves against that regardless of the
  answer, but the underlying fact about what Sideloadly does is still not known.
- **Three M3 device checks were never closed out** and remain open in the background:
  whether the Add game picker's fix is proven (it was an intermittent bug, so one clean run
  doesn't prove it — it needs repeated use across separate app launches without a bad one);
  quitting to the library from inside a game's own menu page; and whether the magnifier
  leaves the game in a good state, visually and technically, after you back out of it.
- **A handful of small gaps found during M4's review, none of them dangerous:**
  if an import fails partway through a multi-save batch, the saves that already copied
  before the failure stay copied — it does not undo them. Exporting the same game twice on
  the same calendar day can produce a filename collision, though the export flow's own
  modal presentation makes it hard to trigger by accident. A multi-game backup's
  confirmation message reads awkwardly, as several game-by-game questions stitched
  together, rather than one clean sentence. Importing a foreign save (one with no
  VNPlayer manifest) never names its game in the "done" summary unless it went through the
  "which game" chooser, which does name it. And an archive whose manifest fails to
  describe one of its own save groups — hand-edited or corrupted — silently drops that
  group: nothing wrong gets written, but the group is neither imported nor mentioned,
  which could read as your saves vanishing when they were never touched.
- **Cover art**, re-import/update of a game itself, rename, and app settings: still not
  built.
- Ren'Py 7 support: refused with a message, by design.
- `device_log.sh` should pass `-a` to grep; game output can be non-UTF-8 and the summary
  currently warns "binary file matches".

## Layout

```
shell/            the engine shell that ships inside the app (Python)
  vnshell/        lifecycle, purge, transports, platform, mailbox
  vnplayer_hook.rpe.py   loaded by Ren'Py for EVERY game; keeps the command channel alive
swift/VNPlayerCore/    pure logic + vendored ZIPFoundation, tested headlessly (154 tests)
spike/            the iOS app layer (windows, SwiftUI, overlay) and its XcodeGen project
scripts/ios/      fetch, generate, overlay, patch, package, device log
tests/            Python suite (79 tests), including the protocol contract fixtures
docs/superpowers/specs/   M2, M3 and M4 designs, all consultation-reviewed
harness/          desktop cycling rig
```
