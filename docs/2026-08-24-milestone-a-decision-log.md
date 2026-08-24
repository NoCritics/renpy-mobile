# SDD ledger — plan: docs/superpowers/plans/2026-08-24-milestone-a-engine-shell.md

Spec: docs/superpowers/specs/2026-08-24-renpy-ios-player-design.md (read, binding authority)
Branch: main (fresh local repo, no remote — user approved local-only until MVP)

## Setup

- `git init` + `git branch -M main` performed by controller during setup, because the
  SDD workspace requires a repo root. This pre-executes Task 1 Step 1; the Task 1
  dispatch will say so.
- Ruling: work proceeds on `main` in a brand-new local repo with no remote. The user
  explicitly asked to "write locally" and approved a plan whose Task 1 initialises
  `main`. Cost if wrong: none — no shared branch exists to disturb.

## Pre-flight conflict scan

### Cross-task rows (pairs sharing a file or interface)

| Pair | Produces → Consumes | Finding |
|---|---|---|
| T1 → T2 | `vendor/renpy-8.5.3-sdk/` → rig source | Clean |
| T2 ↔ T5 | `scripts/make_rig.sh` created by T2, appended by T5 | Clean — T5 gives the exact added lines |
| T3 → T2 | `shell/main.py`, `shell/vnshell/` copied by rig builder | Clean — T2 Step 2 explicitly expects failure until T3 exists |
| T3 → T5 | `shell-project/game/script.rpy` calls `vnshell.lifecycle.tick()` | **Forward reference** — module does not exist until T5. Ruled below |
| T3 → T4 | `main.path_to_saves` reads `vnshell.state.STATE` | Clean |
| T4 → T5 | `Mailbox`, `Command`, `FileTransport`, `NullTransport` | Clean — signatures match usage |
| T5 ↔ T7 | T7 replaces the body of `lifecycle.tick()` | Clean — replacement given verbatim |
| T5 ↔ T8 | T8 replaces `lifecycle.select_next_basedir()` | Clean — different function from T7's edit, no collision |
| T6 → T7 | sentinel games call `vnshell.harness.advance()` | **Forward reference** — same shape as T3→T5. Ruled below |
| T6 → T7 | games write `VNPLAYER_OBSERVATIONS`; `check.py` reads `harness/out/observations.jsonl`; `run_harness.sh` sets the two equal | Clean |
| T7 internal | game records `{"game": "A"|"B"}`; `check.py` branches on exactly those | Clean |
| T7 internal | `harness._games()` returns `<root>/game_a`,`game_b`; `run_harness.sh` sets `VNPLAYER_HARNESS_GAMES=$ROOT/harness/games` | Clean |
| T7 → T8 | `gameId` = basename → `path_to_saves` → distinct dirs → `check.py` set-size assertion | Clean |
| T8 ↔ T6 | `_purge_modules` strips `sys.path` entries under the old root; games `sys.path.insert(0, gamedir)` | Clean — complementary |

### Per-task self-agreement rows

| Task | Own tests vs own code / files created vs later touched | Finding |
|---|---|---|
| T1 | script vs verification steps | Clean |
| T2 | copies files T3 creates; Step 2 states the failure is expected | Clean (acknowledged) |
| T3 | `test_paths.py` asserts `NoGameDirectory`; `main.path_to_gamedir` raises it | Clean |
| T3 | **strict `path_to_gamedir` vs `bootstrap.py:315`** | **DEFECT — ruled below** |
| T4 | mailbox/transport tests vs implementations | Clean. `Command` is `frozen=True` with a `dict` field, so it is unhashable; nothing hashes it |
| T5 | `install()` ordering inside `main.main()` | Clean — `renpy.bootstrap` imported before `install()` patches it |
| T6 | `style.default.font = "DejaVuSans.ttf"` | Clean — Ren'Py ships DejaVuSans.ttf in `renpy/common` |
| T7 | **module-level `_cycle` / `_started` vs `renpy.reload_all()`** | **DEFECT — ruled below** |
| T8 | purge steps vs failures they target | Clean |
| T9 | doc edits vs what earlier tasks changed | Clean |

### Rulings

**Ruling 1 — forward references in T3 and T6 are acceptable as written.**
`shell-project/game/script.rpy` (T3) and the sentinel games (T6) reference modules that
later tasks create. Nothing executes them before those tasks, and the unit tests in T3
import `main` only, whose `lifecycle` import is inside `main()` rather than at module
scope. Implementers are told **not** to create the missing modules early.
Cost if wrong: the repo is briefly in a state where running the rig would fail — caught
immediately at T5 Step 2, which is the first step that runs it.

