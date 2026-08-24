"""Scripted game-cycling driver.

Enabled only when VNPLAYER_HARNESS_CYCLES is set, so it is inert in production. It
alternates between the two sentinel games, recording resident set size after each
switch, then exits the process with a status the shell script can check.
"""

from __future__ import annotations

import ctypes
import json
import os
import sys

from vnshell.state import STATE


# Cycle state is file-backed rather than held in module globals. Game switching runs
# renpy.reload_all(), and whether that reloads non-Ren'Py modules on sys.path is not
# something we have verified. If this module were reloaded, module-level counters would
# reset and the harness would cycle forever instead of terminating — a hang rather than
# a visible failure. A file is immune to whatever the reload semantics turn out to be.
def _cycle_file() -> str:
    return os.path.join(os.path.dirname(os.environ["VNPLAYER_RSS_LOG"]), "cycle.txt")


def _read_cycle() -> int:
    try:
        with open(_cycle_file(), "r", encoding="utf-8") as f:
            return int(f.read().strip() or "0")
    except (OSError, ValueError):
        return 0


def _write_cycle(value: int) -> None:
    path = _cycle_file()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(str(value))


def enabled() -> bool:
    return bool(os.environ.get("VNPLAYER_HARNESS_CYCLES"))


def _total_cycles() -> int:
    return int(os.environ.get("VNPLAYER_HARNESS_CYCLES", "0"))


def _games() -> list[str]:
    root = os.environ["VNPLAYER_HARNESS_GAMES"]
    return [os.path.join(root, "game_a"), os.path.join(root, "game_b")]


def _rss_bytes() -> int:
    """Resident set size, without third-party dependencies.

    Windows only for now; the iOS port will supply its own implementation. Returns 0
    when unavailable rather than failing the run, so a missing metric degrades to
    'not measured' instead of a false failure.
    """

    if sys.platform == "win32":
        import ctypes.wintypes as wintypes

        class Counters(ctypes.Structure):
            _fields_ = [
                ("cb", ctypes.c_uint32),
                ("PageFaultCount", ctypes.c_uint32),
                ("PeakWorkingSetSize", ctypes.c_size_t),
                ("WorkingSetSize", ctypes.c_size_t),
                ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
                ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                ("PagefileUsage", ctypes.c_size_t),
                ("PeakPagefileUsage", ctypes.c_size_t),
            ]

        kernel32 = ctypes.windll.kernel32  # type: ignore[attr-defined]

        # Declaring these is not optional. GetCurrentProcess returns a HANDLE, but
        # ctypes defaults restype to c_int, which truncates the 64-bit pseudo-handle
        # and makes the call fail silently — returning 0 rather than an error.
        kernel32.GetCurrentProcess.restype = wintypes.HANDLE
        kernel32.GetCurrentProcess.argtypes = []

        # K32GetProcessMemoryInfo lives in kernel32 on Vista+ and avoids the psapi
        # forwarder entirely; fall back for anything that lacks it.
        try:
            get_info = kernel32.K32GetProcessMemoryInfo
        except AttributeError:
            get_info = ctypes.windll.psapi.GetProcessMemoryInfo  # type: ignore[attr-defined]

        get_info.argtypes = [wintypes.HANDLE, ctypes.POINTER(Counters), ctypes.c_uint32]
        get_info.restype = wintypes.BOOL

        counters = Counters()
        counters.cb = ctypes.sizeof(Counters)

        if not get_info(kernel32.GetCurrentProcess(), ctypes.byref(counters), counters.cb):
            return 0

        return int(counters.WorkingSetSize)

    # NOTE: ru_maxrss is PEAK resident set size — the high-water mark since process
    # start — not current RSS. It can never decrease, so this fallback cannot detect
    # teardown actually freeing memory: a run where every switch perfectly released what
    # it allocated would still read a monotonically non-decreasing curve here, identical
    # in shape to a real leak. This is fine for the desktop/Linux harness path, which
    # only needs to prove growth exists, but it would be a fourth instrument failure
    # (after the two style-bleed canaries and the truncated-handle RSS bug — see
    # docs/BUILD.md) if inherited as-is on iOS, where the whole point is measuring
    # whether teardown reduces memory. The iOS harness must use
    # task_info(TASK_VM_INFO).phys_footprint instead — current, not peak, and the same
    # figure Jetsam itself uses to decide whether to kill the process.
    try:
        import resource

        maxrss = int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
    except Exception:
        return 0

    # ru_maxrss is bytes on macOS/iOS and kilobytes on Linux. Getting this wrong
    # inflates or deflates every reading by 1024x, which would make the growth
    # threshold meaningless rather than merely wrong.
    if sys.platform == "darwin" or sys.platform == "ios":
        return maxrss

    return maxrss * 1024


def _record_rss(cycle: int) -> None:
    out = os.environ.get("VNPLAYER_RSS_LOG")
    if not out:
        return
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "a", encoding="utf-8") as f:
        f.write(json.dumps({"cycle": cycle, "rss_bytes": _rss_bytes()}) + "\n")


def start() -> None:
    """Begin cycling. Called from the shell project's tick; safe to call repeatedly."""

    if not enabled() or _read_cycle() > 0:
        return

    advance()


def advance() -> None:
    """Move to the next game, or finish the run."""

    if not enabled():
        return

    cycle = _read_cycle()
    _record_rss(cycle)

    cycle += 1
    _write_cycle(cycle)

    if cycle > _total_cycles():
        sys.exit(0)

    games = _games()
    target = games[(cycle - 1) % len(games)]

    from vnshell import lifecycle
    from vnshell.mailbox import Command

    lifecycle._handle_launch(
        Command(
            name="launch",
            args={"basedir": target, "gameId": os.path.basename(target)},
        )
    )
