# Build notes

## Ren'Py 8.5.3 SDK layout

Recorded after running `scripts/fetch_deps.sh`, which downloads and unpacks the pinned
Ren'Py 8.5.3 SDK into `vendor/renpy-8.5.3-sdk/`. This is reference material for the iOS
build plan, which must reproduce this layout inside an app bundle.

```
$ ls vendor/renpy-8.5.3-sdk/
LICENSE.txt
doc/
gui/
launcher/
lib/
renpy/
renpy.app/
renpy.exe*
renpy.py*
renpy.sh*
sdk-fonts/
the_question/
tutorial/
update/

$ ls vendor/renpy-8.5.3-sdk/lib/
py3-linux-x86_64/
py3-mac-universal/
py3-windows-x86_64/
python3.12/
```

Notes:
- `lib/py3-windows-x86_64/` contains the bundled Windows CPython, including
  `python.exe`, that later Milestone A tasks launch directly.
- `lib/` also ships `py3-linux-x86_64/`, `py3-mac-universal/`, and a version-only
  `python3.12/` directory (platform-independent bytecode/stdlib support), alongside the
  Windows build.
- `renpy/bootstrap.py` (under `renpy/`) is the bootstrap entry point every later task
  assumes exists.

## Harness baseline

Recorded after running `bash scripts/run_harness.sh 4` (Milestone A, Task 7, third
correction). There is no purge layer yet (Task 8 builds one); a PASS at this step
would have been the surprising result. This section supersedes two earlier baselines
recorded during this task — see "History of this baseline" at the bottom for the
full trail. Read that section before drawing any conclusion about style state.

**Style bleed is UNTESTED, not "clean."** No canary built during Task 7 has
successfully exercised Ren'Py's mutable style state in a way that both (a) proves
the marker took effect and (b) is not already Ren'Py's own baseline value. The
`config.name` canary below is real and passed cleanly, but it tests **per-game
init-time declarations**, not **mutable style state** — those are different
surfaces of "does init state survive a switch," and only the first has actually
been tested. Do not infer that styles are fine merely because no check reports
them; that inference is exactly the mistake the last two rounds were about.

Command and outcome:

```
$ bash scripts/run_harness.sh 4
Applying shell overlay...
Rig ready at /c/Users/user/source/repos/workstation/renpy-moile/.rig
Running 4 cycles (timeout 80s)...
Resetting cache.
Resetting cache.
Resetting cache.
Resetting cache.
Engine exited cleanly.
FAIL: cycle 1: game B read sentinel 'A', expected 'B' — sys.modules contamination
FAIL: cycle 3: game B read sentinel 'A', expected 'B' — sys.modules contamination
FAIL: memory grew from 184.7 MB to 261.3 MB over 5 cycles — leak
```

Overall script exit status: **1** (from `check.py`). Engine process exit status:
**0** ("Engine exited cleanly.") — not a crash, hang, or timeout. Both `FAIL:`
lines came from `check.py` inspecting real, complete observations.

Cycles: `harness/out/cycle.txt` contains `5` (4 requested + 1, the same
off-by-one-at-completion behavior as every prior run — the counter increments past
the final launch before `advance()` recognizes it should stop). All 4 requested
launches (A, B, A, B) completed and produced one observation record each.

`harness/out/observations.jsonl`, verbatim, in full:

```
{"game": "A", "sentinel_value": "A", "config_name": "Sentinel A", "saves_dir": "C:/Users/user/source/repos/workstation/renpy-moile/harness/out/saves/game_a", "leaked_store_var": null}
{"game": "B", "sentinel_value": "A", "config_name": "Sentinel B", "saves_dir": "C:/Users/user/source/repos/workstation/renpy-moile/harness/out/saves/game_b", "leaked_store_var": null}
{"game": "A", "sentinel_value": "A", "config_name": "Sentinel A", "saves_dir": "C:/Users/user/source/repos/workstation/renpy-moile/harness/out/saves/game_a", "leaked_store_var": null}
{"game": "B", "sentinel_value": "A", "config_name": "Sentinel B", "saves_dir": "C:/Users/user/source/repos/workstation/renpy-moile/harness/out/saves/game_b", "leaked_store_var": null}
```

`harness/out/rss.jsonl`, verbatim, in full:

