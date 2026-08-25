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

# Commands pulled from the mailbox but not yet run.
#
# tick() used to dispatch a whole poll() batch inline, and any handler that restarts the
# engine raises out of that loop -- silently discarding every command behind it. The
# module note said this would become a real bug once a non-restarting handler landed, and
# M3 is when they land. One command per tick, with the rest kept here, means a restart
# costs nothing but a frame.
_pending: list[Command] = []

# Last engine-state snapshot sent to the native side, so unchanged state is not rewritten
# sixty times a second.
_last_state: dict | None = None


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

    # config.save_directory is knowable only from the running engine -- the game sets it
    # in its own Python, so it cannot be read out of the archive at import time. It rides
    # out on the event that already says the game is up rather than opening a channel for
    # one string. None is a legitimate value (renpy/config.py:369) and must survive as
    # null rather than as the string "None": the export note uses it to name a folder.
    save_directory = None
    if STATE.current_game_id:
        try:
            import renpy  # type: ignore

            value = renpy.config.save_directory
            save_directory = str(value) if value else None
        except Exception:  # noqa: BLE001 - never let this stop the ready announcement
            save_directory = None

    _EVENTS.emit(
        {
            "event": event,
            "commandId": _pending_command_id,
            "gameId": STATE.current_game_id,
            "saveDirectory": save_directory,
        }
    )


def tick() -> None:
    """Drain the mailbox. Called every frame from config.periodic_callbacks."""

    if not _announced:
        announce_game_ready()

    if _harness_enabled and STATE.next_basedir is None:
        from vnshell import harness

        harness.start()

    _publish_engine_state()

    # Drain into the queue, then run exactly ONE. A handler that restarts the engine
    # raises out of here, and anything still queued survives in _pending rather than
    # being lost with the frame -- except across a restart, which clears the queue on
    # purpose (see _restart).
    _pending.extend(mailbox_module.MAILBOX.poll())

    if _pending:
        _dispatch(_pending.pop(0))


def _dispatch(command: Command) -> None:
    """Run one command.

    **There is deliberately no `try/except Exception` around this call**, and the reason
    is not obvious enough to leave unwritten.

    Two consultation reviews recommended wrapping every handler, warning that Ren'Py uses
    exceptions for control flow and a blanket catch would swallow rollback and load.
    Checked against the source, that is backwards:

        renpy/rollback.py:1185   RollbackException(BaseException)
        renpy/rollback.py:1169   UnfreezeException(BaseException)
        renpy/game.py:142        UtterRestartException(Exception)

    Rollback and load derive from BaseException precisely so that ordinary handlers do
    not eat them. The one that IS an Exception is ours -- `_restart()` raises it for
    `launch` and `quitToLibrary`. A wrapper here would therefore leave rollback working
    and silently break quit-to-library, the one control a stuck reader most needs.

    Handlers wrap their own engine calls where it is safe (see `_handle_quick_save`), and
    report refusals as events rather than raising.
    """

    handler = _HANDLERS.get(command.name)

    if handler is None:
        # Reported, not dropped. A command the shell does not recognise means the two
        # sides disagree about the protocol, which has already cost this project one
        # device round-trip -- and silence made it look like the channel was dead.
        mailbox_module.MAILBOX._report(f"no handler for command {command.name!r}")
        _emit_failed(
            command.args.get("commandId"),
            f"this build does not understand the command {command.name!r}",
        )
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

        music = _api().music
        music.stop(channel="music", fadeout=0)
        music.stop(channel="sound", fadeout=0)
        music.stop(channel="voice", fadeout=0)
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

    # Commands queued behind a restart were aimed at the outgoing game. Carrying a
    # rollback across a switch would apply it to whatever loads next.
    _pending.clear()

    for action in purge.teardown_live_engine():
        print(f"[vnshell] teardown: {action}")

    import renpy.game  # type: ignore

    raise renpy.game.UtterRestartException()


# Ren'Py API names we call, kept in one place so tests can check them against the SDK.
RENPY_API_NAMES = (
    "save",
    "load",
    "rollback",
    "can_rollback",
    "restart_interaction",
    "game_menu",
    "has_screen",
    "has_label",
    "show_screen",
    "context",
)


