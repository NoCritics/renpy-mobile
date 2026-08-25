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
    # Faults are reported at most this many times per Mailbox, ever.
    REPORT_LIMIT = 20

    def __init__(self, transport: Transport) -> None:
        self.transport = transport
        self._last_report: str | None = None
        self._reports_emitted = 0

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
            # Report it. This branch used to return None silently, and that cost a
            # device round-trip: the Swift side wrote {"command": "launch", ...} instead
            # of {"name": "launch", "args": {...}}, every command was consumed and
            # discarded here without a trace, and the symptom on the phone was a launch
            # that did nothing at all until it timed out. A command channel that drops
            # malformed messages in silence is indistinguishable from one that is not
            # running.
            self._report(f"entry has no 'name' key, ignoring: {entry!r}")
            return None

        args = entry.get("args") or {}
        if not isinstance(args, dict):
            args = {}

        return Command(name=str(name), args=args)

    def _report(self, message: str) -> None:
        """Record a fault, without ever becoming the problem itself.

        Silence is the dangerous failure here: a permanently broken command channel
        would otherwise present as "the buttons do nothing" with no trail at all. But
        poll() runs every frame, so unconditional printing would emit sixty lines a
        second for as long as the fault lasts.

        Two throttles, because one is not enough. Suppressing consecutive duplicates
        handles the common case, where a deterministic bug raises the same exception
        every call. It does nothing for varied faults — a transport feeding back a
        different malformed payload each frame produces a different message each
        frame, since the message embeds the offending entry. The absolute cap covers
        that, and every other variety we have not thought of.

        On iOS, stdout is already routed to the system log by Ren'Py's iossupport
        module, so print is the right primitive.
        """

        if message == self._last_report:
            return

        self._last_report = message

        if self._reports_emitted >= self.REPORT_LIMIT:
            return

        self._reports_emitted += 1

        if self._reports_emitted == self.REPORT_LIMIT:
            print(f"[vnshell] mailbox: {message}")
            print("[vnshell] mailbox: report limit reached, further faults suppressed")
        else:
            print(f"[vnshell] mailbox: {message}")


MAILBOX = Mailbox(NullTransport())