```
{"cycle": 0, "rss_bytes": 135913472}
{"cycle": 1, "rss_bytes": 184688640}
{"cycle": 2, "rss_bytes": 212156416}
{"cycle": 3, "rss_bytes": 233992192}
{"cycle": 4, "rss_bytes": 261304320}
```

In decimal MB (bytes / 1e6): 135.9, 184.7, 212.2, 234.0, 261.3.

No traceback file was produced (`.rig/traceback.txt` and `harness/out/**/traceback.txt`
both checked before and after the run; both absent).

### Interpretation

- **`config.name` canary: both halves passed, on every launch.** Game A read back
  `"Sentinel A"` on both of its launches (cycle 0, cycle 2), and game B read back
  `"Sentinel B"` on both of its launches (cycle 1, cycle 3) — never each other's
  value. This is the first style/init-state canary in this task that both proved
  itself working (A reads its own value) and produced a clean result (B does too).
  Per-game `options.rpy` declarations — at least `config.name` — do **not** survive
  a switch; each game consistently sees its own.
  - This is **not** the same claim as "styles don't bleed." `config.name` is a
    simple string constant declared via `define`, re-evaluated as part of each
    game's own init phase when Ren'Py restarts into it. It says nothing about
    mutable style objects (`style.default` and friends), which is the surface the
    two earlier, failed canaries were trying and failing to test. That surface
    remains untested — see the warning above.
- **`sys.modules` contamination, still real and reproduced on every A→B switch.**
  Both times game B loaded (cycle 1 and cycle 3), `sentinel.VALUE` read `"A"`
  instead of `"B"` — unaffected by the canary swap, since this check reads a plain
  Python module attribute.
- **Real, monotonic memory growth, still real.** 135.9 → 184.7 → 212.2 → 234.0 →
  261.3 MB across the 5 samples — a 41.5% increase from the reading after the first
  switch to the reading after the fourth, against the 30% ceiling. Consistent with
  the two prior runs' findings within measurement noise.
- **Store variables were still not contaminated**, and **save directories stayed
  correctly isolated** — same as every prior run of this harness.

### Bottom line

Two purge targets remain confirmed and actionable for Task 8: **`sys.modules`
caching** and **per-switch memory growth**. A third surface — per-game
`options.rpy`/init declarations, tested via `config.name` — is now confirmed
**clean**: each game correctly sees its own declared value, never the other
game's. A fourth surface — **mutable style state** — remains **completely
untested** after three attempts at a canary for it; the first two canaries were
both broken instruments, and this run replaced the style-based approach entirely
rather than fixing it a third time. Task 8 should treat mutable style state as an
open question, not settle it either way from this file. Root cause for why the
two style-based canaries failed: **mutating a style outside an `init` block
requires an explicit `style.rebuild()` to take effect** — the second canary's
`style.default.size = 137` assignment was real but never became visible to a
same-statement read-back, which is the SDK-documented behavior, not a bug in the
harness or the fixture.

### History of this baseline

This section has been rewritten three times since Task 7 first ran the harness.
Recorded here so Task 8 has the full trail rather than just the current
conclusion:

1. **First run** (`bash scripts/run_harness.sh 2`): reported `sys.modules`
   contamination and a "style bleed" via a `style.default.font` check. RSS was not
   measured at all (`GetProcessMemoryInfo` failed silently due to a 64-bit handle
   truncation bug in `_rss_bytes()`), and `check.py` at the time silently skipped
   the memory-growth check when nothing was measured — a false-negative risk.
2. **Second run** (`bash scripts/run_harness.sh 4`, after fixing the RSS probe):
   confirmed real, monotonic memory growth (40.7% over 4 switches) for the first
   time, and `check.py` was changed to fail loudly instead of skipping when RSS is
   unmeasured. The font-based "style bleed" finding from run 1 was subsequently
   determined to be a **false positive**: `renpy/common/00style.rpy:139` sets
   `font "DejaVuSans.ttf"` as the engine-wide default for *every* game, so a
   font-based canary reports "bleed" even on a perfectly clean reset — it cannot
   distinguish contamination from Ren'Py's own baseline. Game A's `script.rpy` also
   set the font *after* calling `observe("A")`, so game A's own record never proved
   the marker had taken effect in the first place.
