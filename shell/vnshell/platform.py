"""Where this process is allowed to write.

On desktop the base directory is writable and Ren'Py's own defaults are fine. On iOS the
app bundle is **read-only** and the sandbox denies every write into it. Measured on
device (iPhone 13 Pro Max / iOS 26.6, 2026-08-25), three separate denials in a single
30-second launch:

    deny(1) file-write-create .../VNPlayer.app/base/game/saves
    deny(1) file-write-create .../VNPlayer.app/base/vnshell/__pycache__
    deny(1) file-write-create .../VNPlayer.app/base/vnplayer-write-probe.tmp

So anything this process writes -- saves, logs, the command mailbox -- has to live in the
app's Data container instead, which is a different filesystem location entirely from the
bundle:

    bundle (read-only):  /var/containers/Bundle/Application/<uuid>/VNPlayer.app/
    data   (writable):   /var/mobile/Containers/Data/Application/<uuid>/

Both `os.path.expanduser("~")` and `NSHomeDirectory()` resolve to the second on iOS. The
device confirmed `~/Documents` already exists at startup ("Documents exists: True"), so
no bootstrap step has to create it.
"""

from __future__ import annotations

import os

# The environment variable Ren'Py itself uses to decide `renpy.ios`
# (renpy/__init__.py:168). Keying off the same signal rather than inventing a second one
# means the shell and the engine can never disagree about which platform they are on.
#
# It is also readable BEFORE `import renpy`, which matters: path_to_logdir is called out
# of bootstrap early enough that depending on an initialised renpy module would be a
# circularity waiting to happen.
_PLATFORM_ENV = "RENPY_PLATFORM"

# Escape hatches, in precedence order ahead of any platform detection. The desktop
# cycling harness and the unit tests both need to point the shell at a scratch directory
# without pretending to be iOS.
_DATA_ROOT_ENV = "VNPLAYER_DATA_ROOT"


def is_ios() -> bool:
    """True when running under renios' embedded interpreter.

    `librenpython.a` sets ``RENPY_PLATFORM=ios-arm64`` before the interpreter starts;
    verified by inspecting the shipped static library rather than assumed.
    """

    return os.environ.get(_PLATFORM_ENV, "").startswith("ios")


def data_root(fallback: str) -> str:
    """Return a directory this process may create files in.

    ``fallback`` is used unchanged off-iOS, so desktop behaviour -- which Milestone A
    verified over 200 game switches -- is untouched by this module's existence.
    """

    override = os.environ.get(_DATA_ROOT_ENV)
    if override:
        return override

    if is_ios():
        return os.path.join(os.path.expanduser("~"), "Documents")

    return fallback


def support_root(fallback: str) -> str:
    """Return a directory for files the reader should never see.

    Distinct from `data_root` on purpose. On iOS `data_root` is ``~/Documents``, which is
    exposed to the Files app -- by design, so games and saves can be reached by hand. But
    that makes it the wrong home for anything that is not the reader's own content: the
    command spool, the library index, and the shell project's own save files all landed
    there or beside it and looked to her like clutter she was not supposed to touch.

    Must agree with `VNPlayerPaths.applicationSupport` in Swift, which owns the other
    half of this contract.

    Honours ``VNPLAYER_DATA_ROOT`` for the same reason `data_root` does, and the omission
    was caught the hard way: without it a test that merely claims to be iOS writes into
    the real `~/Library`, which is neither hermetic nor polite.
    """

    override = os.environ.get(_DATA_ROOT_ENV)
    if override:
        return os.path.join(override, "Application Support")

    if is_ios():
        return os.path.join(
            os.path.expanduser("~"), "Library", "Application Support", "VNPlayer"
        )

    return fallback


def ensure_dir(path: str) -> str:
    """Create ``path`` if absent and return it.

    Returns the path even when creation fails. A save directory that cannot be created
    is a real problem, but raising here would abort the engine's bootstrap before it can
    display anything at all -- the caller gets a path, attempts its write, and the
    failure surfaces where it can be reported.
    """

    try:
        os.makedirs(path, exist_ok=True)
    except OSError:
        pass

    return path
