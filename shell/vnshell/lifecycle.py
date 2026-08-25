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
from vnshell.transports import (
    FileTransport,
    NullTransport,
    SpoolEmitter,
    SpoolTransport,
)

_installed = False

# Absolute path of the basedir most recently handed back by select_next_basedir, so the
# next call knows what to purge. Module-level rather than on STATE: it tracks what the
# engine actually loaded, not what was requested, and select_next_basedir is the only
# reader/writer.
_previous_basedir: str | None = None

# Whether the scripted cycling harness is active, read once in install() and cached
# here. tick() runs every frame in code that ships to iOS; an os.environ lookup
# (vnshell.harness.enabled()) every frame is production cost paid for test scaffolding.
# Reading it once at startup and checking a bool the rest of the session's frames costs
# nothing.
_harness_enabled = False

# Events flowing back to the native side. The directory stays empty off-iOS, where
# emit() is a no-op, so the desktop harness is untouched by any of this.
_EVENTS = SpoolEmitter("")

# The commandId of the launch currently in flight, and whether its "the game is up"
# event has gone out yet.
#
# Module-level rather than on STATE because STATE.reset_for_shell() clears STATE, and
# these have to survive exactly that: quitting to the library IS one of the transitions
# being announced.
_pending_command_id = None
_announced = False


def install(renpy_base: str) -> None:
    """Wire the shell into Ren'Py. Must run before bootstrap().

    Guarded against double-install: bootstrap() is expected to call this once, but
    calling it twice would silently rebind get_alternate_base and reset STATE.
    """

    global _installed, _harness_enabled

    if _installed:
        return

    # The shell project's game/ lives directly at renpy_base, mirroring iOS, where
    # Ren'Py's distributor packages the game into base/ alongside main.py and renpy/.
    # This also keeps bootstrap.py:334 happy: it calls path_to_gamedir(renpy_base, ...)
    # before the restart loop is ever entered, and our strict version needs game/ there.
    STATE.shell_project_dir = renpy_base

    # On iOS data_root() redirects this out of the read-only bundle and into the app's
    # Data container; off-iOS it returns renpy_base unchanged, preserving the desktop
    # layout Milestone A verified. VNPLAYER_SAVES_ROOT still wins over both, because the
    # cycling harness sets it explicitly.
    from vnshell import platform

    STATE.saves_root = os.environ.get(
        "VNPLAYER_SAVES_ROOT",
        os.path.join(platform.data_root(renpy_base), "Saves"),
    )

    command_file = os.environ.get("VNPLAYER_COMMAND_FILE")
    command_spool = os.environ.get("VNPLAYER_COMMAND_SPOOL")

    if not command_file and not command_spool and platform.is_ios():
        # Nothing on iOS has an environment to export these from -- the process is
        # launched by iOS, not by a shell -- so the paths are derived. They must agree
        # with VNPlayerPaths.swift, which owns the other half of this contract.
        #
        # Application Support rather than Documents: Documents is exposed to the Files
        # app, and the command spool is the app's control plane. A user who deletes a
        # command file mid-launch should not be able to.
        support = os.path.join(
            os.path.expanduser("~"), "Library", "Application Support", "VNPlayer"
        )
        command_spool = os.path.join(support, "Commands")
        _EVENTS.directory = os.path.join(support, "Events")

    if command_spool:
        mailbox_module.MAILBOX = Mailbox(SpoolTransport(command_spool))
    elif command_file:
        mailbox_module.MAILBOX = Mailbox(FileTransport(command_file))
    else:
        mailbox_module.MAILBOX = Mailbox(NullTransport())

    event_spool = os.environ.get("VNPLAYER_EVENT_SPOOL")
    if event_spool:
        _EVENTS.directory = event_spool

    from vnshell import harness

    _harness_enabled = harness.enabled()

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


def attach_to_game() -> None:
    """Register tick() with the game Ren'Py has just loaded.

    Called from ``vnplayer_hook.rpe.py``, which the engine execs for every game during
    early init. `config.periodic_callbacks` belongs to the game, and an imported game
    does not load our shell project's script.rpy -- so without this the command channel
    goes deaf the instant a real game starts, and nothing could quit back to the library.

    Idempotent: the shell project registers a callback of its own, and a restart that
    re-execs the extension must not stack duplicates.
    """

    import renpy  # type: ignore

    callbacks = getattr(renpy.config, "periodic_callbacks", None)
    if callbacks is None:
        return

    if tick not in callbacks:
        callbacks.append(tick)
        # Argument-free on purpose. On iOS this is the only kind of NSLog line that
        # survives the USB relay -- measured in Milestone B, where every line carrying a
        # formatted value arrived as "<decode: missing data>". It is also the only
        # evidence that the .rpe.py extension mechanism fired at all, which is otherwise
        # a silent assumption: a hook that never loads looks exactly like a hook that
        # loads and does nothing.
        print("[vnshell] hook: periodic callback attached")


