"""Command transports.

The shell is driven by commands from outside Ren'Py. On iOS that is Swift, through a
C extension. On desktop it is a file, which lets the harness — and a human debugging by
hand — drive the same code path. The transport is the only part that differs.
"""

from __future__ import annotations

import json
import os
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
