"""Game selection and switching.

Ren'Py's bootstrap already contains a restart loop that re-resolves the base directory
on every pass and catches UtterRestartException. We supply the resolver. It is a *pure
selector*: it reads state and returns a path. It never waits for input and never cleans
up — waiting happens in the running shell project, cleanup happens in vnshell.purge.
"""

from __future__ import annotations

import os

from vnshell import mailbox as mailbox_module
from vnshell.mailbox import Command, Mailbox
from vnshell.state import STATE
from vnshell.transports import FileTransport, NullTransport

_installed = False


def install(renpy_base: str) -> None:
    """Wire the shell into Ren'Py. Must run before bootstrap()."""

    global _installed

    # The shell project's game/ lives directly at renpy_base, mirroring iOS, where
    # Ren'Py's distributor packages the game into base/ alongside main.py and renpy/.
    # This also keeps bootstrap.py:315 happy: it calls path_to_gamedir(renpy_base, ...)
    # before the restart loop is ever entered, and our strict version needs game/ there.
    STATE.shell_project_dir = renpy_base
    STATE.saves_root = os.environ.get(
        "VNPLAYER_SAVES_ROOT", os.path.join(renpy_base, "saves")
    )

    command_file = os.environ.get("VNPLAYER_COMMAND_FILE")
    if command_file:
        mailbox_module.MAILBOX = Mailbox(FileTransport(command_file))
    else:
        mailbox_module.MAILBOX = Mailbox(NullTransport())

    import renpy.bootstrap  # type: ignore

    renpy.bootstrap.get_alternate_base = select_next_basedir

    _installed = True


def select_next_basedir(basedir: str, always: bool = False) -> str:
    """Replacement for renpy.bootstrap.get_alternate_base.

    Returns the base directory Ren'Py should load on this pass of the restart loop.
    Signature matches stock Ren'Py, which calls it with and without ``always``.
    """

    target = STATE.next_basedir or STATE.shell_project_dir

    if not os.path.isdir(target):
        # Never hand Ren'Py a path that does not exist; it exits the process.
        STATE.reset_for_shell()
        return STATE.shell_project_dir

    return target


def tick() -> None:
    """Drain the mailbox. Called every frame from config.periodic_callbacks."""

    for command in mailbox_module.MAILBOX.poll():
        _dispatch(command)


def _dispatch(command: Command) -> None:
    handler = _HANDLERS.get(command.name)
    if handler is None:
        return
    handler(command)


def _handle_launch(command: Command) -> None:
    basedir = command.args.get("basedir")
    if not basedir or not os.path.isdir(basedir):
        return

    STATE.next_basedir = os.path.abspath(basedir)
    STATE.current_game_id = command.args.get("gameId") or os.path.basename(
        os.path.normpath(basedir)
    )
    _restart()


def _handle_quit_to_library(command: Command) -> None:
    STATE.reset_for_shell()
    _restart()


def _restart() -> None:
    """Ask Ren'Py to tear down and re-enter the bootstrap restart loop."""

    import renpy.game  # type: ignore

    raise renpy.game.UtterRestartException()


_HANDLERS = {
    "launch": _handle_launch,
    "quitToLibrary": _handle_quit_to_library,
}
