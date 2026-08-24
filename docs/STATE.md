# Project state — resume here

Last updated: 2026-08-24, after Milestone A.

## What this is

A free, open-source iOS player for Ren'Py 8 visual novels. No ads, no purchases, no time
limits. Built for one specific reader (computer-competent, not a developer); public so
anyone can build or fork it.

Repo: https://github.com/NoCritics/renpy-mobile (public — this matters: macOS CI runners
are free and unlimited on public repos, and bill at 10x on private ones).
Local: `C:\Users\user\source\repos\workstation\renpy-moile`, branch `main`, remote `origin`.

## Read these, in this order

1. `docs/superpowers/specs/2026-08-24-renpy-ios-player-design.md` — the design. **The
   authority.** Rewritten after Milestone A so it records measurements, not hypotheses.
2. `docs/BUILD.md` — the measured record. Authoritative for every figure. Where it and
   the spec disagree, BUILD.md wins; it was written from real runs.
3. `docs/2026-08-24-milestone-a-decision-log.md` — 26 rulings made during Milestone A,
   each with what it costs if wrong. Several correct earlier mistakes; read before
   re-deriving anything.
4. `docs/2026-08-24-research-renpy-ios-player.md` — market and licensing research.

## Status

**Milestone A — COMPLETE, pushed.** The Python engine layer (`shell/main.py`,
`shell/vnshell/*`) that the iOS app embeds unchanged. 19/19 tests via
`bash scripts/run_tests.sh`. Ren'Py's own source is never modified; the entire
customization is one monkey-patch plus a `renpy.__main__` replacement.

Proven over 200 launches: in-process game switching works; `sys.modules` contamination
fixed; save isolation holds even when two games declare an identical
`config.save_directory`; store variables and per-game init state clean.

**Not proven:** mutable style state (three canary designs failed as *instruments*, not as
negative results — see BUILD.md).

**Known constraint:** memory leaks ~22 MB per game switch, linearly, no plateau. Native,
inside Ren'Py's C/GL/SDL layer, unreachable from the shell at either available hook point.
~54 switches from a 200 MB baseline before a 1.4 GB Jetsam ceiling, using tiny synthetic
games. **Decided mitigation: watch and warn** — track memory, surface a dismissible
restart suggestion; deliberately not a hard switch cap. Recorded in spec §14.

**Milestone B — PLANNED, not started.** `docs/superpowers/plans/2026-08-24-milestone-b-ios-pipeline.md`
Six tasks proving GitHub Actions can build an unsigned `.ipa` that installs via Sideloadly
and boots our shell layer. Execution method agreed: `superpowers:subagent-driven-development`.

## Facts worth not re-deriving

- **Two interpreters.** The Ren'Py SDK's bundled CPython 3.12.7 runs Ren'Py; its stdlib is
  stripped, `.pyc`-only, and has **no `unittest`**. Tests run on a system CPython via
  `scripts/run_tests.sh`. Never install anything into `vendor/` — it is SHA-256-verified
  and `fetch_deps.sh` deletes it wholesale on repair.
- **Hook timing is load-bearing.** `select_next_basedir` runs *after* `reload_all()`, so
  teardown there hits freshly-constructed objects while the outgoing game's native
  resources are already orphaned. Live teardown runs from `lifecycle._restart()`, before
  the exception is raised.
- **`ru_maxrss` is peak RSS** and can never decrease. The iOS memory re-measurement must
  use `task_info(TASK_VM_INFO).phys_footprint`, which is also what Jetsam meters.
- **The rig mirrors the iOS bundle exactly:** `main.py`, `vnshell/`, `renpy/` and `game/`
  all sit at one root. `bootstrap.py:334` calls `path_to_gamedir` *before* the restart
  loop, so `game/` must exist at the initial basedir.
- **No secrets in CI, ever.** Unsigned `.ipa`; Sideloadly signs locally with a free Apple
  ID (7-day expiry, max 3 apps). Any step appearing to need a secret is a design failure.
- Working name `VNPlayer` is a placeholder. Settle it before the Xcode project exists —
  bundle identifiers are painful to change. Avoid "Ren'Py" in the app name itself.

## Open decisions

- The product name.
- Whether to pursue the native memory leak upstream (would benefit every Ren'Py mobile
  player) or live with watch-and-warn.