3. **Third run** (`bash scripts/run_harness.sh 4`, style-size canary): replaced the
   font canary with a text-size canary (`style.default.size`, engine default 22,
   game A sets 137 *before* observing) and added a canary-integrity assertion
   (game A must read back its own marker). That assertion immediately caught that
   this canary was *also* broken — game A never read back 137, only ever 22, on
   both of its launches. Root cause, confirmed against the SDK docs afterward:
   mutating a style outside an `init` block requires `style.rebuild()` to take
   effect, which the fixture never called. This was a fixture/design defect, not
   an engine finding — it says nothing about whether style state actually bleeds.
4. **This run** (fourth, current): abandoned style mutation entirely in favor of
   `config.name`, a value each game already declares in its own `options.rpy` with
   no special API or rebuild ceremony required. Both halves of the new assertion
   passed on every launch: game A always reads `"Sentinel A"`, game B always reads
   `"Sentinel B"`. This is a genuine, trustworthy clean result for per-game
   `options.rpy`/init declarations — but it is a different surface from mutable
   style state, which remains completely untested. The `sys.modules` and
   memory-growth findings carried forward unchanged and were reconfirmed on this
   run's own data, as they have been on every run in this history.

## Purge findings

Recorded after Milestone A, Task 8 (`shell/vnshell/purge.py`, wired into
`shell/vnshell/lifecycle.py:select_next_basedir`). This section is the empirical answer
to what between-game cleanup is actually required, as opposed to what the task brief
hypothesized might be required. Both halves — what proved necessary and what was tried
and discarded — are recorded, per the task's own instruction that a step nobody can
justify is a liability for the iOS plan.

**This section covers two hook points, tried in this order, and the result at each is
recorded separately below rather than overwritten** — the distinction between them is
itself the most useful thing this task hands to the iOS plan:

1. **Post-reload hook**, `purge_engine_state()`, called from
   `lifecycle.select_next_basedir()`. Bootstrap calls this *after*
   `renpy.reload_all()`, so any engine module reachable only through fresh module state
   (image cache, render cache, font cache, audio/video subsystems) is already a new,
   empty object here — cleanup at this point has nothing live to act on except
   `sys.modules`/`sys.path`, which persist across `reload_all()` regardless.
2. **Pre-restart hook**, `teardown_live_engine()`, called from `lifecycle._restart()`,
   *before* `UtterRestartException` is raised. This is the last moment the outgoing
   game's renderer, audio subsystem and caches are still live, reachable objects — the
   same objects bootstrap.py's own `finally` (bootstrap.py:409-419) tears down once, at
   process exit, outside the restart loop.

The first pass at this task tried five memory candidates against the post-reload hook
and found none of them helped. Task 8's coordinator caught that this was very likely
the wrong hook — the objects being cleaned were freshly reconstructed, not the leaking
ones — and asked for the same kind of calls to be retried from the pre-restart hook
instead. Both experiments and both results are recorded below in full: the fix to
*where* teardown runs did not turn out to fix the leak, but confirming that empirically,
rather than assuming it from the theory, is exactly the discipline this section exists
to enforce.

### Necessary: purging `sys.modules` and `sys.path` under the previous game's `game/` dir

This is the only step that measurably fixed a reported failure. Before it existed, the
harness baseline (`## Harness baseline` above) showed game B reading game A's cached
`sentinel.VALUE` (`"A"` instead of `"B"`) on both A→B switches. After wiring in
`purge._purge_modules`, four separate 4-cycle harness runs (the correction below, plus
three more while testing memory candidates) each showed zero `sys.modules`-contamination
failures, and the 100-cycle run at the bottom of this section confirmed it holds over 50
A→B switches, not just 2.

**A real bug was found and fixed while wiring this in, worth recording in detail.** The
brief's own `purge_engine_state` code purges everything under `previous_basedir` itself.
That is wrong for the *first* switch of every run: the shell project's own basedir, per
`shell/main.py:path_to_renpy_base`, is the directory `main.py` lives in — which the rig
places at the SDK root (`.rig/`) and which iOS will place at the app bundle root. That
root also holds `renpy/` (the engine), the interpreter's own standard library, and
`vnshell/` itself. Purging "everything under the previous basedir" on the first
shell→game switch therefore purged the running interpreter out from under itself:

```
$ bash scripts/run_harness.sh 4
...
[vnshell] purge: purged 330 modules: __future__, __main__, ..., re, ...,
renpy, renpy.bootstrap, ..., vnshell, vnshell.lifecycle, vnshell.purge, ...
...
ModuleNotFoundError: No module named '__main__'
...
Engine exited with status 1 (expected 0).
FAIL: .../observations.jsonl missing — the run did not produce output
```

