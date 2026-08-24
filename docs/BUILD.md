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

Recorded after running `bash scripts/run_harness.sh 4` (Milestone A, Task 7, second
correction). There is no purge layer yet (Task 8 builds one); a PASS at this step
would have been the surprising result. This section supersedes the two earlier
baselines recorded during this task, both of which turned out to have instrumentation
problems of their own — see "History of this baseline" at the bottom for the full
trail, since Task 8 should understand what changed and why.

**The style-bleed question is currently unanswered — the new canary is broken too.**
See the interpretation below. Do not read either of the earlier baselines as settling
whether style state bleeds between games; neither instrument was trustworthy.

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
FAIL: cycle 0: game A reports text size 22, expected 137 — the style canary itself is broken, so any style-bleed verdict below is meaningless
FAIL: cycle 1: game B read sentinel 'A', expected 'B' — sys.modules contamination
FAIL: cycle 2: game A reports text size 22, expected 137 — the style canary itself is broken, so any style-bleed verdict below is meaningless
FAIL: cycle 3: game B read sentinel 'A', expected 'B' — sys.modules contamination
FAIL: memory grew from 184.3 MB to 260.3 MB over 5 cycles — leak
```

Overall script exit status: **1** (from `check.py`). Engine process exit status:
**0** ("Engine exited cleanly.") — not a crash, hang, or timeout. All five `FAIL:`
lines came from `check.py` inspecting real, complete observations.

Cycles: `harness/out/cycle.txt` contains `5` (4 requested + 1, the same
off-by-one-at-completion behavior as prior runs — the counter increments past the
final launch before `advance()` recognizes it should stop). All 4 requested launches
(A, B, A, B) completed and produced one observation record each.

`harness/out/observations.jsonl`, verbatim, in full:

```
{"game": "A", "sentinel_value": "A", "default_size": 22, "saves_dir": "C:/Users/user/source/repos/workstation/renpy-moile/harness/out/saves/game_a", "leaked_store_var": null}
{"game": "B", "sentinel_value": "A", "default_size": 22, "saves_dir": "C:/Users/user/source/repos/workstation/renpy-moile/harness/out/saves/game_b", "leaked_store_var": null}
{"game": "A", "sentinel_value": "A", "default_size": 22, "saves_dir": "C:/Users/user/source/repos/workstation/renpy-moile/harness/out/saves/game_a", "leaked_store_var": null}
{"game": "B", "sentinel_value": "A", "default_size": 22, "saves_dir": "C:/Users/user/source/repos/workstation/renpy-moile/harness/out/saves/game_b", "leaked_store_var": null}
```

`harness/out/rss.jsonl`, verbatim, in full:

```
{"cycle": 0, "rss_bytes": 135766016}
{"cycle": 1, "rss_bytes": 184299520}
{"cycle": 2, "rss_bytes": 211853312}
{"cycle": 3, "rss_bytes": 233037824}
{"cycle": 4, "rss_bytes": 260317184}
```

In decimal MB (bytes / 1e6): 135.8, 184.3, 211.9, 233.0, 260.3.

No traceback file was produced (`.rig/traceback.txt` and `harness/out/**/traceback.txt`
both checked before and after the run; both absent).

### Interpretation

- **The style-size canary is broken, and this run stops short of a bleed verdict.**
  Game A's own observation reads `default_size: 22` in *both* of its launches (cycle
  0 and cycle 2) — never `137`, despite `script.rpy` setting
  `$ style.default.size = 137` immediately before `observe("A")` runs. `check.py`'s
  new canary-integrity assertion (`game A reports text size 22, expected 137 — the
  style canary itself is broken`) fired both times, exactly as it was designed to.
  This means **the style-bleed question remains unanswered**: game B also reads 22,
  but since game A's own marker never took effect, B reading 22 is uninformative —
  it is equally consistent with "styles reset cleanly" and with "the assignment
  mechanism itself doesn't do what the canary assumes," and this run cannot
  distinguish the two. This is a real, reproducible instrumentation failure (both A
  launches, 100% of the time), not a fluke. The likely mechanism — offered as a
  hypothesis, not a verified fact, since the `Style` class ships compiled in this SDK
  and was not inspected at the source level — is that a runtime property assignment
  on `style.default` is not guaranteed to be visible to an immediate same-statement
  read-back; Ren'Py's style system is known to defer some rebuild work to the next
  screen interaction, and `observe()` runs before any interaction occurs in the
  label. This needs further investigation before a style-based canary can be trusted
  for Task 8.
- **`sys.modules` contamination, still real and reproduced on every A→B switch.**
  Both times game B loaded (cycle 1 and cycle 3), `sentinel.VALUE` read `"A"` instead
  of `"B"` — unaffected by the canary swap, since this check reads a plain Python
  module attribute, not a style property.
- **Real, monotonic memory growth, still real.** 135.8 → 184.3 → 211.9 → 233.0 →
  260.3 MB across the 5 samples — a 41.2% increase from the reading after the first
  switch to the reading after the fourth, against the 30% ceiling. Consistent with
  the previous run's finding within measurement noise.
- **Store variables were still not contaminated**, and **save directories stayed
  correctly isolated** — same as every prior run of this harness.

### Bottom line

Two of the three previously-suspected purge targets remain confirmed and actionable
for Task 8: **`sys.modules` caching** and **per-switch memory growth**. The third —
style state — is **not yet known**, because both style-based canaries built so far
have turned out to be non-discriminating: the font canary, because Ren'Py's own
engine default matches the value the "contaminated" reading would show; the
text-size canary, because the marker assignment itself doesn't reliably reach the
same-statement read-back that would prove it took effect. Task 8 should not assume
style state either bleeds or doesn't; treat it as an open question requiring a
working canary, not a settled finding.

### History of this baseline

This section has been rewritten twice since Task 7 first ran the harness. Recorded
here so Task 8 has the full trail rather than just the current conclusion:

1. **First run** (`bash scripts/run_harness.sh 2`): reported `sys.modules`
   contamination and a "style bleed" via a `style.default.font` check. RSS was not
   measured at all (`GetProcessMemoryInfo` failed silently due to a 64-bit handle
   truncation bug in `_rss_bytes()`), and `check.py` at the time silently skipped the
   memory-growth check when nothing was measured — a false-negative risk.
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
3. **This run** (third, current): replaced the font canary with a text-size canary
   (`style.default.size`, engine default 22, game A sets 137 *before* observing) and
   added the canary-integrity assertion that this write-up is built around. That
   assertion immediately caught that the new canary is *also* not discriminating —
   for a different reason (the marker assignment doesn't take effect in time for
   game A's own read) — which is exactly what the canary-integrity check exists to
   catch. The `sys.modules` and memory-growth findings carried forward unchanged and
   were reconfirmed on this run's own data.