**Ruling 2 — the rig mirrors iOS by placing the shell project's `game/` at the rig root,
and `STATE.shell_project_dir` becomes `renpy_base`.**
The plan as written is broken here. `bootstrap.py:315` calls `path_to_gamedir(basedir, name)`
*before* the restart loop, with `basedir = args.basedir or renpy_base`. T5 Step 2 launches
`.rig/main.py` with no `--basedir`, so that call gets the rig root — which has no `game/`
— and our deliberately strict `path_to_gamedir` raises, killing the process before the
loop is ever reached.
The fix is the one that is *also* more faithful to the thing the rig exists to mirror. On
iOS, Ren'Py's distributor packages the game into `base/`, so `base/game/` exists and
`base/` is itself a valid base directory. The rig should do the same: copy
`shell-project/game` to `.rig/game` rather than `shell-project/` to `.rig/shell-project/`,
and set `STATE.shell_project_dir = renpy_base`. No `--basedir` argument is then needed on
either platform.
Affects: T2 Step 1 (`make_rig.sh`), T5 Step 1 (`install()`), T5 Steps 2-3 (launch command).
Cost if wrong: small rework confined to `make_rig.sh` and one line of `lifecycle.install`.

**Ruling 3 — harness cycle state is file-backed, not module globals.**
T7 keeps `_cycle` and `_started` as module-level globals in `vnshell.harness`. Game
switching runs `renpy.reload_all()`, and whether that reloads non-Ren'Py modules on
`sys.path` is unverified. If `vnshell.harness` is reloaded, both counters reset and the
harness loops forever instead of terminating — a hang, not a visible failure.
`vnshell.state.STATE` is no safer, being a module global itself. The counter therefore
persists to a file (`$VNPLAYER_RSS_LOG`'s directory, `cycle.txt`), which is immune to
whatever reload semantics turn out to be.
Cost if wrong: a few lines of unnecessary file I/O in test-only code.

---

## Task log

**Ruling 4 — `.gitignore` must also ignore `.superpowers/` and `.remember/`.**
The plan's `.gitignore` omits both. `.superpowers/` is this skill's own scratch workspace
and must never be committed; `.remember/` is unrelated session state that already exists
in the directory. Added by the controller during setup.
Cost if wrong: none.

**Ruling 5 — `.gitattributes` enforces `eol=lf`, and `core.autocrlf` is off.**
Git on Windows defaulted to converting LF to CRLF on checkout. Every `scripts/*.sh` in
this plan is run under Git Bash, and a CRLF shell script fails with
`$'\r': command not found` — a confusing failure that would have burned a fix round on
Task 1. Set up before any script exists.
Cost if wrong: none.

Setup commits: 5a9f44b (docs), 95aa50c (line endings). BASE for Task 1 = 95aa50c.

- Rulings 2 and 3 applied to the plan file itself rather than carried in dispatch prompts,
  so the plan stays the single source of truth. Briefs 5 and 7 regenerated from the
  amended text. Plan amendment left uncommitted until Task 1 reports, to avoid racing
  the running implementer's commit.
- Task 1 dispatched (sonnet). BASE=95aa50c. Brief: task-1-brief.md. Report: task-1-report.md.
- Task 1: implementer DONE. Commit ddcfeff. SDK downloaded, SHA-256 matched pinned hash,
  idempotent second run confirmed. No concerns raised.
- Plan amendment committed separately as 3ead56d (after Task 1's commit, so it stays out
  of Task 1's review diff).
- Task 1: review dispatched (sonnet) over 95aa50c..ddcfeff.
- Task 1: review returned spec ✅ with one Important, plan-mandated finding.

**Ruling 6 — the reviewer is right; `fetch_deps.sh` must survive an interrupted unpack.**
The finding is against my own plan text, so it is mine to rule on. It is correct and well
evidenced: `unzip -q` without `-o` on a partially-extracted tree prompts to overwrite,
reads EOF on non-interactive stdin, treats that as "none", and exits 1 — which `set -e`
converts into a silent abort *before* the script's own diagnostic can fire. Every later
task depends on this script, and a 163 MB unpack is a realistic thing to interrupt.
Fixed in the plan (`rm -rf "$SDK_DIR"` then `unzip -qo`) so plan and code agree, and sent
to the implementer as fix round 1.
Cost if wrong: none — the change is strictly more robust and cannot break a clean run.

- Task 1: minor (deferred): no preflight check that curl/unzip/sha256sum are on PATH;
  a missing tool fails with a raw "command not found". All three confirmed present in
  Git Bash here.
- Task 1: minor (deferred): `scripts/fetch_deps.sh` committed mode 100644, not +x.
  Irrelevant — it is always invoked as `bash scripts/fetch_deps.sh`.
- Task 1: fix round 1/5 — implementer applied the unzip fix, commit f5b1992. Verified by
  deleting bootstrap.py and re-running with stdin closed: exit 0, file restored, and the
  clean no-op path still works. Scoped re-review dispatched over 530b6fb..f5b1992
  (fix base excludes the two controller-only doc commits, which contain no code).

**Ruling 7 — corrected the recorded CPython version from 3.12.8 to 3.12.7.**
I had recorded 3.12.8 in the research doc, spec and plan, taken from renpy-build's `tars/`
listing. The actual 8.5.3 Windows SDK reports `3.12.7`. renpy-build vendors both
`Python-3.12.7-Setup.stdlib` and `Python-3.12.8.tar.xz`, so the tarball list was not
evidence of what shipped. Corrected in all three docs; the plan's Global Constraints now
notes the iOS value must be confirmed in M0 rather than assumed equal.
Cost if wrong: none — nothing depends on the patch version, but the spec is the input to
the iOS plan and should not assert unverified specifics.
Doc commit held until the re-review returns, so HEAD does not move under it.
- Task 1: re-review — finding ADDRESSED, no new breakage, `rm -rf "$SDK_DIR"` verified
  non-broad (unconditional assignment from a literal version + set -u).
- Task 1: complete (commits 95aa50c..f5b1992, review clean, 2 minors deferred).
- Task 2: implementer DONE. Commit 05e1612. Script behaved exactly as designed: SDK copied,
  overlay stage failed loudly on the not-yet-existing shell/main.py; second run skipped the
  SDK copy. No stubs or guards added to mask the failure. Review dispatched over 04548f8..05e1612.
- Task 2: review — spec ✅, task quality Approved, no Critical/Important.
- Task 2: minor (deferred): `.rig/` staleness across SDK version bumps — the SDK copy is
  gated only on `.rig/renpy/bootstrap.py` existing, with no version stamp. A future Ren'Py
  bump would silently reuse a stale rig unless `.rig/` is deleted by hand. Plan-mandated,
  forward-looking note for whoever does the next SDK bump.
- Task 2: complete (commits 04548f8..05e1612, review clean, 1 minor deferred).

**Ruling 8 — removed a stray empty say statement from the shell project's script.**
Task 3's `shell-project/game/script.rpy` as I first wrote it had `""` on its own line in
`label start`, with a comment claiming it was a placeholder. An empty say statement is a
real Ren'Py statement: it renders an empty dialogue box and blocks waiting for a click.
On iOS at cold launch that means the shell project would sit waiting for a tap before ever
reaching its idle loop — with the native library window covering the screen, the user
would see nothing to tap. Removed; the comment now explains why `renpy.pause(hard=True)`
is the right idle primitive. Brief 3 regenerated.
Cost if wrong: none — removing it strictly reduces behaviour.

**Ruling 9 — unit tests run on a SYSTEM Python, not the Ren'Py SDK's; the vendor tree is
restored to pristine.**
Task 3's implementer hit a real plan defect and worked around it unsafely. The defect is
mine: I specified the SDK's bundled interpreter as the test runner, but Ren'Py ships a
stripped, `.pyc`-only stdlib with **no `unittest` module at all** (verified: its
`lib/python3.12/` holds only `.pyc` files and no `unittest`). The implementer bridged the
gap by copying a Python **3.11** `unittest` package into the **3.12** SDK tree.

That workaround must be reverted, for three independent reasons:
1. It mixes a 3.11 stdlib package into a 3.12 interpreter.
2. It mutates `vendor/`, which is SHA-256-verified and, by our own Global Constraint,
   never modified.
3. Ruling 6 gave `fetch_deps.sh` an `rm -rf "$SDK_DIR"` on repair — so the first time
   anyone repairs the SDK, the hack vanishes and tests break mysteriously.

The real fix: nothing under test imports Ren'Py at module scope, so the suite never needed
the SDK interpreter. This machine has CPython 3.14.4 and 3.11.9 on PATH. Added
`scripts/run_tests.sh`, which probes for a usable 3.10+ interpreter (rejecting Windows'
`python3` Microsoft-Store shim, which exits non-zero) and fails with a clear message if
none exists. Plan amended: Global Constraints now state the two-interpreter split
explicitly and forbid installing into `vendor/`; Task 3 gains a step for the wrapper;
all four test-command references updated; Task 3 steps renumbered; briefs 3 and 4
regenerated.
Cost if wrong: tests execute on 3.14 while the runtime is 3.12. The code under test is
path/dict logic with no version-sensitive behaviour, so the drift is acceptable — but if a
3.12-specific bug ever slips through, this is where it came from.
- Task 3: implementer DONE after fix. Commits cae5af3, e5e784d. Vendor tree restored via
  the Task 1 repair path (rm -rf + re-unpack from cached zip) and confirmed pristine.
  Controller independently verified: no unittest dir in vendor, `bash scripts/run_tests.sh`
  → 3/3 OK. Full task review dispatched over c0c6abc..e5e784d (Task 3 had no prior review;
  the vendor concern was adjudicated pre-review, not by a reviewer).
- Task 3: review — spec ✅, task quality Approved, no Critical/Important.
- Task 3: minor (deferred): `path_to_saves` fallback to `<gamedir>/saves` is safe (each
  import has a distinct basedir, so no collision), BUT if it is ever reached for an
  *identified* game while `STATE.saves_root` is still empty, it silently masks an
  init-order bug instead of surfacing it. **Carry this into the Task 5 dispatch** — Task 5
  is what wires STATE.
- Task 3: minor (deferred): scripts are tracked at git mode 100644 despite local +x; a
  Windows core.fileMode artifact, no functional effect since scripts run via `bash`.
- Task 3: complete (commits c0c6abc..e5e784d, review clean, 2 minors deferred).
- Task 4: implementer DONE first pass. Commit 7277da3. 11/11 green, verified by controller.
- Task 4: review — spec ✅, quality "Approved", but TWO Important findings, both
  plan-mandated. Approved-with-Importants still enters the fix loop.

**Ruling 10 — both Important findings are correct; the "never raises" guarantee was
half-implemented in my plan's reference code. Fixing rather than parking.**
(a) `Mailbox.poll()` wrapped only `transport.receive()` in its try. The per-entry loop ran
unguarded, so a transport returning a list containing a non-dict raises `AttributeError`
straight out of `poll()` — precisely the "broken transport kills a running game" failure
the module exists to prevent. Unreachable today only because both shipped transports
happen to return well-formed data; Task 5 wires a live one, and the iOS bridge will
deserialize data we do not control.
(b) It swallowed everything silently with no record anywhere. A permanently dead command
channel would present to the user as "the buttons do nothing" with no diagnostic trail.
Fix: per-entry defensive conversion so one bad entry cannot discard good ones beside it,
plus a `_report()` that prints once per distinct message — deduplicated because `poll()`
runs every frame and an unconditional print would emit ~60 lines/sec while a fault lasts.
On iOS, Ren'Py's iossupport module already routes stdout to the system log.
Two new tests (report-once, non-dict-tolerance) take the suite 11 → 13; the existing
swallow test now captures stdout so output stays pristine.
Cost if wrong: a small amount of extra code in a hot path (one string compare per fault,
none on the happy path).

- Task 4: minor (deferred): `FileTransport.receive()` read-then-delete is non-atomic; a
  write landing between the two syscalls is lost. Accepted — desktop harness is
  single-writer, and the iOS transport is not file-based. Revisit only if Task 7's harness
  writes concurrently with polling.
- Task 4: minor (deferred): report did not state the test interpreter choice was
  deliberate (3.14.4 satisfies 3.10+, and is correctly not the SDK's 3.12.7).
- Task 4: fix round 1/5 — both Important findings ADDRESSED, no new breakage (re-review).

**Ruling 11 — closing a hole the re-review found in my own fix. Fix round 2.**
The re-reviewer verdicted both findings addressed but noted a real gap: `_report()` dedups
only against the immediately-previous message, and the per-entry message embeds `{entry!r}`.
So a transport feeding back a *different* malformed payload each frame produces a different
message each frame and is not throttled at all — restoring the exact 60-lines-per-second
problem `_report` exists to prevent. It called this non-blocking, and it is; but leaving a
known spam path inside the anti-spam mechanism is not a good place to stop.
Fix: keep consecutive-duplicate suppression for the common deterministic case, and add an
absolute `REPORT_LIMIT = 20` per Mailbox with a final "further faults suppressed" line.
The cap covers varied faults, alternating faults, and varieties we have not thought of.
One new test drives 60 distinct malformed payloads and asserts output stops at the cap.
Suite 13 → 14.
Cost if wrong: after 20 distinct faults a Mailbox stops reporting for the process lifetime.
Acceptable — by then the channel is comprehensively broken and the first 20 lines say so.
- Task 4: fix round 2/5 — finding ADDRESSED, no new breakage. Re-reviewer independently
  traced the 19+2=21 arithmetic rather than trusting the assertion, and confirmed the
  `_last_report`-before-cap-check ordering is behaviourally identical to the reverse.
- Task 4: complete (commits 810356a..d4be3c6, review clean, 2 minors deferred).
- Task 4 → Task 5 handoff note (from re-review): `_reports_emitted` is per-Mailbox
  instance, and `lifecycle.install()` reassigns the `MAILBOX` singleton — so the cap is
  "20 per install", not "20 per process". Fine if install() runs once; a latent surprise
  if it can run again while the process lives. **Carried into the Task 5 dispatch.**

**Ruling 12 — Task 5's verification had to become headless-checkable.**
My plan said "a Ren'Py window opens showing a black screen and stays open. Close it."
A subagent cannot see a window or close one, and neither can CI. The step was unrunnable
as written and would have produced either a hang or a fabricated confirmation.
Replaced with: `timeout 25` around the launch (exit 124 = stayed up = success), plus
assertions on `.rig/log.txt` for Ren'Py's startup banner and on the *absence* of
`.rig/traceback.txt`. Both diagnostic cases are named in the plan so a failure is
self-explaining: `NoGameDirectory` means the game/ copy did not land, anything mentioning
`vnshell` means the shell layer is broken.
Cost if wrong: none — strictly more verifiable than what it replaced, and it is the same
check CI will need later.
- Task 5: implementer DONE. Commit eeff2b5. **Ren'Py boots for the first time.** Controller
  independently confirmed: exit 124 (stayed up), no traceback.txt, log.txt shows
  "Ren'Py 8.5.3.26051504", gl2 renderer initialized, `_start` ran, interface started.
  The get_alternate_base monkey-patch is live and strict path_to_gamedir accepted .rig/game.
  Suite still 14/14. Review dispatched over b3b1df8..eeff2b5.
- Task 5: implementer confirmed `install()` runs once per process — the bootstrap restart
  loop lives inside `bootstrap()` and never re-enters `main()` — so the Task 4 mailbox
  cap-reset concern does not trigger. Closed, no code change.
- Task 5: review — spec ✅, task quality Approved, no Critical/Important.
- Task 5: **load-bearing fact worth carrying to the iOS plan** (found by the reviewer, not
  by design): `renpy/__init__.py` does `from renpy.bootstrap import get_alternate_base`
  inside `import_all()`, which runs *after* `lifecycle.install()`. So our monkey-patch
  propagates to `renpy.get_alternate_base` too — including the auto-updater's
  `always=True` call site in `renpy/common/00updater.rpy`. Correct, but by ordering rather
  than by intent. If `install()` ever moves later, the patch silently stops applying there.
- Task 5: minors (deferred, all in lifecycle.py — **fold into Task 8's dispatch**, which
  edits that same file): (a) `_installed` is assigned but never read — dead state implying
  a double-install guard that does not exist; (b) the "never cleans up" docstring
  overstates purity, since the fallback branch calls `reset_for_shell()`; (c) a command
  batch is abandoned when a handler raises UtterRestartException — harmless while both
  handlers restart, a real bug once non-restarting handlers land; (d) `always` is accepted
  for signature compatibility but unused, undocumented.
- Task 5: complete (commits b3b1df8..eeff2b5, review clean, 4 minors deferred).

**Ruling 13 — rewrote the sentinel asset generator to build rows, not pixels.**
My `scripts/make_assets.py` looped over 2048x2048 = 4.2 million pixels in pure Python,
allocating a `bytes` object per pixel. That takes minutes and presents as a hang, which an
implementer would reasonably interpret as a broken step. The image exists solely for
texture-cache pressure — 2048x2048 RGBA is ~16 MB decoded whatever it depicts — so a
solid colour per row gives identical memory behaviour in ~2048 iterations.
Cost if wrong: none. The image's content is irrelevant to every assertion the harness makes.
- Task 6: implementer DONE_WITH_CONCERNS. Commit c8e4933. Both concerns correct, both mine.

**Ruling 14 — `.gitignore` must cover the generated per-game image copies.**
The implementer found that `harness/games/*/game/big.png` is not ignored, so the brief's
own Step 6 (`git add harness/games`) would have committed two generated binaries. They
avoided it by staging explicitly and flagged it rather than committing — the right call.
Left unfixed, the next `git add -A` anywhere in this repo silently commits generated
binaries, and the whole point of a generator is that its output is not source.
Fixed in the plan's `.gitignore` block; Task 6's implementer applies it now rather than
deferring, since the exposure exists the moment the files do.
Cost if wrong: none.

**Ruling 15 — corrected the plan's stated PNG size.**
I predicted 1-3 MB; the real file is ~92 KB, because Ruling 13's solid-colour rows
compress far better than the per-pixel pattern they replaced. The prediction was wrong,
not the output. Corrected, with a note that the *decoded* size (~16 MB of RGBA texture) is
the number that matters and is unchanged — that is the only reason the image exists.
Cost if wrong: none — documentation accuracy only.
- Task 6: review — spec ✅, Approved, no Critical/Important. Canaries confirmed intact:
  differing sentinel VALUEs, identical save_directory, asymmetric font/store writes, and a
  correctly hand-rolled PNG (IHDR/IDAT/IEND, per-scanline filter byte, CRC over tag+data).
- Task 6: minor (deferred → **carry into Task 8**): `sys.path.insert(0, gamedir)` runs on
  every `observe()` with no removal, so sys.path grows across cycles. The purge design
  already strips sys.path entries under the previous basedir; this confirms that half of
  the purge is needed, not just the sys.modules half.
- Task 6: minor (deferred): `import shutil` mid-function in make_assets.py (brief-mandated).
- Task 6: complete (commits 67afed5..f35a0aa, review clean, 2 minors deferred).

**Ruling 16 — `run_harness.sh` needs a timeout, because hanging is a likely result.**
My script invoked the engine unbounded. But one of the specific failures this harness
exists to detect is "the UtterRestart never fires and the engine idles forever" — and
without a bound that outcome hangs the run rather than reporting it, which is the worst
possible way to learn it. Added `timeout $((CYCLES * 5 + 60))`, an explicit exit-124
branch explaining what a timeout means and where to look, and made `check.py` run
regardless of engine status — a partial run's observations are exactly the evidence needed
to see how far cycling got before it broke.
Cost if wrong: a very slow machine could time out on a legitimate 100-cycle run. The
message names the cause, and the budget is generous at 5s/cycle.

## MILESTONE A CORE RESULT (Task 7, first harness run)

**In-process game switching WORKS.** Engine exit 0, no crash, no hang, no timeout, no
traceback. Game A ran, `UtterRestartException` propagated out of the periodic callback,
`reload_all()` ran, and game B loaded — 3 cycles recorded for a 2-cycle request.
The spec's fallback (one game per app launch) is NOT needed.

Observed contamination, exactly as both external models predicted:
- `sys.modules` leak: game B read `sentinel_value: "A"` instead of `"B"`.
- Style bleed: game B's font is `DejaVuSans.ttf`, which only game A ever sets.

Observed CLEAN:
- Store isolation: `leaked_store_var: null` in B.
- **Save isolation works.** Both games declare the identical
  `config.save_directory = "sentinel-shared-name"`, yet wrote to
  `harness/out/saves/game_a` and `.../game_b` respectively. Task 3's `path_to_saves`
  override does its job — the crossover trap was sprung and held.

**Ruling 17 — the RSS probe was broken, and `check.py` would have silently passed anyway.**
The implementer flagged RSS reading 0 for every cycle. Diagnosed it directly: my
`_rss_bytes()` called `ctypes.windll.kernel32.GetCurrentProcess()` with ctypes' default
`restype=c_int`, which truncates the 64-bit pseudo-handle, so `GetProcessMemoryInfo`
failed and returned 0. Declaring `restype`/`argtypes` and preferring
`K32GetProcessMemoryInfo` makes it work — verified live: 18.2 MB.
Worse than the broken probe was `check.py`: it filtered to `rss_bytes > 0` and required
four samples, so an entirely unmeasured run *skipped* the memory check and reported PASS.
A memory check that passes without measuring anything is a lie, and memory growth is the
one failure that survives to iOS as a Jetsam kill. It now fails loudly when nothing was
measured.
Also fixed a latent unit bug in the POSIX fallback: `ru_maxrss` is bytes on macOS/iOS and
kilobytes on Linux; the code multiplied by 1024 unconditionally, which would have made
every iOS-simulator reading 1024x too large.
Cost if wrong: a run on a platform where RSS genuinely cannot be read now fails instead of
passing. That is the intended direction — it demands an explicit decision rather than
quietly dropping the check.

**Ruling 18 — the style-bleed canary was non-discriminating. Replaced. (Task 7 fix round 1)**
The best finding of this whole run, and it invalidates one of the three failures I reported
in the ledger above. Verified against the SDK directly:
- `renpy/common/00style.rpy:139` sets `font "DejaVuSans.ttf"` as Ren'Py's engine-wide
  default for **every** game.
- `harness/games/game_a/game/script.rpy:23` calls `observe("A")` *before* line 24 sets the
  font — so A's own record already reads DejaVuSans.ttf without the set doing anything.
Therefore game B reading `"DejaVuSans.ttf"` proves nothing: a perfectly clean reset
produces the identical value. The check could never pass, and Task 8 would have chased it
indefinitely — or worse, "fixed" it in a way that broke something real.
The `sys.modules` and memory findings are unaffected: `sentinel.VALUE`, `game_a_marker`
and monotonic RSS are genuinely discriminating markers. **The style-bleed line in the
BUILD.md baseline must not be treated as evidence of a real defect until re-measured.**

Replacement canary: text size, not font. Engine default is 22 (00style.rpy:142); game A
sets 137 **before** observing, so A's own record proves the marker took effect. check.py
now asserts both halves — A must read 137 (else the instrument is broken and any bleed
verdict is meaningless) and B must read 22. The canary-integrity half is exactly the
assertion whose absence let this bug survive.
Also removed the dead `EXPECTED` constant the reviewer flagged.
Cost if wrong: if 137 collides with something, A's self-check fails loudly rather than
silently mis-reporting — which is the whole point of adding it.

- Task 7: minor (deferred): check.py's "cycle N" is a 0-based launch index while
  cycle.txt is a running counter, so the two "cycle" numbers mean different things.

**Ruling 19 — third canary design. Style mutation abandoned in favour of config.name.
(Task 7 fix round 2)**
The text-size canary failed too: game A set 137 and read back 22. The canary-integrity
assertion added in Ruling 18 caught it immediately — which is the entire reason it exists,
and is the difference between "two rounds spent" and "Task 8 built on a lie".
Root cause found in the SDK docs: mutating a style outside an `init` block requires
`style.rebuild()` to take effect. My fixture set the property and never rebuilt, so the
read-back returned the built default.
I am not spending a third round on Ren'Py style-mutation mechanics. The underlying question
worth answering is "does per-game init state survive a switch?", and `config.name` answers
it using state each game already declares — no special API, no rebuild ceremony, and
self-validating (A must read "Sentinel A"). Both prior designs are documented in the
fixture comments so nobody re-treads them.
**Style bleed specifically remains UNTESTED**, and Task 8 must be told so rather than
inferring it is clean. The `style.rebuild()` requirement is the lead for anyone who wants
to test it properly later.
Cost if wrong: config.name may prove trivially clean, making the canary uninformative
rather than wrong. That is still useful — it tells Task 8 one vector needs no purging.
- Task 7: fix round 2/5 — finding ADDRESSED. Re-reviewer confirmed the config.name canary
  is structurally different from both failed designs (distinct game-owned literals, no
  shared engine baseline, declarative not runtime-mutated), self-validated on the real run,
  and left no dead residue or schema mismatch between the two games' observation keys.
- Task 7: complete (commits cd50478..e0aec28, review clean, 1 minor deferred).
- Task 7 → Task 9 note (from re-review, out of scope there): the SPEC still describes the
  style canary as `style.default.font` (spec §"Testing"/10.1). Task 9 updates the spec and
  must correct this too.

## HARNESS BASELINE HANDED TO TASK 8

| Vector | Result |
|---|---|
| In-process switching | WORKS — exit 0, no crash/hang/timeout |
| Save isolation | CLEAN (identical config.save_directory, separate dirs) |
| Store variables | CLEAN |
| Per-game init state (config.name) | CLEAN |
| `sys.modules` | LEAKS — game B reads game A's sentinel, both A→B switches |
| Memory | LEAKS — 184.7 → 261.3 MB, +41.5% over 5 cycles (limit 30%) |
| Mutable style state | **UNTESTED** — not clean. Needs `style.rebuild()` to test properly |

## TASK 8 FIRST RESULT

**Contamination: FIXED.** 100 launches, zero sentinel mismatches, zero config.name
mismatches, zero store leaks. Controller-verified from observations.jsonl.

**Memory: NOT fixed.** 136 MB → 2360 MB over 100 cycles. Mean 22.2 MB/switch, median 21.7,
and the last five deltas are still 17-27 MB — perfectly linear, no plateau.
At ~22 MB/switch a phone that Jetsams near 1.4 GB dies after roughly 55 switches with
these tiny synthetic games; real VNs with real assets would manage far fewer.

**Ruling 20 — the purge was running at the wrong time. My error, and it is architectural.**
`purge_engine_state` is called from `select_next_basedir`, which bootstrap invokes *after*
`renpy.reload_all()`. By then the engine's module objects have been replaced, so every
teardown call operates on freshly-constructed objects while the outgoing game's GL
surfaces, audio buffers and font caches sit orphaned — unreachable from Python and never
freed. That fully explains why five candidate cleanup steps measured no effect: they were
all cleaning the wrong objects.
The correct hook is `lifecycle._restart()`, *before* `UtterRestartException` is raised,
while the live engine still owns its resources. Added `purge.teardown_live_engine()` making
the same calls bootstrap's own `finally` makes at process exit (bootstrap.py:409-419) —
`im.cache.quit()`, `draw.quit()`, `audio.audio.quit()`, plus font free — the difference
being that we make them per switch, which is precisely what that `finally` sitting outside
the restart loop fails to do.
Risk: calling `draw.quit()` mid-session and expecting `main()` to re-init the renderer may
crash. That is exactly what the harness exists to find out, and a crash would itself be a
decisive finding.
Cost if wrong: one more harness round. If the leak is genuinely native and survives this,
the answer is a switch cap on iOS — and we will know it is a real constraint rather than
an artefact of cleaning at the wrong moment.

- Task 8: implementer also found and fixed a real bug in my brief's purge scope: the shell
  project's basedir IS the SDK root, so a whole-basedir module purge would have wiped the
  interpreter's own modules on the first switch. Good catch, documented in their report.

## MILESTONE A FINAL RESULT (Task 8, both hook points tested)

Ruling 20's hypothesis was correct to test and WRONG as a fix — which is itself the finding.
Pre-restart teardown survives completely: all six calls ran on all 100 switches (600 log
lines), `draw.quit()` mid-session included, no crash. And the leak did not move:
22.2 MB/switch before, 21.9 after — within run-to-run noise. First-10 mean 26.0 MB,
last-10 21.2 MB: no decay, no plateau.

**Conclusion, established by experiment rather than assumption: the leak is native —
inside Ren'Py's own C/GL/SDL layer — and unreachable from the shell at either hook point.**
Fixing it would mean modifying `renpy/`, which the spec forbids and which would forfeit
the "stock engine, one seam" property the whole design rests on.

Practical ceiling: from a ~200 MB start, ~54 switches before a 1.4 GB Jetsam kill, using
tiny synthetic games. Real VNs would reach it sooner.
- Task 8: review — spec ❌ on one real bug, Approved overall, two Important findings.

**Ruling 21 — the sys.path filter's missing boundary guard is a real bug. Fixing.**
`_purge_modules` guards the module filter with `root + os.sep` but the sys.path filter
used a bare `startswith(root)`. With `root = <basedir>/game`, a sibling like
`<basedir>/game_assets` or `<basedir>/gamelib` prefix-matches and would be wrongly stripped
from sys.path on every switch. Invisible to the harness because both sentinel games use
the literal name `game`. Real games do ship sibling directories. Fixed in the plan with a
`_under_root` helper mirroring the module filter exactly.
Cost if wrong: none — strictly narrows what gets stripped.

**Ruling 22 — `teardown_live_engine()`'s six steps STAY, with an honest justification
recorded. The reviewer was right to flag them and right to leave the call to me.**
By the letter of the method I mandated, these steps have no measured justification: they
run every switch and demonstrably do not move RSS (22.2 → 21.9 MB/switch, within noise).
The method exists to keep *speculative* cleanup out of a hot path, and I still think that
rule is correct.
But these are not speculative in the sense the rule targets. They are Ren'Py's own
documented process-exit teardown sequence (bootstrap.py:409-419), and we have measured
that they execute safely 600 times including `draw.quit()` mid-session. What we measured is
narrower than "they do nothing": we measured that they do not reduce **RSS on Windows with
an NVIDIA GL driver**. RSS does not capture driver-side allocations, and iOS runs a
completely different graphics stack (MetalANGLE over Metal) where that measurement simply
does not transfer.
So they stay, and the justification is written down as exactly that — safe, mirrors the
engine's own shutdown, ineffective on Windows RSS, retained because the iOS graphics stack
is different and must be re-measured rather than assumed. The iOS plan is instructed to
re-measure. Recording a step as "kept on an untransferred measurement" is honest; deleting
it and silently re-deriving the need later is not.
Cost if wrong: six no-op calls per switch, microseconds each, in a path that already tears
down an entire game.

- Task 8: minor (deferred → folded into this fix round since it is one line): the lambda in
  `purge_engine_state`'s step table logs as `<lambda>` on failure rather than naming
  `_purge_modules`.
- Task 8: fix round 1/5 — all three findings ADDRESSED, no new breakage. Re-reviewer
  verified `_under_root` handles both boundary cases and that the teardown docstring does
  NOT overclaim iOS effectiveness (only that the Windows RSS-null result does not transfer).
- Task 8: complete (commits e0aec28..2d480a3, review clean, 2 minors deferred).
- Task 9: implementer DONE. Commit 6681cc6. Spec §5.2/5.3/5.4/6/8/10.1/13/14 updated.
  The two "extra" risk-table notes it flagged as possible scope creep were explicitly
  requested in my dispatch's "also worth capturing" section — not scope creep.
  Review dispatched over 2d480a3..6681cc6.
- Task 9: review — spec ✅, Approved, no Critical/Important. Reviewer read the whole spec
  end-to-end and spot-checked every figure against BUILD.md verbatim; found no over-claim,
  and confirmed the memory finding is stated at three points a reader would land on rather
  than buried in the risk table.
- Task 9: minor (deferred → **for final review triage**): spec §8 carries forward only the
  first purge-scoping bug (whole-basedir purge wiping the interpreter's modules), not the
  second (sys.path filter missing the directory-boundary guard, which would wrongly strip a
  sibling like `game_assets/`). A fresh iOS implementer re-deriving this logic could
  reproduce it. Real transferable lesson, worth adding.
- Task 9: minor (deferred): spec §238 says "the SDK/app root" — compresses two different
  roots (rig = SDK root, iOS = app bundle root) into one phrase.
- Task 9: complete (commits 2d480a3..6681cc6, review clean, 2 minors deferred).

## ALL NINE TASKS COMPLETE. Final whole-branch review next.

## FINAL WHOLE-BRANCH REVIEW — "Needs fixes before building on"

No Critical. Ren'Py source untouched, no third-party deps, LF throughout, MIT, 14 tests.

**Ruling 23 — the sys.path purge is dead code, and Ruling 21 fixed a bug in it that could
never fire. Correcting the record rather than the code.**
Verified against the pinned SDK: `get_alternate_base` is called at bootstrap.py:379, and
bootstrap.py:387 does `sys.path = list(original_sys_path)` unconditionally eight lines
later, in the same try, with no import in between. Our filter therefore has no observable
effect on any path. Ruling 21's boundary-guard fix was correct in itself and fixed nothing
real. The filter is harmless and stays; what changes is the record — BUILD.md and spec §8
list the sys.path strip under **Necessary**, which would send the iOS implementer to
re-derive the same subtlety for zero benefit while the load-bearing fact (bootstrap resets
sys.path every pass, so only sys.modules needs purging) goes unrecorded.
Cost if wrong: none — documentation accuracy.

**Ruling 24 — the spec does not describe what shipped. Highest-impact finding of the run.**
Spec §5.2/§5.3 name the package `base/shell/` and show `import shell.lifecycle`; what
shipped is `vnshell`, so that import raises ModuleNotFoundError on iOS. Spec §5.3 also says
`base/launcher-shell/` is the cold-launch basedir, which the implementation deliberately
contradicts (game/ sits at renpy_base because bootstrap.py:334 calls path_to_gamedir before
the loop). And §5.2's code block omits `lifecycle.install()`, without which there is no
mailbox and no save isolation. The spec is the sole input to the iOS phase; this is the
single most likely thing to break the port.

**Ruling 25 — "mirrors bootstrap's own finally" is half true.** Verified: the finally
(bootstrap.py:427+) contains `im.cache.quit()`, `draw.quit()` (guarded by
`if renpy.display.draw:`), `audio.audio.quit()`. The three stop/font calls are ours. Since
Ruling 22 retained all six *on the strength of that claim*, the claim has to be accurate:
three are engine-authored, three are ours.

**Ruling 26 — `ru_maxrss` is PEAK RSS, so the iOS re-measurement would fail as an
instrument.** It can never decrease, so an iOS run measuring whether teardown helps reads
monotonic regardless of the truth. Three canary designs already failed as instruments in
this milestone; specifying a fourth would be careless. The iOS harness must use
`task_info(TASK_VM_INFO).phys_footprint` — which is also what Jetsam actually meters.

- Also fixing: check.py's save-isolation assertions reduce to `"game_a" != "game_b"` and
  cannot fail (the real evidence is on disk, unchecked); `_purge_modules` and `_rss_bytes`
  have no unit tests despite being the only two functions with a history of shipped bugs;
  bootstrap.py line citations carry a consistent ~18-line offset; the research doc asserts
  3.12.7 for renios, which the spec says must not be assumed; check.py:81 still silently
  PASSes runs shorter than 4 samples — the same false-negative shape §70-80 exists to kill.
