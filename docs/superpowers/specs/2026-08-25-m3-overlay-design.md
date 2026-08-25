# M3 — In-game overlay: design

**Status:** draft for review
**Date:** 2026-08-25
**Parent spec:** [`2026-08-24-renpy-ios-player-design.md`](2026-08-24-renpy-ios-player-design.md) §9
**Depends on:** M2 (library and import), device-confirmed 2026-08-25

---

## 1. What M3 delivers

M2 ends with a commercial Ren'Py game running on the phone, playable by touch, with a
44-point button in one corner to get back to the library. That button is a placeholder in
two ways: it permanently occupies a corner of every game, and it is the only thing the
player can do without going through the game's own UI.

M3 replaces it with a real overlay:

1. A **summon gesture** that costs the game no screen area at all.
2. **Controls**: quick save, quick load, rollback, skip toggle, hide UI, quit to library.
3. A **magnifier**, for games whose text is unreadably small on a phone.
4. **Memory watch-and-warn**, if the on-device measurement says it is needed.

## 2. What is already proven

Device-measured, 2026-08-25, on an iPhone 13 Pro Max running iOS 26.6.

| Fact | How it is known |
|---|---|
| A second `UIWindow` above SDL renders, and SwiftUI hosts inside it | Library UI on device |
| Touches reach a real game through the passthrough window | Big Bad Dogs menus, choices and dialogue all respond |
| A UIKit control in that window is tappable while the rest passes through | The corner button works; the game works around it |
| Swift → Python commands arrive and are acted on | `launch` switches games |
| Python → Swift events arrive | `launchAccepted` / `gameReady` / `shellReady` drive the UI |
| The engine keeps running while the library is up | The launch handshake completes from the library |
| Games are **not** cropped on a 19.5:9 screen | A real game's bottom menu bar and centred choices are fully visible |

That last row retires the risk the M2 spec called "possibly serious". The clipping seen
earlier was the diagnostic screen's own frame being taller than the display, not an
engine-wide aspect problem.

### 2.1 The hit-testing constraint, which shapes the whole design

**`UIHostingController`'s view does its own internal hit-testing and returns *itself* for
every point.** A SwiftUI `Button` is not a separate `UIView`; it is a region the hosting
view handles internally. A passthrough window therefore cannot tell "over a control" from
"over empty space" by view identity — both come back as the hosting view.

This is not a footnote. It cost a device round-trip in M2, where rejecting the hosting
view to let touches through rejected the button along with them: the game became fully
playable in the same build that made the button completely inert, so the working half made
it look like a success.

**The rule M3 must follow: every interactive region is its own view.** Either a UIKit
control, or its own small `UIHostingController` sized to the control, added as a sibling
above the full-screen backdrop. Then identity separates them again — the backdrop is
rejected, each island is not. A single full-screen SwiftUI overlay with controls inside it
**cannot work**, and will fail in the specific way that looks like success.

## 3. Constraints

Unchanged: no secrets in CI; never modify Ren'Py's source; never download a game; MIT
only; never weaken an assertion to make a check pass.

Carried forward from M2, and load-bearing:

- **Never pause SDL's `CADisplayLink`.** SDL drives Ren'Py's frame execution from it and
  the command spool is drained per frame. Pausing it means commands are never read — the
  app hangs with no error at all.
- **Commands are `{"name": ..., "args": {...}}`.** `vnshell.mailbox` has read that shape
  since Milestone A. `tests/protocol/*.json` pins it from both sides.
- **Only argument-free `NSLog` survives the USB relay.** Any number that has to be read
  off a device must be rendered on screen; it can never be logged.

## 4. The summon gesture

### 4.1 It cannot live on the overlay window, and that reshapes the design

**A `UIGestureRecognizer` only receives touches if its view is returned by `hitTest`.**
Our overlay window returns `nil` for empty space so touches reach the game — which means
a recognizer attached to that window's backdrop **never sees `touchesBegan` and can never
fire.** Returning a view for a right-edge strip instead makes that strip a permanent dead
zone for the game, which is what §1 says M3 exists to remove.

Both reviewers found this independently, and it is the most valuable thing the review
produced: the first draft of this section specified a gesture that could not work.

Two ways out:

**(a) Put the recognizer on SDL's own view.** A custom `UIPanGestureRecognizer` — not
`UIScreenEdgePanGestureRecognizer` — with a start-region test, a distance threshold and a
vertical-drift limit, cancelling SDL's touches only *after* it recognises. Costs the game
nothing when it does not fire.

**(b) A small floating handle.** A 24×64pt translucent tab docked to the right edge. It is
its own view, so it is hit-testable with no ambiguity at all.

**Recommendation: (b) for M3, with (a) as a follow-up if the handle proves annoying.**

The reviewers split here — one recommended the swipe on SDL's view, one the handle — and
the deciding factor is this project's economics rather than elegance. Option (a) has to be
tuned against real games by trial, and every trial is a CI build plus a manual sideload by
one person. Option (b) has one failure mode (it is visible) and needs no tuning. A gesture
that misfires into Ren'Py's swipe-to-rollback would also be actively destructive: the
reader loses their place and has no idea why.

