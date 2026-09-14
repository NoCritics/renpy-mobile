# Where this project is

**Read this first.** Last updated 2026-09-14.

## In one paragraph

VNPlayer is a free, open-source iOS player for Ren'Py 8 visual novels. **M4 (save export
and import) is merged to `main`** along with everything before it. M2 (library and import)
and M3 (the in-game overlay) are device-confirmed. **M4 has had a first device pass**:
adding a game, backing up, and the control strip all work. The rest of M4's checklist
below has not been run.

**v0.2.0 is tagged** and is what `releases/latest` serves. Until 2026-09-14 the only
release was v0.1.0 — the Milestone B diagnostic screen — and a fresh install from the
release page on a new machine produced exactly that. The README's note steering readers
to Actions had been correct for three weeks and nobody followed it, because nobody
reads a note when there is a Releases tab. Lesson recorded: **a green `main` that is not
tagged does not exist for anyone but the developer.**

## The build to install

**`v0.2.0`** from <https://github.com/NoCritics/renpy-mobile/releases/latest>.
Sideloadly as usual — `docs/INSTALL.md`. Release builds now stamp
`CFBundleShortVersionString` from the tag (`patch_info_plist.sh`, `VNPLAYER_VERSION`);
every build before this reported renios's template `1.0`, and wrote that into backup
manifests as `appVersion`.

Between releases, the newest green run on `main` is the equivalent — Actions, artifact
`VNPlayer-ipa`, unzip.

That size is worth knowing: a `main` build that comes back around **27.5 MB** is stock
Ren'Py with none of our Swift compiled in. Three workflow steps used to be gated to
feature branches only, so `main` and release tags produced an app-shaped file containing
none of the app. Fixed, but the size is the tell if it ever regresses.

## Landed after the merge, from device use

- **The file picker never opened.** Seven presentation modifiers were stacked on one
  view, including two `.fileImporter`s — `.fileImporter` is built on `.sheet`, so only
  the later one could present and "Add game" silently did nothing. Now exactly one
  modifier of each kind. This had been flagged in review as an iOS 15 hazard and
  deliberately parked; parking it was wrong.
- **`print` does not reach the device log** for a sideloaded app — it writes to stdout,
  which the log never sees. Every `[vnspike]` diagnostic is `NSLog` now. The lines that
  were supposed to explain a picker failure had never once appeared.
- **A stranded picker flag needed an app restart.** `guard !showPicker else { return }`
  turned any transient failure permanent, because nothing but SwiftUI's binding ever
  cleared the flag. It now heals on the next tap.
- **The library screen was littering `Documents`.** It is itself a Ren'Py project, so it
  inherits `autosave_slots = 10` and autosaved itself into the folder the reader browses,
  mixed in with her real saves and distinguishable only by being smaller. Its writes go
  to Application Support now. **Deliberately did NOT set `config.has_autosave = False`**:
  `config` is process-global and nothing in the restart path was found to reset it, so a
  leak into a loaded game would silently disable autosaves on a real playthrough.
- **Backups live in `Saves/<gameId>/backup/`**, and a whole-library backup in
  `Saves/backup/`. Safe inside a Ren'Py save directory: `savelocation.py:175` skips
  anything not ending in `-LT1.save`. Filenames gained the time, because kept files make
  a same-day collision one backup destroying another.
- **Size caps raised to 64 GiB total / 16 GiB per entry.** Real games run 4–8 GB and keep
  assets in one or two `.rpa` files, so the old 4 GiB per-entry cap rejected them
  outright. The bomb defences (`maxCompressionRatio`, `maxEntries`) are untouched, and
  free space — checked against the volume before any write — is the real limit.

## `persistent` travels with saves (landed, `695f849` + `d4ee3da`)

Without it, reinstall-and-restore returned her save slots and silently dropped gallery
unlocks, seen-text (so skip-unread stopped working) and preferences. Export includes the
file when the save directory has one; import copies it only when the destination has
none, and never overwrites an existing one — checked at plan time, re-checked at write
time, and written `.withoutOverwriting`. Both confirmations name it in words. It is
counted separately from the slots, so "3 saves" still means three slots. Ren'Py's own
union-merge (`persistent.py:364`) is engine-side Python and cannot be called from Swift;
merging is a later refinement, not something to fake. Not yet exercised on a device.

## Ren'Py 7 — discussed, undecided

Refused today by design. Facts established on 2026-08-26, verified against the vendored
8.5.3 SDK unless marked otherwise:

- **Ren'Py 8 already carries the compatibility layer.** `renpy/python.py:1198` retries a
  `SyntaxError` through `renpy/compat/fixes.py` (`print` statements, `raise X, y`,
  octals, `<>`, backtick repr). Syntax only — `has_key`, `iteritems`, integer division
  and `map`/`filter` iterators fail at runtime, the first two loudly, the rest silently.
- **A 7 `.rpyc` is rejected** (`script.py:957`, `script_version` 5003000) and recompiled
  from the adjacent `.rpy` (`script.py:1051-1063`). **Scripts inside an `.rpa` have no
  fallback** (`script.py:992`) — a source-stripped 7 game cannot run on an 8 engine by
  any route.
- **Ren'Py's default build ships `.rpy` source, loose.** `00build.rpy:233`'s catch-all is
  `("**", "all")` and the template `options.rpy` has its archive rules commented out.
  Stripping is something a developer adds. How many do is unmeasured.
- **The detector has a gap.** The `py2-` prefix only appeared at 7.5; earlier 64-bit
  builds use plain `lib/windows-x86_64`, hit neither condition in
  `EngineDetection.swift`, and fall through to `.unknown` — so they import today, and
  fail later, while we believe they are refused.
- **Ren'Py 7.8.7 (March 2025) is the final 7.x release and ships `renpy-7.8.7-renios.zip`
  and `renpy-7.8.7-web.zip`** — <https://renpy.org/latest-7.html>. Not verified in
  this repo. Two external models both assumed py2 iOS prebuilts were dead; they are not.
- **Two CPythons in one binary** collide on exported symbols and iOS forbids a second
  process. A *second app* built from renios 7.8.7 does not have that problem, and reads
  7 bytecode natively — archived scripts included. Costs a free-Apple-ID slot, a Python 2
  `shell/`, and whether 2025 prebuilts still link on current Xcode, which is a CI
  experiment away.
- A WKWebView running the 7.8.7 web runtime is the other real option; the memory ceiling
  (32-bit wasm) against 4–8 GB games and saves living in evictable browser storage are the
  costs.

Full comparison of the two external consultations is in the 2026-08-26 session; the
contradictions between them were settled by reading the source, in the 8 engine's favour
on every point but the renios one.

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

## Device checklist for M4 — partly checked

Adding a game, per-game export, whole-library backup and the control strip have been used
on the phone. The rest of this list has not, and `persistent` has not been exercised at
all. Everything unchecked still needs someone with an iPhone to actually try it. Run these in order — each one only assumes the ones
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

- **The unchecked items above**, and `persistent` end to end.
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
- Ren'Py 7 support: refused with a message, by design — see the section above for what
  is now known, and the detector gap that means the refusal is incomplete.
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