It also stripped the SDK root from `sys.path` (`sys.path[:] = [p for p in sys.path if
not os.path.abspath(p).startswith(root)]`, with `root == previous_basedir`), which would
have broken any subsequent import from the engine's own tree even if the module purge
itself had not already crashed the process.

The fix: scope the purge to `<previous_basedir>/game`, not `previous_basedir` itself.
This matches how code actually loads — `main.py:path_to_gamedir` requires a strict
`game/` subdirectory, and every observed game does `sys.path.insert(0,
renpy.config.gamedir)` where `gamedir == basedir/game` — so scoping to `game/` is not a
weaker version of the brief's approach, it is the *correct* scope the brief's own
reasoning (about `utils.py` collisions) already implied. After the fix:

```
$ bash scripts/run_harness.sh 4
...
[vnshell] purge: purged 1 modules: sentinel
...
Engine exited cleanly.
FAIL: memory grew from 185.3 MB to 261.2 MB over 5 cycles — leak
```

`sys.modules` contamination: gone. Only the pre-existing memory-growth failure remained.

**A second real bug, same shape, found in Task 8 code review after the above was
written.** The `sys.modules` filter correctly uses a directory-boundary guard
(`resolved.startswith(root + os.sep)` — a trailing separator, so `.../game_assets`
cannot match a `root` of `.../game`), but the `sys.path` filter a few lines below it
used a bare `os.path.abspath(p).startswith(root)`, with no such guard. With
`root = <previous_basedir>/game`, a sibling directory like `<previous_basedir>/gamelib`
or `<previous_basedir>/game_assets` prefix-matches the string `"…/game"` and would have
been wrongly stripped from `sys.path` on every switch, even though it is not under
`game/` at all. Invisible to the harness because neither sentinel game ships such a
sibling — a latent bug, not a theoretical one, since real games commonly do. Fixed by
giving the `sys.path` filter the identical `_under_root` boundary check the module
filter already had (`resolved == root or resolved.startswith(root + os.sep)`). No
harness-observable behavior changed for the sentinel games (confirmed by rerunning
`bash scripts/run_harness.sh 4`: same "purged 1 modules: sentinel" outcome, same
memory-only failure) — this fix protects a case this harness cannot exercise, which is
exactly why review caught it and the harness did not.

### Tried and found unnecessary (post-reload hook): five candidates for the memory-growth failure

Each was added alone to `purge_engine_state`, run through `bash scripts/run_harness.sh
4`, and compared against the module-purge-only baseline (185.3 MB → 261.2 MB, +40.9%
over 5 samples). None moved the result outside run-to-run noise (~1 MB on a ~260 MB
process), and none flipped the check from FAIL to PASS, alone or in combination:

| Candidate | Result | End RSS (4-cycle run) |
|---|---|---|
| `renpy.display.im.cache.clear()` | ran cleanly, no measurable effect | 261.1 MB |
| `renpy.text.font.free_memory()` | ran cleanly, no measurable effect | 261.2 MB |
| `gc.collect()` | ran cleanly, freed ~9,700 objects every switch, no measurable effect on RSS | 259.2 MB |
| `renpy.display.render.free_memory()` | **always raised** `AttributeError: 'NoneType' object has no attribute 'surftree'` | n/a (step failed every time) |
| `renpy.audio.music.stop(...)` | **always raised** `IndexError: list index out of range` | n/a (step failed every time) |
| `renpy.display.video.movie_stop(...)` | **always raised** `IndexError: list index out of range` | n/a (step failed every time) |
| all three non-failing candidates combined (image cache + font cache + gc.collect) | ran cleanly | 260.5 MB |

The three that always raised are not "broken" in the sense of a bug to fix — they fail
because `select_next_basedir` runs *before* Ren'Py has (re)created its rendering
interface and audio/video subsystems for the next pass through the restart loop
(`renpy.game.interface` is `None` at this point). There is currently no Python-level
hook available to this module, between passes of the bootstrap restart loop, at which
those subsystems exist and can be asked to free memory. All three failed defensively —
they were caught, logged as `failed: ...`, and did not crash the switch — which is
exactly the behavior the brief required of every step.

