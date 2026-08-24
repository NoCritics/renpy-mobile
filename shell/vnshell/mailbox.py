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
        self._last_report: str | None = None

    def poll(self) -> list[Command]:
        """Return pending commands.

        Never raises. A broken transport must not take down a running game — a user
        mid-novel should not lose their session because a command channel failed.

        The guarantee covers *processing* as well as receiving. `Transport.receive()`
        is a static type hint with no runtime enforcement, so a transport that
        conforms in name can still hand back a list containing a non-dict — and the
        iOS bridge this module exists to prepare for deserializes data we do not
        control. Each entry is therefore converted defensively and in isolation, so
        one bad entry cannot discard the good ones beside it.
        """

        try:
            raw = self.transport.receive()
        except Exception as exc:
            self._report(f"transport.receive() failed: {exc!r}")
            return []

        commands: list[Command] = []

        for entry in raw:
            try:
                command = self._to_command(entry)
            except Exception as exc:
                self._report(f"could not convert entry {entry!r}: {exc!r}")
                continue

            if command is not None:
                commands.append(command)

        return commands

    def _to_command(self, entry: object) -> Command | None:
        """Convert one raw entry, or return None if it is not a usable command."""

        if not isinstance(entry, dict):
            self._report(f"ignoring non-dict entry {entry!r}")
            return None

        name = entry.get("name")
        if not name:
            return None

        args = entry.get("args") or {}
        if not isinstance(args, dict):
            args = {}

        return Command(name=str(name), args=args)

    def _report(self, message: str) -> None:
        """Record a fault once.

        Silence is the dangerous failure here: a permanently broken command channel
        would otherwise present as "the buttons do nothing" with no trail at all. But
        poll() runs every frame, so an unconditional print would emit sixty lines a
        second for as long as the fault lasts. Consecutive identical messages are
        therefore reported once. On iOS, stdout is already routed to the system log by
        Ren'Py's iossupport module.
        """

        if message == self._last_report:
            return

        self._last_report = message
        print(f"[vnshell] mailbox: {message}")


MAILBOX = Mailbox(NullTransport())
