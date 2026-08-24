"""VNPlayer entry point.

Ren'Py assigns this module to ``renpy.__main__`` and calls the ``path_to_*`` functions
below. On iOS this file is ``base/main.py``; on desktop the rig places it at the SDK
root. The two layouts are identical by construction.
"""

from __future__ import annotations

import os
import sys
import warnings


class NoGameDirectory(Exception):
    """Raised when a base directory contains no ``game/`` subdirectory."""


def path_to_renpy_base() -> str:
    return os.path.abspath(os.path.dirname(os.path.abspath(__file__)))


def path_to_gamedir(basedir: str, name: str) -> str:
    """Return ``<basedir>/game``, strictly.

    Stock Ren'Py tries several candidate names and silently falls back to ``basedir``
    itself. For imported, untrusted games that fallback would make Ren'Py treat the
    whole import as its game directory, so we require ``game/`` and fail loudly.
    """

    gamedir = os.path.join(basedir, "game")

    if not os.path.isdir(gamedir):
        raise NoGameDirectory(f"No game/ directory in {basedir!r}")

    return gamedir


def path_to_common(renpy_base: str) -> str | None:
    path = os.path.join(renpy_base, "renpy", "common")
    return path if os.path.isdir(path) else None


def path_to_saves(gamedir: str, save_directory: str | None = None) -> str:
    """Return a per-game save directory, outside the game tree.

    Ren'Py's default derives the location from the game's own ``config.save_directory``,
    which means two imported games with the same configured name would share saves.
    We key on our own game id instead, and keep saves outside the game directory so
    deleting or re-importing a game never destroys progress.
    """

    from vnshell.state import STATE

    if STATE.saves_root and STATE.current_game_id:
        return os.path.join(STATE.saves_root, STATE.current_game_id)

    # The shell project, or a not-yet-identified game: keep saves beside the game.
    return os.path.join(gamedir, "saves")


def path_to_logdir(basedir: str) -> str:
    return basedir


def predefined_searchpath(commondir: str | None) -> list[str]:
    import renpy  # type: ignore

    searchpath = [renpy.config.gamedir]

    if commondir and os.path.isdir(commondir):
        searchpath.append(commondir)

    return searchpath


def main() -> None:
    renpy_base = path_to_renpy_base()
    sys.path.append(renpy_base)

    warnings.simplefilter("ignore", DeprecationWarning)

    import renpy.bootstrap  # type: ignore

    renpy.__main__ = sys.modules[__name__]  # type: ignore

    from vnshell import lifecycle

    lifecycle.install(renpy_base)

    renpy.bootstrap.bootstrap(renpy_base)


if __name__ == "__main__":
    main()