None of the five are in `purge_engine_state` in `shell/vnshell/purge.py`. Keeping them
there would have been speculative cleanup in a path that runs between every game
switch, with measured evidence that they do not fix the failure they were added for.
(Four of the five reappear below, retried from the *other* hook, where they can
actually execute against live objects — see "Necessary at the pre-restart hook" below.)

### First full harness (post-reload hook only): `bash scripts/run_harness.sh 100`

```
Running 100 cycles (timeout 560s)...
...
Engine exited cleanly.
FAIL: memory grew from 185.2 MB to 2359.6 MB over 101 cycles — leak
```

**Not a PASS.** `sys.modules` contamination and store-variable leakage both held clean
over all 100 launches (50 A→B and 50 B→A switches) — checked directly against
`harness/out/observations.jsonl`: 100 records, zero contamination, zero store leaks,
save directories stayed isolated throughout. The engine exited cleanly (status 0); this
was not a crash, hang, or timeout. The only failure is memory growth, and at 100 cycles
it is severe and clearly unbounded, not noise: **135.6 MB → 2,359.6 MB**, growing
essentially linearly at roughly **22 MB per switch**, with no sign of a plateau across
the full run. `RSS_GROWTH_LIMIT` (1.30, i.e. 30%) was left untouched, as instructed —
this is a real finding, not an instrument to relax.

Full growth curve, `harness/out/rss.jsonl`, verbatim (bytes; MB in the table below the
raw data):

```
{"cycle": 0, "rss_bytes": 135618560}
{"cycle": 1, "rss_bytes": 185204736}
{"cycle": 2, "rss_bytes": 212570112}
{"cycle": 3, "rss_bytes": 234385408}
{"cycle": 4, "rss_bytes": 260939776}
{"cycle": 5, "rss_bytes": 286490624}
{"cycle": 6, "rss_bytes": 305758208}
{"cycle": 7, "rss_bytes": 332140544}
{"cycle": 8, "rss_bytes": 349581312}
{"cycle": 9, "rss_bytes": 371269632}
{"cycle": 10, "rss_bytes": 396947456}
{"cycle": 11, "rss_bytes": 414674944}
{"cycle": 12, "rss_bytes": 440950784}
{"cycle": 13, "rss_bytes": 462299136}
{"cycle": 14, "rss_bytes": 489136128}
{"cycle": 15, "rss_bytes": 507383808}
{"cycle": 16, "rss_bytes": 528654336}
{"cycle": 17, "rss_bytes": 555425792}
{"cycle": 18, "rss_bytes": 572993536}
{"cycle": 19, "rss_bytes": 595329024}
{"cycle": 20, "rss_bytes": 612241408}
{"cycle": 21, "rss_bytes": 638812160}
{"cycle": 22, "rss_bytes": 655618048}
{"cycle": 23, "rss_bytes": 677007360}
{"cycle": 24, "rss_bytes": 703782912}
{"cycle": 25, "rss_bytes": 721981440}
{"cycle": 26, "rss_bytes": 747966464}
{"cycle": 27, "rss_bytes": 765652992}
{"cycle": 28, "rss_bytes": 790827008}
{"cycle": 29, "rss_bytes": 808652800}
{"cycle": 30, "rss_bytes": 830353408}
{"cycle": 31, "rss_bytes": 856289280}
{"cycle": 32, "rss_bytes": 874168320}
{"cycle": 33, "rss_bytes": 900239360}
{"cycle": 34, "rss_bytes": 919044096}
{"cycle": 35, "rss_bytes": 944783360}
{"cycle": 36, "rss_bytes": 962707456}
{"cycle": 37, "rss_bytes": 983916544}
{"cycle": 38, "rss_bytes": 1010143232}
{"cycle": 39, "rss_bytes": 1028898816}
{"cycle": 40, "rss_bytes": 1050378240}
{"cycle": 41, "rss_bytes": 1072832512}
{"cycle": 42, "rss_bytes": 1097936896}
{"cycle": 43, "rss_bytes": 1115660288}
{"cycle": 44, "rss_bytes": 1137414144}
{"cycle": 45, "rss_bytes": 1162506240}
{"cycle": 46, "rss_bytes": 1180536832}
{"cycle": 47, "rss_bytes": 1207009280}
{"cycle": 48, "rss_bytes": 1224351744}
{"cycle": 49, "rss_bytes": 1250557952}
{"cycle": 50, "rss_bytes": 1267929088}
{"cycle": 51, "rss_bytes": 1289342976}
{"cycle": 52, "rss_bytes": 1314279424}
{"cycle": 53, "rss_bytes": 1333768192}
{"cycle": 54, "rss_bytes": 1360379904}
{"cycle": 55, "rss_bytes": 1378471936}
{"cycle": 56, "rss_bytes": 1404399616}
{"cycle": 57, "rss_bytes": 1421758464}
{"cycle": 58, "rss_bytes": 1443614720}
{"cycle": 59, "rss_bytes": 1470263296}
{"cycle": 60, "rss_bytes": 1487073280}
{"cycle": 61, "rss_bytes": 1513455616}
{"cycle": 62, "rss_bytes": 1530929152}
{"cycle": 63, "rss_bytes": 1556578304}
{"cycle": 64, "rss_bytes": 1573982208}
{"cycle": 65, "rss_bytes": 1595822080}
{"cycle": 66, "rss_bytes": 1622609920}
{"cycle": 67, "rss_bytes": 1640058880}
{"cycle": 68, "rss_bytes": 1665409024}
{"cycle": 69, "rss_bytes": 1682960384}
{"cycle": 70, "rss_bytes": 1709240320}
{"cycle": 71, "rss_bytes": 1727254528}
{"cycle": 72, "rss_bytes": 1748045824}
{"cycle": 73, "rss_bytes": 1774465024}
{"cycle": 74, "rss_bytes": 1791823872}
{"cycle": 75, "rss_bytes": 1817636864}
{"cycle": 76, "rss_bytes": 1835196416}
{"cycle": 77, "rss_bytes": 1860886528}
{"cycle": 78, "rss_bytes": 1878220800}
{"cycle": 79, "rss_bytes": 1900138496}
{"cycle": 80, "rss_bytes": 1925771264}
{"cycle": 81, "rss_bytes": 1943101440}
{"cycle": 82, "rss_bytes": 1968459776}
{"cycle": 83, "rss_bytes": 1986142208}
{"cycle": 84, "rss_bytes": 2012585984}
{"cycle": 85, "rss_bytes": 2029547520}
{"cycle": 86, "rss_bytes": 2051416064}
{"cycle": 87, "rss_bytes": 2076782592}
{"cycle": 88, "rss_bytes": 2094854144}
{"cycle": 89, "rss_bytes": 2121089024}
{"cycle": 90, "rss_bytes": 2142744576}
{"cycle": 91, "rss_bytes": 2168299520}
{"cycle": 92, "rss_bytes": 2186878976}
{"cycle": 93, "rss_bytes": 2208415744}
{"cycle": 94, "rss_bytes": 2230251520}
{"cycle": 95, "rss_bytes": 2246914048}
{"cycle": 96, "rss_bytes": 2273529856}
{"cycle": 97, "rss_bytes": 2294644736}
{"cycle": 98, "rss_bytes": 2320306176}
{"cycle": 99, "rss_bytes": 2338021376}
{"cycle": 100, "rss_bytes": 2359607296}
```

