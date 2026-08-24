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

        counters = Counters()
        counters.cb = ctypes.sizeof(Counters)
        handle = ctypes.windll.kernel32.GetCurrentProcess()  # type: ignore[attr-defined]
        ok = ctypes.windll.psapi.GetProcessMemoryInfo(  # type: ignore[attr-defined]
            handle, ctypes.byref(counters), counters.cb
        )
        return int(counters.WorkingSetSize) if ok else 0

    try:
        import resource

        return int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss) * 1024
    except Exception:
        return 0


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