The handle is smaller, dimmer and edge-docked compared with M2's corner button, and unlike
that button it can be dragged along the edge and out of the way.

### 4.2 The overlay's three hit-testing states

The window's behaviour must be explicit, because "sometimes passes through" is exactly
what produced M2's inert button:

| State | Backdrop | Controls | Notes |
|---|---|---|---|
| Closed | passes through | the handle only | ordinary play |
| Open | **absorbs** | all | a tap outside dismisses, and must NOT also advance dialogue |
| Magnified | **absorbs** | pan/zoom | see §6 |

The "open absorbs" row is a review finding. Dismiss-by-tapping-outside that also advances
the game is a bad failure, and the M2 code as written would have done exactly that.

## 5. Controls

Each is a command through the existing spool. None may restart the engine except quit.

| Control | Command | Ren'Py call |
|---|---|---|
| Quick save | `quickSave` | `renpy.save("quick-1", ...)` — see §8 |
| Quick load | `quickLoad` | `renpy.load("quick-1")` |
| Rollback | `rollback` | `renpy.rollback()`, guarded by `renpy.can_rollback()` |
| Skip toggle | `toggleSkip` | `renpy.config.skipping` |
| Close | — | Swift-side only; closes the overlay |
| Magnifier | — | Swift-side only; §6 |
| Quit to library | `quitToLibrary` | already implemented |

"Hide UI" from the draft is renamed **Close**. A reviewer pointed out that a reader will
expect "Hide UI" to hide the *game's* dialogue window, not ours — and the draft meant ours.

### 5.1 A defect this makes real

`vnshell.lifecycle.tick()` carries this note today:

> both current handlers restart the engine … That aborts this loop, so any further
> commands already pulled from this poll() batch are silently dropped … it will be a real
> bug once a non-restarting handler lands.

M3 is when that lands. **Fix it as the first task of M3.** Both reviewers went further and
they are right: process one engine command per tick, keep a Python-side pending queue, and
emit a result event per `commandId`. That also removes double-tap races such as a quick
save immediately followed by a quick load.

### 5.2 Exception handling — the reviewers are WRONG here, and the hazard is inverted

Both reviews warned that wrapping handlers in `except Exception` would swallow Ren'Py's
control-flow exceptions and break rollback and load. **Checked against the source, and it
is not so. The hazard runs the other way:**

```
renpy/rollback.py:1185   class RollbackException(BaseException)
renpy/game.py:142        class UtterRestartException(Exception)
renpy/game.py:168        class JumpException(Exception)
```

`RollbackException` derives from **`BaseException`**, precisely so that ordinary
`except Exception` handlers do not eat it. Rollback is safe inside a blanket handler.

`UtterRestartException` derives from **`Exception`** — and that one is *ours*. It is what
`_restart()` raises for `launch` and `quitToLibrary`. **A blanket `except Exception:`
around handler dispatch would silently break quit-to-library**, the one control a stuck
reader most needs. The draft specified exactly that wrapper.

So: catch narrowly, and let control-flow exceptions propagate. Never `except Exception`
around a handler that may restart the engine. A test must cover it — dispatching
`quitToLibrary` through the wrapper has to still restart.

### 5.3 Guarding save, without an API that does not exist

One review recommended guarding with `renpy.exports.can_save()`. **That function does not
exist in Ren'Py 8.5.3.** `renpy.can_rollback()` does (`rollbackexports.py:73`) and is the
right guard for rollback.

For save, Ren'Py's own `FileSave.get_sensitive()` (`common/00action_file.rpy:421`) is the
authority, and it checks:

```python
_in_replay          # in a replay
main_menu           # at the main menu, not in a game
page == "auto"      # the autosave page
not config.save     # saving disabled by the game
```

Mirror those four rather than inventing a fifth. Each refusal produces an event the
overlay renders as a plain sentence — "you can't save at the main menu" is an answer, not
an error to swallow.

### 5.4 The overlay needs to know what the engine can do

Missing from the draft, raised in review: Swift has no idea whether the game is at a menu,
in a replay, skipping or auto-advancing, so it cannot enable and disable its own controls.
Every button looks available whether or not it will work.

Python emits a small periodic state event — `canRollback`, `canSave`, `isSkipping`,
`autoAdvance` — throttled to changes rather than sent per frame. The overlay greys out
what will not work instead of offering it and failing.

## 6. Magnifier

A `CATransform3D` scale and translate applied to **SDL's view**, never to Ren'Py. Parent
spec §9's reasoning holds: games position UI with hardcoded pixel geometry, so changing
font size clips dialogue out of its box. Scaling rendered output cannot break a layout the
game never learns about.

