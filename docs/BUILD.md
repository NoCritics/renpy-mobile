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
