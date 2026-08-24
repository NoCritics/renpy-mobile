"""Between-game engine cleanup.

Ren'Py's bootstrap tears down the renderer, audio and image cache in a ``finally`` that
sits *outside* its restart loop (bootstrap.py: try at 354, while at 355, finally at 409).
Nothing is therefore released between games, and this module has to do it by hand.

Every step is defensive: a failure here must degrade the switch, not crash the app.

Steps are added to ``purge_engine_state`` only in response to a failure the harness
actually reported (see docs/BUILD.md, "Purge findings"). Do not add a step here
speculatively — untested code in a path that runs between every game switch is worse
than no cleanup at all.

Only one step lives here: purging modules imported from the previous game's ``game/``
directory. It is the only step that measurably fixed a reported failure (the
``sys.modules`` contamination in docs/BUILD.md's harness baseline).

Five other candidates were tried against the memory-growth failure and removed —
not because they errored (all but ``gc.collect()`` did, defensively, and are recorded
below for that reason), but because none of them, alone or combined, moved the
measured RSS growth outside run-to-run noise (~1 MB on a ~260 MB process). Full data in
docs/BUILD.md, "Purge findings":

- ``renpy.display.im.cache.clear()`` — ran without error; no measurable effect.
- ``renpy.text.font.free_memory()`` — ran without error; no measurable effect.
- ``gc.collect()`` — ran without error, freed ~9,700 objects every switch; no
  measurable effect on RSS outside noise.
- ``renpy.display.render.free_memory()`` — always raised
  ``AttributeError: 'NoneType' object has no attribute 'surftree'``. At the point
  ``select_next_basedir`` runs, Ren'Py has not yet (re)created its rendering interface
  for the next pass, so this call has nothing to act on from this hook.
- ``renpy.audio.music.stop(...)`` / ``renpy.display.video.movie_stop(...)`` — both
  always raised ``IndexError: list index out of range``, same root cause: the audio
  and video subsystems are not initialized at this call site either.

The memory growth is real (see docs/BUILD.md) but is not reachable from any Python-level
cache this module can call between passes of the restart loop. It survives module
purging, image-cache clearing, font-cache clearing, and forced GC, together or alone.
"""

from __future__ import annotations

import os
import sys


def purge_engine_state(previous_basedir: str | None) -> list[str]:
    actions: list[str] = []

    for step in (
        lambda: _purge_modules(previous_basedir),
    ):
        try:
            result = step()
            if result:
                actions.append(result)
        except Exception as exc:  # noqa: BLE001 — cleanup must never propagate
            actions.append(f"failed: {step.__name__ if hasattr(step, '__name__') else step}: {exc!r}")

    return actions


def _purge_modules(previous_basedir: str | None) -> str:
    """Drop modules imported from the previous game's ``game/`` directory.

    Scoped by resolved path rather than by module name, so a game's ``utils.py`` cannot
    leak into the next game's ``utils.py`` — and so nothing belonging to Ren'Py or the
    standard library is ever touched.

    Deliberately scoped to ``<previous_basedir>/game``, not ``previous_basedir`` itself.
    The shell project's own basedir *is* the SDK root (see main.py:path_to_renpy_base —
    it is the directory main.py lives in, which the rig places at the SDK root and iOS
    places at the app bundle root). That root also holds ``renpy/``, the interpreter's
    stdlib, and ``vnshell/`` itself. The first run of this purge, scoped to the whole
    basedir, took out the whole basedir on the very first switch away from the shell
    project and killed the running interpreter's own modules (``re``, ``json``,
    ``renpy.*``, ``vnshell.*``, even ``__main__``), crashing before any game loaded.
    Scoping to ``game/`` matches where code actually runs from: ``path_to_gamedir``
    requires a strict ``game/`` subdirectory (main.py), and every observed game imports
    via ``sys.path.insert(0, renpy.config.gamedir)`` where ``gamedir == basedir/game``.

    Confirmed necessary: harness/out/observations.jsonl showed game B reading game A's
    cached ``sentinel`` module (VALUE == "A") on both A->B switches before this step
    existed. See docs/BUILD.md, "Harness baseline".
    """

    if not previous_basedir:
        return ""

    root = os.path.join(os.path.abspath(previous_basedir), "game")
    removed: list[str] = []

    for name, module in list(sys.modules.items()):
        origin = getattr(module, "__file__", None)
        if not origin:
            continue
        try:
            resolved = os.path.abspath(origin)
        except (TypeError, ValueError):
            continue
        if resolved.startswith(root + os.sep):
            sys.modules.pop(name, None)
            removed.append(name)

    # The game directory is pushed onto sys.path by the game itself and by
    # bootstrap; leaving stale entries there would let the next game import from
    # a directory that no longer holds the modules it expects.
    sys.path[:] = [p for p in sys.path if not os.path.abspath(p).startswith(root)]

    return f"purged {len(removed)} modules: {', '.join(sorted(removed))}" if removed else ""
