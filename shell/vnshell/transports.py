"""Command transports.

The shell is driven by commands from outside Ren'Py. On iOS that is Swift, through a
C extension. On desktop it is a file, which lets the harness — and a human debugging by
hand — drive the same code path. The transport is the only part that differs.
"""

from __future__ import annotations

import json
import os
import time
from typing import Protocol


class Transport(Protocol):
    def receive(self) -> list[dict]:
        """Return and consume any pending commands. Must never block."""
        ...


class NullTransport:
    """No commands, ever. Used when nothing is driving the shell."""

    def receive(self) -> list[dict]:
        return []


class FileTransport:
    """Reads newline-delimited JSON commands from a file, consuming them.

    Consuming matters: this is polled every frame, so leaving the contents in place
    would replay the same command forever.
    """

    def __init__(self, path: str) -> None:
        self.path = path

    def receive(self) -> list[dict]:
        if not os.path.exists(self.path):
            return []

        try:
            with open(self.path, "r", encoding="utf-8") as f:
                raw = f.read()
            os.remove(self.path)
        except OSError:
            return []

        commands: list[dict] = []

        for line in raw.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                parsed = json.loads(line)
            except ValueError:
                continue
            if isinstance(parsed, dict):
                commands.append(parsed)

        return commands


class SpoolTransport:
    """Reads one-message-per-file commands from a directory.

    Replaces FileTransport for the Swift bridge. FileTransport reads a whole file and
    then deletes it, so a command written between the read and the delete is destroyed
    unread, and a partially-written line is lost permanently because the JSON parse
    fails and the loop moves on. Neither ever bit the spike, which wrote one command per
    tap by hand -- but the launch flow has traffic in both directions.

    Here the writer creates ``<name>.json.tmp`` and renames it to ``<name>.json``. Rename
    within a directory is atomic, so this side sees a file either not at all or complete.
    Files are read oldest-first by name, which is send order because the writer's names
    carry a monotonic prefix.

    FileTransport is kept, unchanged, for the desktop harness: its behaviour is what
    Milestone A verified over 200 switches and there is no reason to disturb it.
    """

    def __init__(self, directory: str) -> None:
        self.directory = directory

    def receive(self) -> list[dict]:
        try:
            names = sorted(
                name for name in os.listdir(self.directory) if name.endswith(".json")
            )
        except OSError:
            return []

        commands: list[dict] = []

        for name in names:
            path = os.path.join(self.directory, name)
            try:
                with open(path, "r", encoding="utf-8") as f:
                    parsed = json.load(f)
            except (OSError, ValueError):
                # Unreadable or not JSON. Removed rather than retried forever: it will
                # not parse later either, and leaving it would grow without bound.
                _unlink_quietly(path)
                continue

            _unlink_quietly(path)

            if isinstance(parsed, dict):
                commands.append(parsed)

        return commands


class SpoolEmitter:
    """Writes events for Swift to read, using the same atomic-rename discipline.

    The direction that did not exist before M2. Swift needs it to know a launch actually
    reached the game rather than merely being written -- without it, the library is
    dismissed on hope, and a game that fails to boot leaves the user staring at whatever
    the renderer last drew with no way back.
    """

    def __init__(self, directory: str) -> None:
        self.directory = directory
        self._counter = 0

    def emit(self, payload: dict) -> bool:
        self._counter += 1

        try:
            os.makedirs(self.directory, exist_ok=True)
        except OSError:
            return False

        name = "%013d-%06d" % (int(time.time() * 1000), self._counter)
        final = os.path.join(self.directory, name + ".json")
        temporary = final + ".tmp"

        try:
            with open(temporary, "w", encoding="utf-8") as f:
                json.dump(payload, f)
            os.replace(temporary, final)
        except OSError:
            _unlink_quietly(temporary)
            return False

        return True


def _unlink_quietly(path: str) -> None:
    try:
        os.remove(path)
    except OSError:
        pass