def _api():
    """Ren'Py's public API module.

    **This is `renpy.exports`, and it is NOT the `renpy` package.**

    `renpy/defaultstore.py:481` does `globals()["renpy"] = renpy.exports`, so inside a
    `.rpy` file the name `renpy` already IS `renpy.exports`. That is why every example in
    Ren'Py's documentation writes `renpy.save(...)` and why the same line fails from a
    plain Python module: `import renpy` gives the PACKAGE, which has `config`, `game` and
    `loadsave` but none of `save`, `load`, `rollback`, `can_rollback`,
    `restart_interaction` or `music`.

    This cost a device round-trip. `config.skipping` assigned fine (real submodule) and
    then `restart_interaction()` raised AttributeError; `_publish_engine_state` died on
    `can_rollback()` so no engine-state event was ever emitted, and the overlay showed
    Roll back and Quick save permanently greyed out. Two symptoms, one cause, and neither
    pointed at it.
    """

    import renpy.exports  # type: ignore

    return renpy.exports


def _emit_done(command_id, **extra) -> None:
    payload = {"event": "commandDone", "commandId": command_id}
    payload.update(extra)
    _EVENTS.emit(payload)


def _emit_failed(command_id, reason: str) -> None:
    """Report a refusal in words a reader can act on.

    Not an error channel: "you cannot save at the main menu" is a legitimate answer to a
    save request, and the overlay renders it as a sentence. The alternative -- swallowing
    it -- produces a button that sometimes does nothing, which is the worst option.
    """

    _EVENTS.emit({"event": "commandFailed", "commandId": command_id, "reason": reason})


def _save_blocked_reason():
    """Why saving is not allowed right now, or None if it is.

    These four conditions are not invented. They mirror Ren'Py's own
    FileSave.get_sensitive() (renpy/common/00action_file.rpy:421), which is the authority
    on when the engine will accept a save. A consultation review recommended guarding with
    renpy.can_save() instead -- that function does not exist in Ren'Py 8.5.3, which is why
    this reads the same state Ren'Py's own save button reads.
    """

    import renpy  # type: ignore

    try:
        store = renpy.store  # type: ignore[attr-defined]

        if getattr(store, "_in_replay", None):
            return "you cannot save during a replay"
        if getattr(store, "main_menu", False):
            return "you cannot save from the main menu"
        if not renpy.config.save:
            return "this game has saving turned off"
    except Exception as exc:  # noqa: BLE001
        return f"could not check whether saving is allowed ({type(exc).__name__})"

    return None


QUICK_SLOT = "quick-1"


def _handle_quick_save(command: Command) -> None:
    command_id = command.args.get("commandId")

    reason = _save_blocked_reason()
    if reason:
        return _emit_failed(command_id, reason)

    import renpy  # type: ignore

    # except Exception is safe HERE and only here: renpy.save does not use exceptions for
    # control flow. It is not safe around rollback, load or quit -- see _dispatch.
    try:
        _api().save(QUICK_SLOT, extra_info="Quick save")
    except Exception as exc:  # noqa: BLE001
        return _emit_failed(command_id, f"the save failed ({type(exc).__name__})")

    _emit_done(command_id)


def _handle_quick_load(command: Command) -> None:
    command_id = command.args.get("commandId")

    import renpy  # type: ignore

    import renpy.loadsave  # type: ignore

    if not renpy.loadsave.can_load(QUICK_SLOT):
        return _emit_failed(command_id, "there is no quick save to load")

    # Deliberately NOT wrapped. renpy.load raises UnfreezeException to perform the load,
    # and while that derives from BaseException (so except Exception would not catch it),
    # relying on that subtlety in a handler is how the next person breaks it.
    _emit_done(command_id)
    _api().load(QUICK_SLOT)


# The game's own menu pages, by the names Ren'Py gives them. Not an invented set: these
# are the three screens ShowMenu is documented with (common/00action_menu.rpy:57).
MENU_SCREENS = ("save", "load", "preferences")


