"""Between-game engine cleanup.

Ren'Py's bootstrap tears down the renderer, audio and image cache in a ``finally`` that
sits *outside* its restart loop (bootstrap.py: try at 372, while at 373, finally at 427).
Nothing is therefore released between games, and this module has to do it by hand.

Every step is defensive: a failure here must degrade the switch, not crash the app.

There are two hook points here, and they are not interchangeable — that distinction was
learned the hard way and is the single most important thing this module has to say to
the iOS plan:

- ``teardown_live_engine()`` runs from ``lifecycle._restart()``, *before*
  ``UtterRestartException`` is raised. This is the only moment the outgoing game's
  renderer, audio subsystem and caches are still live and reachable. Three of its six
  calls are the same ones bootstrap.py's own ``finally`` block makes at process exit
  (bootstrap.py: 427-438) — ``im.cache.quit()``, ``draw.quit()`` and ``audio.audio.quit()``
  — made per switch instead of once at the end of the process; the other three
  (stopping music/sound/voice, ``movie_stop()``, ``font.free_memory()``) are ours, with
  no engine-authored counterpart. See the docstring on ``teardown_live_engine`` for the
  full breakdown.
- ``purge_engine_state()`` runs from ``select_next_basedir()``, which bootstrap calls
  *after* ``renpy.reload_all()``. By then the engine's module objects have already been
  replaced, so anything reachable only through fresh module state (image cache, render
  cache, font cache, audio/video subsystems) is a *new*, empty object at this point —
  cleaning it up here has nothing to act on. Only ``sys.modules`` is actually reachable
  and useful from this hook; ``sys.path`` is also filtered here for belt-and-braces
  reasons, but bootstrap.py resets ``sys.path`` unconditionally on every pass
  (bootstrap.py:387) before the next game's code runs, so that filter has no observable
  effect — see ``_purge_modules`` for the detail.

Concretely: five candidates (``im.cache.clear()``, ``render.free_memory()``,
``font.free_memory()``, ``gc.collect()``, audio/video stop) were tried from the
post-reload hook (``purge_engine_state``) against the memory-growth failure. Three
always raised (subsystem not yet initialized on the next pass) and the other two ran
cleanly but measured no effect across 100 cycles — full data in docs/BUILD.md, "Purge
findings". Only after moving the *same kind* of calls to the pre-restart hook
(``teardown_live_engine``) did they have anything live to act on. Whether that actually
moves the measured RSS curve is itself recorded in docs/BUILD.md, not assumed here — do
not treat the existence of a live object as proof the leak is fixed.

Steps are added to either function only in response to a failure the harness actually
reported. Do not add a step here speculatively — untested code in a path that runs
between every game switch is worse than no cleanup at all.
"""

from __future__ import annotations

import os
import sys


def teardown_live_engine() -> list[str]:
    """Release the running engine's native resources, while it still owns them.

    Called from ``lifecycle._restart()`` before ``UtterRestartException`` is raised —
    see the module docstring for why that timing, not ``select_next_basedir``, is the
    only point these calls have anything live to act on.

    Every step is independent and defensive, same contract as ``purge_engine_state``: a
    failure here degrades to a logged ``failed: ...`` entry, it never propagates and
    never blocks the restart.

    Why these six steps are kept despite measuring no effect on RSS (docs/BUILD.md,
    "Purge findings", second full harness run): they are **safe** — measured across 100
    consecutive mid-session switches, including ``draw.quit()``, the step judged most
    likely to crash the next restart pass, with zero failures.

    "Mirrors the engine's own shutdown sequence" is only half true, and the two halves
    matter differently. Only **three** of these six calls actually appear in
    bootstrap.py's own ``finally`` (bootstrap.py:427-438, at process exit):
    ``im.cache.quit()`` (``_quit_image_cache``), ``draw.quit()`` (``_quit_draw``, both
    guarded there behind ``if renpy.display.draw:``) and ``audio.audio.quit()``
    (``_quit_audio``). The other **three** — stopping music/sound/voice (``_stop_audio``),
    ``movie_stop()`` (``_stop_video``) and ``font.free_memory()`` (``_free_fonts``) — do
    not appear in bootstrap.py's ``finally`` at all; they are ours, added because the
    engine-authored three did not cover everything a live game leaves behind mid-session
    (bootstrap.py's ``finally`` only ever runs once, at process exit, with no next game
    about to load). All six are kept on the same safety argument regardless of origin:
    what was actually measured is narrower than "these steps do nothing" — it is that
    none of the six reduce **resident set size on Windows with an NVIDIA GL driver**. RSS
    does not capture driver-side allocations, and this measurement does not transfer to
    iOS, which runs a completely different graphics stack (MetalANGLE over Metal, not
    Windows OpenGL). Removing them on the strength of a Windows-only null result would
    be discarding safe cleanup — engine-mirroring for three, shell-original for the other
    three — on an assumption, not a cross-platform measurement. **The iOS port must
    re-measure these six steps on device** rather than inherit this Windows finding in
    either direction — the null result here is not evidence they are safe to skip there,
    any more than it would be evidence to keep them if the *positive* result had shown up
    on Windows.
    """

    actions: list[str] = []

    for label, step in (
        ("stopped audio", _stop_audio),
        ("stopped video", _stop_video),
        ("freed fonts", _free_fonts),
        ("quit image cache", _quit_image_cache),
        ("quit renderer", _quit_draw),
        ("quit audio subsystem", _quit_audio),
    ):
        try:
            step()
            actions.append(label)
        except Exception as exc:  # noqa: BLE001 — teardown must never propagate
            actions.append(f"failed: {label}: {exc!r}")

    return actions