Every 10th sample in MB (bytes / 1e6), to make the shape legible without scanning all
101 rows: cycle 0: 135.6, 10: 396.9, 20: 612.2, 30: 830.4, 40: 1050.4, 50: 1267.9,
60: 1487.1, 70: 1709.2, 80: 1925.8, 90: 2142.7, 100: 2359.6. The per-cycle delta is
consistently in the 17–27 MB range throughout the run (mean ≈ 22.2 MB/cycle) — this is
not front-loaded and not tapering off by cycle 100; a longer run would be expected to
keep climbing at roughly the same rate.

### Necessary at the pre-restart hook: `teardown_live_engine()`, called from `lifecycle._restart()`

After the first full harness above, the coordinator reviewing this task caught a real
error in where the five memory candidates were being tried: `select_next_basedir` runs
*after* `renpy.reload_all()` has already replaced the engine's module objects, so those
candidates were freeing freshly-constructed, still-empty caches — never the outgoing
game's actual GL surfaces, audio buffers, or font caches, which by that point are
orphaned and unreachable from Python. The only point those objects are still live and
reachable is *before* `UtterRestartException` is raised, inside `lifecycle._restart()`.

`shell/vnshell/purge.py` gained `teardown_live_engine()`, called from `_restart()`
before the raise, making six calls against the still-live engine — the same ones
bootstrap.py's own `finally` makes at process exit (bootstrap.py:409-419), plus
`renpy.text.font.free_memory()`: stop audio (`renpy.audio.music.stop` on all three
channels), stop video (`renpy.display.video.movie_stop`), free fonts
(`renpy.text.font.free_memory`), quit the image cache (`renpy.display.im.cache.quit`),
quit the renderer (`renpy.display.draw.quit`), and quit the audio subsystem
(`renpy.audio.audio.quit`). `purge_engine_state` (the post-reload hook, `_purge_modules`
only) was left unchanged, as instructed — the `sys.modules` fix must not regress.

