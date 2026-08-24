"""The command queue between the host UI and the running engine.

While a game is running, Ren'Py owns the main loop and cannot be called into. Commands
are therefore queued by the host and drained by a periodic callback. This module is
transport-agnostic so the same logic runs under the desktop harness and under Swift.
"""

from __future__ import annotations

import dataclasses

from vnshell.transports import NullTransport, Transport


@dataclasses.dataclass(frozen=True)
class Command:
    name: str
    args: dict


class Mailbox:
    def __init__(self, transport: Transport) -> None:
        self.transport = transport

    def poll(self) -> list[Command]:
        """Return pending commands. Never raises — a broken transport must not
        take down a running game."""

        try:
            raw = self.transport.receive()
        except Exception:
            return []

        commands: list[Command] = []

        for entry in raw:
            name = entry.get("name")
            if not name:
                continue
            args = entry.get("args") or {}
            if not isinstance(args, dict):
                args = {}
            commands.append(Command(name=str(name), args=args))

        return commands


MAILBOX = Mailbox(NullTransport())