def _stop_audio() -> None:
    import renpy.audio.music  # type: ignore

    renpy.audio.music.stop(channel="music")
    renpy.audio.music.stop(channel="sound")
    renpy.audio.music.stop(channel="voice")


def _stop_video() -> None:
    import renpy.display.video  # type: ignore

    renpy.display.video.movie_stop(only_fullscreen=False)


def _free_fonts() -> None:
    import renpy.text.font  # type: ignore

    renpy.text.font.free_memory()


def _quit_image_cache() -> None:
    """Quit the image cache, guarded the same way bootstrap.py's own ``finally`` guards it.

    bootstrap.py:434-436 calls ``im.cache.quit()`` and ``draw.quit()`` both behind a
    single ``if renpy.display.draw:``. Matching that guard here, rather than calling
    unconditionally, keeps this call consistent with the sequence it is cited as
    mirroring — see the module and ``teardown_live_engine`` docstrings.
    """

    import renpy.display  # type: ignore
    import renpy.display.im  # type: ignore

    if renpy.display.draw:
        renpy.display.im.cache.quit()


def _quit_draw() -> None:
    """Quit the active renderer. This is the candidate most likely to be unsafe.

    ``draw.quit()`` is one of the calls bootstrap.py's own ``finally`` makes, but it
    makes it once, at process exit, with nothing expected to run afterward. Calling it
    mid-session and expecting the next pass through bootstrap to reinitialize the
    renderer cleanly is untested territory — see docs/BUILD.md, "Purge findings" for
    whether this survived the harness.
    """

    import renpy.display  # type: ignore

    if renpy.display.draw:
        renpy.display.draw.quit()


def _quit_audio() -> None:
    import renpy.audio.audio  # type: ignore

    renpy.audio.audio.quit()


def purge_engine_state(previous_basedir: str | None) -> list[str]:
    actions: list[str] = []

    for label, step in (
        ("_purge_modules", lambda: _purge_modules(previous_basedir)),
    ):
        try:
            result = step()
            if result:
                actions.append(result)
        except Exception as exc:  # noqa: BLE001 — cleanup must never propagate
            actions.append(f"failed: {label}: {exc!r}")

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
    #
    # Mirror the module filter's directory-boundary guard exactly. A bare
    # startswith(root) would also strip a sibling like <basedir>/game_assets or
    # <basedir>/gamelib — neither is under game/, but both prefix-match the string
    # "…/game". Invisible with the sentinel games (neither ships such a sibling). Note
    # this guard is now known to be belt-and-braces on a line that has no observable
    # effect at all (see the comment below) — bootstrap.py:387 resets sys.path
    # unconditionally on every pass, before any import happens, so a missing guard here
    # could never have manifested as an observed import from the wrong directory. Kept
    # correct anyway, on the same reasoning as keeping the filter itself.
    def _under_root(path: str) -> bool:
        resolved = os.path.abspath(path)
        return resolved == root or resolved.startswith(root + os.sep)

    # Belt-and-braces, not the mechanism: bootstrap.py:387 does
    # `sys.path = list(original_sys_path)` unconditionally, eight lines after it calls
    # get_alternate_base() (bootstrap.py:379, which is how this function gets invoked),
    # in the same `try`, before any import happens. Whatever this filter removes is
    # therefore discarded and rebuilt from the pre-loop snapshot before the next game's
    # code ever runs — this line has no observable effect on the running interpreter.
    # Kept anyway because it is cheap and correct, in case a future engine version drops
    # that reset.
    sys.path[:] = [p for p in sys.path if not _under_root(p)]

    return f"purged {len(removed)} modules: {', '.join(sorted(removed))}" if removed else ""