**The most uncertain call, `renpy.display.draw.quit()`, was flagged as possibly fatal**
— quitting the renderer mid-session and expecting `main()`/bootstrap to reinitialize it
cleanly on the next pass was untested territory. It was not fatal. A 4-cycle run showed
all six teardown actions succeeding, every switch, with no traceback:

```
$ bash scripts/run_harness.sh 4
...
[vnshell] teardown: stopped audio
[vnshell] teardown: stopped video
[vnshell] teardown: freed fonts
[vnshell] teardown: quit image cache
[vnshell] teardown: quit renderer
[vnshell] teardown: quit audio subsystem
Resetting cache.
...
Engine exited cleanly.
FAIL: memory grew from 184.8 MB to 261.0 MB over 5 cycles — leak
```

Engine exited cleanly (status 0), same as every prior run. `sys.modules` contamination:
still gone. But the memory number at 4 cycles (184.8 → 261.0 MB) is indistinguishable
from the post-reload-only baseline (185.3 → 261.2 MB) — within the same ~1 MB
run-to-run noise band documented above. That is not proof by itself (4 cycles is too
short to trust, per the earlier history of this file), so a full 100-cycle run was run
to get a decisive answer rather than stopping on a short run that could be noise either
way.

### Second full harness (with pre-restart teardown added): `bash scripts/run_harness.sh 100`

```
$ bash scripts/run_harness.sh 100
Running 100 cycles (timeout 560s)...
...
Engine exited cleanly.
FAIL: memory grew from 184.9 MB to 2352.2 MB over 101 cycles — leak
```

