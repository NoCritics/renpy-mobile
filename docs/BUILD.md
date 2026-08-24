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

Recorded after running `bash scripts/run_harness.sh 4` (Milestone A, Task 7, corrected
run). This is the **expected first failure** — there is no purge layer yet (Task 8
builds one), and this run's output is exactly the evidence Task 8 is derived from. A
PASS at this step would have been the surprising result.

An earlier 2-cycle run of this same harness reported `rss_bytes: 0` for every sample
because `GetCurrentProcess()` was called without declaring `restype`; ctypes defaults
that to `c_int`, which truncates the 64-bit pseudo-handle and makes
`GetProcessMemoryInfo` fail silently. `check.py` also treated an all-zero RSS log as
"nothing to check" rather than a failure, so a broken probe could have produced a
false PASS on the memory-growth check. Both were fixed (see `shell/vnshell/harness.py`
`_rss_bytes()` and `harness/check.py`'s RSS section) and the harness was re-run with
4 cycles, below, so the memory check would have enough samples to be meaningful.

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
FAIL: cycle 1: game B inherited game A's font 'DejaVuSans.ttf' — style bleed
FAIL: cycle 3: game B read sentinel 'A', expected 'B' — sys.modules contamination
FAIL: cycle 3: game B inherited game A's font 'DejaVuSans.ttf' — style bleed
FAIL: memory grew from 185.4 MB to 260.9 MB over 5 cycles — leak
```

Overall script exit status: **1** (non-zero, from `check.py`). The engine process
itself exited **cleanly with status 0** — it ran the full requested cycle count and
called `sys.exit(0)` from `vnshell.harness.advance()` once `cycle > _total_cycles()`.
The failure is not a crash or a hang: the engine ran to completion and all five
`FAIL:` lines above came from `check.py` inspecting the resulting observations.

Cycles: `harness/out/cycle.txt` contains `5` after the run (4 requested + 1, since the
counter is incremented past the last real launch before the run recognizes it should
stop and exits). All 4 requested game launches (A, B, A, B) completed and each
produced one observation record — the run did not stop early.

`harness/out/observations.jsonl`, verbatim, in full (4 lines, one per cycle):

```
{"game": "A", "sentinel_value": "A", "font": "DejaVuSans.ttf", "saves_dir": "C:/Users/user/source/repos/workstation/renpy-moile/harness/out/saves/game_a", "leaked_store_var": null}
{"game": "B", "sentinel_value": "A", "font": "DejaVuSans.ttf", "saves_dir": "C:/Users/user/source/repos/workstation/renpy-moile/harness/out/saves/game_b", "leaked_store_var": null}
{"game": "A", "sentinel_value": "A", "font": "DejaVuSans.ttf", "saves_dir": "C:/Users/user/source/repos/workstation/renpy-moile/harness/out/saves/game_a", "leaked_store_var": null}
{"game": "B", "sentinel_value": "A", "font": "DejaVuSans.ttf", "saves_dir": "C:/Users/user/source/repos/workstation/renpy-moile/harness/out/saves/game_b", "leaked_store_var": null}
```

`harness/out/rss.jsonl`, verbatim, in full — now real, non-zero readings:

```
{"cycle": 0, "rss_bytes": 135950336}
{"cycle": 1, "rss_bytes": 185401344}
{"cycle": 2, "rss_bytes": 212320256}
{"cycle": 3, "rss_bytes": 234242048}
{"cycle": 4, "rss_bytes": 260939776}
```

In decimal MB (bytes / 1e6, matching `check.py`'s own arithmetic): 136.0 → 185.4 →
212.3 → 234.2 → 260.9 MB across the 5 samples (cycle 0 through cycle 4). `check.py`
compares `measured[1]` (185,401,344 bytes ≈ 185.4 MB, the reading after the first
switch) against `measured[-1]` (260,939,776 bytes ≈ 260.9 MB, the reading after the
fourth): a **40.7% increase** over 4 game switches, against the 30% growth ceiling —
a genuine, measured leak, not a probe artifact.

Interpretation:

- **`sys.modules` contamination, confirmed as predicted, on every A→B switch.** Both
  times game B loaded (cycle 1 and cycle 3), its `sentinel` module import resolved to
  the cached module object from game A's earlier import (both are named `sentinel`
  and `sys.path` was never cleaned between launches), so `sentinel.VALUE` read `"A"`
  instead of `"B"`. This reproduced identically on both A→B transitions, not just the
  first — it is not a one-off startup artifact.
- **Style bleed, on every A→B switch.** Game B's `style.default.font` came back as
  `'DejaVuSans.ttf'` — the value game A's script explicitly set
  (`$ style.default.font = "DejaVuSans.ttf"`) — instead of Ren'Py's default, both
  times. Style state was not reset by `renpy.reload_all()` / the restart loop.
- **Real memory growth, now correctly measured and correctly caught.** Working set
  grew monotonically every single cycle (each switch is a net increase, not just an
  end-to-end comparison): 136.0 → 185.4 → 212.3 → 234.2 → 260.9 MB. This is consistent
  with each switch accumulating rather than releasing per-game state (loaded images,
  cached `.rpyc` bytecode, style objects, etc.) — exactly the class of failure that
  becomes a Jetsam kill on iOS if uncorrected. Task 8's purge layer needs to address
  this, not just the two contamination bugs above.
- **Store variables were *not* contaminated.** `leaked_store_var` is `null` for both
  game B observations, even though game A's script sets `game_a_marker = "leaked"` in
  its store both times. Unlike `sys.modules`, style state, and process memory, the
  Ren'Py store itself does appear to be cleared across the restart. `check.py`'s
  store-leak assertion did not fire.
- **Save directories stayed correctly isolated.** No "games share a save directory"
  or "save dir moved between launches" failure fired across all 4 launches;
  `saves_dir` for game A and game B are distinct, stable paths under
  `VNPLAYER_SAVES_ROOT`, as `main.py:path_to_saves` intends.
- **No traceback file was produced.** `.rig/traceback.txt` (checked before and after
  the run) and `harness/out/**/traceback.txt` do not exist — the engine did not raise
  an unhandled exception at any point in the 4-cycle run.

Bottom line: this is **not** a first-switch crash or hang — the harness ran to
completion, produced full observations and real memory measurements for every
requested cycle, and `check.py` correctly caught three distinct, real bugs:
`sys.modules` caching, unreset style state, and genuine per-switch memory growth.
Task 8's purge layer needs to target all three: module cache eviction, style/state
reset, and releasing per-game resources (images, bytecode, style objects) around the
restart boundary.
