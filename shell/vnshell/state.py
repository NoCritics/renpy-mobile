"""Process-wide switching state.

Deliberately a plain object rather than module globals scattered around: everything
that survives a game switch lives here, so the purge step has one place to look.
"""

from __future__ import annotations


class State:
    def __init__(self) -> None:
        # Absolute path of the base directory Ren'Py should load on its next
        # pass through the bootstrap restart loop. None means "the shell project".
        self.next_basedir: str | None = None

        # Stable identifier for the game currently loaded, used to isolate saves.
        # None while the shell project is loaded.
        self.current_game_id: str | None = None

        # Absolute path to the bundled idle launcher project. Set once at startup.
        self.shell_project_dir: str = ""

        # Absolute path to the directory holding per-game save directories.
        self.saves_root: str = ""

    def reset_for_shell(self) -> None:
        self.next_basedir = None
        self.current_game_id = None


STATE = State()