All six teardown actions ("stopped audio", "stopped video", "freed fonts", "quit image
cache", "quit renderer", "quit audio subsystem") succeeded on every one of the 100
switches — zero `failed:` entries anywhere in the run's console output, confirmed by
scanning it in full. `renpy.display.draw.quit()` mid-session, followed by the next pass
through bootstrap reinitializing the renderer for the next game, is therefore
**survivable at 100 consecutive switches**, not just a handful. `sys.modules`
contamination and store-variable leakage: checked directly against
`harness/out/observations.jsonl`, 100 records, 0 contamination, 0 store leaks — same as
the first 100-cycle run.

**The memory number is, within noise, the same as the first 100-cycle run.**
136.1 MB → 2,352.2 MB over 101 samples, mean per-cycle
delta **≈ 21.9 MB/switch** (computed the same way as the first run's ≈ 22.2 MB/switch:
mean of `rss[i+1] - rss[i]` for `i` from cycle 1 to the second-to-last cycle, excluding
the cold-start cycle-0-to-1 jump). Last five deltas: 25.7, 17.7, 25.7, 18.0, 21.6 MB —
the same 17–27 MB band as before. `RSS_GROWTH_LIMIT` was left untouched.

Every 10th sample in MB from this run, for direct comparison against the first run's
table above: cycle 0: 136.1, 10: 396.4, 20: 610.7, 30: 830.4, 40: 1052.0, 50: 1265.3,
60: 1482.4, 70: 1704.6, 80: 1922.6, 90: 2140.0, 100: 2352.2. Full `harness/out/rss.jsonl`
from this run is not reproduced a second time verbatim in this file — the shape and
summary statistics above are, to within measurement noise, the same curve as the first
100-cycle run's, printed in full earlier in this section.

**Conclusion: moving teardown to the correct, pre-restart hook — and confirming it
executes successfully against live objects, including the previously-untested
`draw.quit()` — did not change the measured memory-growth rate.** The coordinator's
theory (post-reload cleanup was acting on the wrong, already-replaced objects) was
correct and worth testing; the fix for *that* bug did not turn out to be the fix for
the leak. Two possibilities remain, neither resolvable from this shell layer:
1. `draw.quit()` / `im.cache.quit()` / `audio.audio.quit()` release Python-visible
   references but the underlying native allocations (GL context objects, SDL surfaces,
   decoded audio buffers) are not actually freed back to the OS by these calls, or are
   re-leaked identically by whatever (re)initializes the next pass's interface.
2. The leak is somewhere neither hook can reach at all — e.g. per-pass allocation inside
   `renpy.main.main()`/`renpy.bootstrap.bootstrap()`'s own init sequence, which runs
   after both of vnshell's hooks and is out of scope for this shell layer to alter
   (modifying `renpy/` is explicitly disallowed for this task).

Both are native/engine-internal, not Python-cache leaks reachable from `vnshell.purge`,
regardless of which of the two hook points is used.

**Ruling on `teardown_live_engine()`'s six steps, from Task 8 review:** by the letter of
this task's own method — every purge step must be justified by a failure it measurably
fixes — these six steps have no such justification; they run every switch and
demonstrably do not move RSS. They are being kept anyway, and the reasoning is recorded
here rather than only in the code, because it changes what the iOS plan should do with
this section: what was actually measured is narrower than "these steps do nothing." It
is that they do not reduce **resident set size on Windows with an NVIDIA GL driver**.
RSS does not see driver-side allocations, and iOS runs a categorically different
graphics stack (MetalANGLE over Metal, not Windows OpenGL) — this measurement does not
transfer. The six steps are also Ren'Py's own documented process-exit sequence
(bootstrap.py:409-419) and have now been measured safe across 100 consecutive
mid-session calls, `draw.quit()` included. **The iOS port must re-measure these six
steps on-device rather than inherit this Windows result in either direction** — a null
result on Windows is not evidence they are safe to drop on iOS, and it would not have
been evidence to keep them if the result had been positive here either. Full reasoning
also lives in `teardown_live_engine()`'s docstring in `shell/vnshell/purge.py`.

### Bottom line for Task 8

- **`sys.modules`/`sys.path` contamination: fixed**, confirmed over 200 launches across
  two separate 100-cycle runs (100 A→B/B→A switches each), zero failures in either.
- **Store-variable leakage and save-directory isolation: still clean**, as at the Task 7
  baseline — unaffected by this task, reconfirmed over both 100-cycle runs.
- **Memory growth: not fixed, at either hook point, and this was checked, not assumed.**
  First pass: every Python-level cache reachable from the post-reload hook
  (`select_next_basedir` → `purge_engine_state`) — image cache, font cache, forced
  GC — was tried and made no measurable difference; the other three (render tree,
  audio, video) could not even run there, because their owning subsystem does not exist
  yet on that pass. Second pass, after the coordinator's correction: the same kind of
  calls, plus `draw.quit()` and `audio.audio.quit()`, were moved to the pre-restart
  hook (`lifecycle._restart()` → `teardown_live_engine()`), where the objects *are*
  still live — confirmed by all six actions succeeding on every one of 100 switches,
  with no crash, including the previously-untested `draw.quit()`. The measured growth
  rate did not move: ≈ 22.2 MB/switch before, ≈ 21.9 MB/switch after — the same curve
  within run-to-run noise, not a partial improvement. The growth is linear and shows no
  sign of slowing over either 100-cycle run — this rules out a one-time fixed-size leak
  and points to something that reallocates roughly constant-sized state every single
  switch without releasing the old copy, and does so regardless of which of vnshell's
  two hook points asks the engine to release its caches. Most likely explanation: the
  actual native allocations (GL context objects, SDL surfaces, decoded audio/font
  buffers) are not released by `im.cache.quit()`/`draw.quit()`/`audio.audio.quit()`
  themselves, or are re-leaked identically by whatever (re)initializes the next pass's
  `renpy.game.interface` inside `renpy.main.main()` — code this task is not permitted to
  modify (`renpy/` is off-limits) and which runs after both of vnshell's hooks regardless.
- **Consequence for the iOS plan:** as specified in the milestone brief, unbounded
  ~22 MB/switch growth is exactly the shape of failure that becomes a Jetsam kill on
  iOS, and it survives fixing both *what* gets torn down and *when*. The iOS app cannot
  currently switch games freely for an unbounded session; it needs a per-session switch
  cap sized to the platform's memory ceiling. Further reduction, if any is possible,
  would require instrumenting or modifying Ren'Py's own C/SDL-level teardown
  (`renpy/`, out of scope for this shell-layer task) rather than anything callable from
  `vnshell.purge` at either hook point available to it.