def _handle_show_menu(command: Command) -> None:
    """Open one of the game's OWN menu pages -- Save, Load or Preferences.

    Distinct from quick save, which writes one reserved slot and never shows a screen.
    These hand the reader the game's real pages: every slot, its thumbnails, its own
    settings. On a phone there is otherwise no route to them at all -- desktop reaches
    them with Escape or right-click, and a game's own quick-menu is frequently drawn too
    small to hit or hidden outright.

    The implementation mirrors ShowMenu.__call__ (common/00action_menu.rpy:83) instead of
    inventing a route, and that includes its two branches, which are not interchangeable:

      * From play, entering the game menu means a NEW CONTEXT (`game_menu`), which runs
        the menu's own interaction loop inside this call and returns when the reader
        dismisses it.
      * Once already inside the menu -- and the main menu counts, `_menu` is True there
        too (00gamemenu.rpy:90, 00start.rpy:105) -- switching pages is a transient screen
        show. Calling `game_menu` again from there would stack a second context on the
        first, and the reader would need two dismissals to get back to the game.

    Blocking is safe. The nested context pumps PERIODIC like any other, so `tick()` keeps
    running inside it and the strip stays live; and `call_in_new_context` pops its context
    in a `finally` (renpy/game.py), so a `quitToLibrary` raised from within the menu
    unwinds cleanly rather than leaving the stack dirty.
    """

    command_id = command.args.get("commandId")
    screen = command.args.get("screen")

    if screen not in MENU_SCREENS:
        return _emit_failed(command_id, f"this build cannot open a {screen!r} page")

    # Save is the only one of the three the engine ever refuses -- Load and Preferences
    # are legitimate at the main menu. Reuses the same four conditions Ren'Py's own save
    # button reads, rather than a second opinion about them.
    if screen == "save":
        reason = _save_blocked_reason()
        if reason:
            return _emit_failed(command_id, reason)

    api = _api()

    # A game may define a page as a label rather than a screen; Ren'Py appends "_screen"
    # for exactly that case, and so does this.
    target = screen
    if not (api.has_screen(target) or api.has_label(target)):
        target = screen + "_screen"

    if not (api.has_screen(target) or api.has_label(target)):
        return _emit_failed(command_id, f"this game has no {screen} page")

    in_menu = bool(getattr(api.context(), "_menu", False))

    if in_menu and not api.has_screen(target):
        # Inside the menu, page switching is a screen show. A game that defines this page
        # as a LABEL needs a jump within the menu context, which ShowMenu performs with
        # ui.layer/remove_above and which is not worth half-reproducing from here. Say so
        # rather than returning quietly -- a control that does nothing and says nothing is
        # the failure this whole event channel exists to avoid.
        return _emit_failed(
            command_id,
            f"this game's {screen} page can only be opened from its own menu",
        )

    _emit_done(command_id)

    if in_menu:
        api.show_screen(target, _transient=True)
        api.restart_interaction()
        return

    api.game_menu(target)


def _handle_rollback(command: Command) -> None:
    command_id = command.args.get("commandId")

    import renpy  # type: ignore

    if not _api().can_rollback():
        # A real answer, not a failure: at the start of a game there is nothing behind you.
        return _emit_failed(command_id, "there is nothing to roll back to")

    _emit_done(command_id)
    # Raises RollbackException (a BaseException) to do the work. Same reasoning as load:
    # left unwrapped so the control flow is visible rather than implied.
    _api().rollback()


def _handle_toggle_skip(command: Command) -> None:
    command_id = command.args.get("commandId")

    import renpy  # type: ignore

    try:
        if renpy.config.skipping:
            renpy.config.skipping = None
            skipping = False
        else:
            renpy.config.skipping = "slow"
            skipping = True
        _api().restart_interaction()
    except Exception as exc:  # noqa: BLE001
        return _emit_failed(command_id, f"could not change skipping ({type(exc).__name__})")

    _emit_done(command_id, isSkipping=skipping)


def _publish_engine_state() -> None:
    """Tell the overlay what the engine will currently accept.

    Without this every control looks available whether or not it will work, and the
    reader learns which ones are real by tapping them and reading refusals. Raised in
    review, and it is the difference between an overlay that feels solid and one that
    feels broken.

    Emitted only on CHANGE. This runs every frame, and a spool file per frame would be
    both pointless and a genuine IO problem on a phone.
    """

    global _last_state

    if not _EVENTS.directory:
        return

    import renpy  # type: ignore

    try:
        state = {
            "canRollback": bool(_api().can_rollback()),
            "canSave": _save_blocked_reason() is None,
            "isSkipping": bool(renpy.config.skipping),
            "inGame": STATE.current_game_id is not None,
            # True while the game's own menu (or its main menu) is up. The overlay greys
            # out rollback and skip there, because neither means anything on a menu page.
            "inMenu": bool(getattr(_api().context(), "_menu", False)),
        }
    except Exception:  # noqa: BLE001
        # The engine is mid-restart or otherwise not answering. Saying nothing is right:
        # the overlay keeps its last known state rather than flickering everything off.
        return

    if state == _last_state:
        return

    _last_state = state
    _EVENTS.emit({"event": "engineState", **state})


_HANDLERS = {
    "launch": _handle_launch,
    "quitToLibrary": _handle_quit_to_library,
    "quickSave": _handle_quick_save,
    "quickLoad": _handle_quick_load,
    "rollback": _handle_rollback,
    "toggleSkip": _handle_toggle_skip,
    "showMenu": _handle_show_menu,
}