def announce_game_ready() -> None:
    """Tell the native side the launch actually reached a running game.

    Swift dismisses the library on THIS, never on having written the command. A game
    that fails during init would otherwise leave the user looking at whatever the
    renderer last drew, with no way back.

    Emitted from tick() rather than from the restart, because tick() only runs once the
    engine is executing the new game's interaction loop -- which is the thing being
    claimed. Announcing at restart time would claim it a second too early, and be wrong
    in exactly the case that matters.
    """

    global _announced

    if _announced:
        return

    _announced = True

    # Which side of the switch we landed on. The shell project is what runs when there
    # is no game, so "the shell is interacting" is the completion signal for
    # quitToLibrary just as "the game is interacting" is for launch.
    event = "gameReady" if STATE.current_game_id else "shellReady"

    _EVENTS.emit(
        {
            "event": event,
            "commandId": _pending_command_id,
            "gameId": STATE.current_game_id,
        }
    )


def tick() -> None:
    """Drain the mailbox. Called every frame from config.periodic_callbacks."""

    if not _announced:
        announce_game_ready()

    if _harness_enabled and STATE.next_basedir is None:
        from vnshell import harness

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
    global _pending_command_id, _announced

    command_id = command.args.get("commandId")
    basedir = command.args.get("basedir")

    def fail(reason: str) -> None:
        _EVENTS.emit({"event": "launchFailed", "commandId": command_id, "reason": reason})

    if not basedir:
        return fail("no basedir given")

    resolved = os.path.realpath(os.path.abspath(basedir))

    if not os.path.isdir(resolved):
        return fail("that game is no longer on disk")

    if not _is_permitted_basedir(resolved):
        # The command spool is a file on disk, and Documents/ is user-visible. Nothing
        # should be able to point the engine at an arbitrary directory by writing a
        # command -- least of all one that was left over from a previous version of the
        # app. Cheap to check, and it makes the trust boundary explicit rather than
        # implied.
        return fail("that game is not in the library")

    if not os.path.isdir(os.path.join(resolved, "game")):
        # path_to_gamedir raises NoGameDirectory for this, which would abort the process
        # rather than return control. Catching it here turns a crash into a message.
        return fail("that folder has no game/ directory")

    STATE.next_basedir = resolved
    STATE.current_game_id = command.args.get("gameId") or os.path.basename(
        os.path.normpath(resolved)
    )

    _pending_command_id = command_id
    _announced = False
    _EVENTS.emit({"event": "launchAccepted", "commandId": command_id})

    _restart()


def _is_permitted_basedir(resolved: str) -> bool:
    """True when the path is a game the library actually installed.

    Off-iOS this always passes: the desktop harness legitimately launches games from
    scratch directories all over the filesystem, and tightening that would break the
    200-switch rig that validates the whole switching design.
    """

    from vnshell import platform

    if not platform.is_ios():
        return True

    games_root = os.path.realpath(
        os.path.join(os.path.expanduser("~"), "Documents", "Games")
    )
    parent = os.path.dirname(os.path.normpath(resolved))
    return os.path.normcase(parent) == os.path.normcase(games_root)


def _handle_quit_to_library(command: Command) -> None:
    global _pending_command_id, _announced

    # SDL keeps playing the outgoing game's audio across the restart otherwise; the
    # library would come up over a game that is still singing.
    _stop_audio()

    STATE.reset_for_shell()
    _pending_command_id = command.args.get("commandId")
    _announced = False
    _restart()


def _stop_audio() -> None:
    try:
        import renpy  # type: ignore

        renpy.music.stop(channel="music", fadeout=0)
        renpy.music.stop(channel="sound", fadeout=0)
        renpy.music.stop(channel="voice", fadeout=0)
    except Exception as e:  # noqa: BLE001 - never let cleanup abort the switch
        print(f"[vnshell] could not stop audio: {type(e).__name__}")


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
