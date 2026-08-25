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

    from vnshell import platform
    from vnshell.state import STATE

    if STATE.saves_root and STATE.current_game_id:
        return platform.ensure_dir(
            os.path.join(STATE.saves_root, STATE.current_game_id)
        )

    # The shell project, or a not-yet-identified game.
    #
    # This used to return <gamedir>/saves unconditionally, which on iOS is inside the
    # read-only app bundle: the sandbox denied it on every launch
    # (deny(1) file-write-create .../base/game/saves). On desktop <gamedir>/saves is
    # correct and stays, because data_root() returns its fallback unchanged off-iOS.
    #
    # On iOS it must not be under Documents either, which is where it went next. The
    # library screen is itself a Ren'Py project and inherits Ren'Py's defaults, including
    # ten rotating autosave slots -- so its own save files piled up loose in the folder
    # the reader browses, mixed in among the per-game directories and indistinguishable
    # from her real saves except by being smaller. Observed on device: auto-1, auto-2,
    # 1-1 and _reload-1 sitting beside Games/ and Saves/.
    #
    # Nothing written through this branch is ever the reader's data.
    if platform.is_ios():
        return platform.ensure_dir(
            os.path.join(platform.support_root(gamedir), "shell-saves")
        )

    return platform.ensure_dir(
        os.path.join(platform.data_root(gamedir), "saves")
    )


def path_to_logdir(basedir: str) -> str:
    """Return a writable directory for Ren'Py's log and traceback files.

    Note that on iOS Ren'Py never opens log.txt at all -- renpy/log.py:79 points the log
    at real stdout when renpy.ios is set, and renios routes stdout through NSLog. This
    override therefore does not affect logging on the device; it exists because
    config.logdir is also where traceback.txt and errors.txt are written, and those must
    not target the read-only bundle.
    """

    from vnshell import platform

    return platform.ensure_dir(platform.data_root(basedir))


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

    # Every import from the bundle otherwise tries to drop a .pyc beside its source, and
    # on iOS the bundle is read-only, so each one costs a failed syscall and a sandbox
    # denial in the device log (measured: deny(1) file-write-create .../base/vnshell/
    # __pycache__). Python already falls back to running from source, so nothing breaks
    # today -- this just stops the process asking for something it will never be given.
    from vnshell import platform as vnplatform

    if vnplatform.is_ios():
        sys.dont_write_bytecode = True

    import renpy.bootstrap  # type: ignore

    renpy.__main__ = sys.modules[__name__]  # type: ignore

    from vnshell import lifecycle

    lifecycle.install(renpy_base)

    renpy.bootstrap.bootstrap(renpy_base)


if __name__ == "__main__":
    main()
