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

### Tried and found unnecessary: five candidates for the memory-growth failure

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

None of the five are in `shell/vnshell/purge.py`. Keeping them would have been
speculative cleanup in a path that runs between every game switch, with measured
evidence that they do not fix the failure they were added for.

### Full harness: `bash scripts/run_harness.sh 100`

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

### Bottom line for Task 8

- **`sys.modules`/`sys.path` contamination: fixed**, confirmed over 100 launches (50
  A→B, 50 B→A), zero failures.
- **Store-variable leakage and save-directory isolation: still clean**, as at the Task 7
  baseline — unaffected by this task, reconfirmed over 100 launches.
- **Memory growth: not fixed, and not a purge-layer problem.** Every Python-level cache
  reachable from `select_next_basedir` (image cache, font cache, forced GC) was tried
  and made no measurable difference; the three caches that plausibly hold the actual
  leaked memory (render tree, audio, video) are not reachable from this hook point at
  all, because their owning subsystem does not exist yet on this pass. The growth is
  linear and shows no sign of slowing over 100 cycles — this rules out a one-time
  fixed-size leak (e.g. from the crashed first run's cleanup) and points to something
  that reallocates roughly constant-sized state every single switch without releasing
  the old copy — most likely at the Ren'Py C/SDL level (surfaces, GL objects, or similar
  native display resources tied to `renpy.game.interface`, which is recreated fresh on
  every pass through the restart loop) rather than in ordinary Python heap the GC can
  reach.
- **Consequence for the iOS plan:** as specified in the milestone brief, unbounded
  ~22 MB/switch growth is exactly the shape of failure that becomes a Jetsam kill on
  iOS. The iOS app cannot currently switch games freely for an unbounded session; it
  needs either a per-session switch cap sized to the platform's memory ceiling, or
  further investigation into the native-level render/audio/video teardown that
  `renpy.bootstrap`'s own (loop-external) `finally` performs at process exit — see the
  `im.cache.quit()` / `draw.quit()` / `audio.audio.quit()` calls this module's docstring
  references — to find out whether an equivalent can be invoked mid-run once the
  relevant subsystem objects actually exist for the pass that is about to end, not the
  pass that is about to begin.
