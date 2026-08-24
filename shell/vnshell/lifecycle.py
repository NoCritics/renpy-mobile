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

# Absolute path of the basedir most recently handed back by select_next_basedir, so the
# next call knows what to purge. Module-level rather than on STATE: it tracks what the
# engine actually loaded, not what was requested, and select_next_basedir is the only
# reader/writer.
_previous_basedir: str | None = None


def install(renpy_base: str) -> None:
    """Wire the shell into Ren'Py. Must run before bootstrap().

    Guarded against double-install: bootstrap() is expected to call this once, but
    calling it twice would silently rebind get_alternate_base and reset STATE.
    """

    global _installed

    if _installed:
        return

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
    Signature matches stock Ren'Py, which calls it with and without ``always``; ``always``
    is accepted only for signature compatibility with the stock function and is unused
    here — bootstrap.py's restart loop always wants the freshest target, so there is no
    "sometimes" case for us to distinguish.

    This is also the one place guaranteed to run on every pass through the restart loop,
    so it doubles as the between-game cleanup point: before returning a target that
    differs from what was previously loaded, it hands the previous basedir to
    vnshell.purge so caches and stray modules from the outgoing game do not survive into
    the next one.
    """

    global _previous_basedir

    from vnshell import purge

    target = STATE.next_basedir or STATE.shell_project_dir

    if not os.path.isdir(target):
        # Never hand Ren'Py a path that does not exist; it exits the process.
        STATE.reset_for_shell()
        target = STATE.shell_project_dir

    if _previous_basedir and _previous_basedir != target:
        for action in purge.purge_engine_state(_previous_basedir):
            print(f"[vnshell] purge: {action}")

    _previous_basedir = target
    return target


def tick() -> None:
    """Drain the mailbox. Called every frame from config.periodic_callbacks."""

    from vnshell import harness

    if harness.enabled() and STATE.next_basedir is None:
        harness.start()

    # NOTE: both current handlers restart the engine, i.e. raise UtterRestartException
    # out of _dispatch. That aborts this loop, so any further commands already pulled
    # from this poll() batch are silently dropped rather than deferred to next tick.
    # Harmless today — a batch containing a restart command is expected to end the
    # session anyway — but it will be a real bug once a non-restarting handler lands:
    # queue remaining commands (or re-poll) instead of dropping them.
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
    """Tear down the live engine, then ask Ren'Py to re-enter the bootstrap restart loop.

    Teardown must happen here, before the raise: this is the last point at which the
    outgoing game's renderer, audio subsystem and caches are still live objects. Once
    UtterRestartException is caught and renpy.reload_all() runs, those objects have
    already been replaced — see vnshell.purge's module docstring for why
    select_next_basedir (which runs *after* reload_all) is a different, and mostly
    ineffective, hook for the same kind of cleanup.
    """

    from vnshell import purge

    for action in purge.teardown_live_engine():
        print(f"[vnshell] teardown: {action}")

    import renpy.game  # type: ignore

    raise renpy.game.UtterRestartException()


_HANDLERS = {
    "launch": _handle_launch,
    "quitToLibrary": _handle_quit_to_library,
}