**Magnified mode is modal, and that is a review finding rather than a preference.** Pan
gestures have the same routing problem as the summon gesture and worse consequences: a
drag that reaches SDL is fed to Ren'Py, which reads horizontal drags as rollback. Panning
the magnifier would scroll the reader backwards through dialogue they had not finished.
So while magnified the overlay backdrop **absorbs every touch** and handles pan and zoom
entirely in Swift; nothing reaches SDL until magnification is dismissed.

Other things to expect, from review:

- **Blur.** This is a viewport zoom of a rasterised texture, not a font-size reflow. Small
  text gets bigger *and* softer. Say so in the UI once, rather than letting it look like a
  rendering bug.
- **Orientation, backgrounding and drawable size.** Save the original layer transform,
  apply it around a defined anchor, clamp pan to bounds, and re-test after rotation and
  after a background/foreground cycle.
- **Black margins** at the edges of a panned view.

Touch coordinates while magnified stop being an open question, because nothing passes
through while magnified. They become one again if magnification is ever made non-modal.

## 7. Memory watch-and-warn

Parent spec §14 decided watch-and-warn over a hard cap on switches: the realistic pattern
is one switch then hours of reading, so a cap punishes everyone for a case few reach, and
reproduces the artificial-limit feel of the paid apps this project exists to replace.

**The threshold cannot be set from the desktop figure.** The harness measured Windows
working-set at ~22 MB per switch; iOS kills on `phys_footprint`, a different number that
counts compressed and IOKit-mapped memory. M2 shipped an on-device probe reporting
`phys_footprint` and `os_proc_available_memory` into the library UI.

**This section is deliberately unfinished until that reading exists.** Writing a threshold
now would be inventing a number and then defending it. What is decided:

- The warning is dismissible and suggests restarting the app, never blocking a switch.
- It triggers on headroom remaining (`os_proc_available_memory`), not on total used —
  the distance to being killed is what matters, and it varies with what else the device
  is doing.
- `didReceiveMemoryWarningNotification` clears Ren'Py's image cache immediately,
  regardless of the threshold.

## 8. Save integration

Quick save and quick load use **Ren'Py's own quick-save page**, not an invented slot.
`common/00action_file.rpy:949` defines `QuickSave` as `FileSave(1, page="quick",
cycle=True)` -- slot `"quick-1"`. Both reviewers independently recommended a reserved
slot over writing to the game's most recent one, and Ren'Py already reserves exactly
this one: the overlay's quick save shows up in the game's own load screen under Q.Save,
and cannot overwrite a deliberate checkpoint. Per-game isolation already works: `path_to_saves` keys on `gameId` and lives
outside the game tree, verified on the desktop harness with two games declaring an
*identical* `config.save_directory`.

Exporting saves is M4. The Files app already exposes `Documents/Saves/<gameId>/`, which is
a manual answer in the meantime.

## 9. Discoverability

The target reader is the author's sister: computer-competent, not a developer. A gesture
nobody mentions is a gesture nobody uses.

On the first launch of any game, show the overlay already open, with a one-line note
saying how to bring it back. Dismissed once, per install, not per game. This is not a
permanent handle — it appears once and then never again.

## 10. Testing

**In `VNPlayerCore`, headless:** command construction for every new control (extending
`ProtocolMessages` and its round-trip tests), and the memory-threshold logic once a
threshold exists.

**In Python:** each new handler, including its failure path — a `rollback` with nothing to
roll back must produce an event, not an exception. Plus a regression test for §5.1: a
batch of several commands where the first does not restart must deliver all of them.

**On device**, in this order, because each depends on the last:

1. The summon gesture opens the overlay, and does not fire during ordinary play.
2. Each control does what it says, in a real game.
3. The magnifier scales, pans, and **taps still land where they look**.
4. Quick save then quick load returns to the same point.
5. Memory after several switches matches what the probe predicted.

## 11. Risks

| Risk | Standing |
|---|---|
| The summon gesture collides with a game's own gestures | Confirm on device before building on it (§4). Cheap to test alone |
| Magnified touch coordinates do not map | Verify before relying on it (§6). Failure mode is worse than no magnifier |
| A control runs at a moment Ren'Py cannot service it | Every handler wraps its call and reports failure as an event (§5.2) |
| The dropped-command defect | Fix first, not last (§5.1) |
| Memory forces a design change | Section deliberately unfinished until the device reading exists (§7) |

## 12. Out of scope

Text-size scaling (cut in the parent spec, and the magnifier replaces it), cover art,
export saves, settings, Ren'Py 7 support, and anything about the App Store.

## 13. Open questions for review

1. **Is a right-edge swipe the right summon gesture** for someone who is not a developer,
   given it must not collide with Ren'Py's own swipe-to-rollback?
2. **Should quit-to-library confirm** when the game has unsaved progress — and can that
   even be known from outside the engine?
3. **Should the overlay pause the game** while open? It cannot pause the display link
   (§3), but it could stop auto-advance and skipping.
4. **Is a reserved quick-save slot right**, against writing to the game's own most-recent
   slot, which would be visible from the game's own load screen?
