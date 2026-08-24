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

Recorded after running `bash scripts/run_harness.sh 2` (Milestone A, Task 7). This is
the **expected first failure** — there is no purge layer yet (Task 8 builds one), and
this run's output is exactly the evidence Task 8 is derived from. A PASS at this step
would have been the surprising result.

Command and outcome:

```
$ bash scripts/run_harness.sh 2
Applying shell overlay...
Rig ready at /c/Users/user/source/repos/workstation/renpy-moile/.rig
Running 2 cycles (timeout 70s)...
Resetting cache.
Resetting cache.
Engine exited cleanly.
FAIL: cycle 1: game B read sentinel 'A', expected 'B' — sys.modules contamination
FAIL: cycle 1: game B inherited game A's font 'DejaVuSans.ttf' — style bleed
```

Overall script exit status: **1** (non-zero, from `check.py`). The engine process
itself exited **cleanly with status 0** — it ran the full requested cycle count and
called `sys.exit(0)` from `vnshell.harness.advance()` once `cycle > _total_cycles()`.
The failure is not a crash or a hang: the engine ran to completion and the two
`FAIL:` lines above came from `check.py` inspecting the resulting observations.

Cycles: `harness/out/cycle.txt` contains `3` after the run (2 requested + 1, since the
counter is incremented past the last real launch before the run recognizes it should
stop and exits). Both of the 2 requested game launches (game_a then game_b) completed
and each produced one observation record — the run did not stop early.

`harness/out/observations.jsonl`, verbatim (2 lines, one per cycle):

```
{"game": "A", "sentinel_value": "A", "font": "DejaVuSans.ttf", "saves_dir": "C:/Users/user/source/repos/workstation/renpy-moile/harness/out/saves/game_a", "leaked_store_var": null}
{"game": "B", "sentinel_value": "A", "font": "DejaVuSans.ttf", "saves_dir": "C:/Users/user/source/repos/workstation/renpy-moile/harness/out/saves/game_b", "leaked_store_var": null}
```

Interpretation:

- **`sys.modules` contamination, confirmed as predicted.** Game B's `sentinel` module
  import resolved to the cached module object from game A's earlier import (both are
  named `sentinel` and `sys.path` was never cleaned between launches), so
  `sentinel.VALUE` read `"A"` instead of `"B"`. Both AI reviewers who predicted this
  ahead of time were right.
- **Style bleed, a second and distinct failure.** Game B's `style.default.font` came
  back as `'DejaVuSans.ttf'` — the value game A's script explicitly set
  (`$ style.default.font = "DejaVuSans.ttf"`) — instead of Ren'Py's default. Style
  state was not reset by `renpy.reload_all()` / the restart loop either.
- **Store variables were *not* contaminated.** `leaked_store_var` is `null` for game
  B, even though game A's script set `game_a_marker = "leaked"` in its store. Unlike
  `sys.modules` and style state, the Ren'Py store itself does appear to be cleared
  across the restart. `check.py`'s store-leak assertion did not fire.
- **Save directories stayed correctly isolated.** No "games share a save directory"
  or "save dir moved between launches" failure fired; `saves_dir` for game A and game
  B are distinct paths under `VNPLAYER_SAVES_ROOT`, as `main.py:path_to_saves` intends.
- **No traceback file was produced.** `.rig/traceback.txt` (checked before and after
  the run) and `harness/out/**/traceback.txt` do not exist — the engine did not raise
  an unhandled exception at any point in the 2-cycle run.
- **RSS was not measured on this run.** Every entry in `harness/out/rss.jsonl` has
  `rss_bytes: 0`:
  ```
  {"cycle": 0, "rss_bytes": 0}
  {"cycle": 1, "rss_bytes": 0}
  {"cycle": 2, "rss_bytes": 0}
  ```
  `GetProcessMemoryInfo` returned a falsy/failing result under the SDK's bundled
  Windows Python in this environment, so `_rss_bytes()` fell back to its documented
  "not measured" value (0) rather than failing the run. `check.py`'s leak check only
  evaluates when at least 4 non-zero measurements exist, so it did not fire here —
  it is inconclusive, not passing. This is worth revisiting but is out of scope for
  Task 7/8: the harness's contract is "0 means not measured", and it honored that.

Bottom line: this is **not** a first-switch crash or hang — the harness ran to
completion, produced full observations for every requested cycle, and `check.py`
correctly caught two distinct, real contamination bugs (`sys.modules` caching and
unreset style state) exactly where Task 8's purge layer needs to target: module
cache eviction and style/exception-state reset around the restart boundary.
