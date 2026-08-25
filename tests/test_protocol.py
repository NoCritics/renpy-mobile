# tests/test_protocol.py
"""Pins the Swift <-> Python wire format from the Python side.

This file exists because of a specific, expensive bug. The Swift library wrote

    {"command": "launch", "gameId": ..., "basedir": ...}

while ``vnshell.mailbox._to_command`` has always read ``entry["name"]`` and
``entry["args"]``. Every command was consumed by the transport and then dropped on the
floor by the mailbox -- with no error, because the "no name key" branch returned None in
silence. On the device it presented as a launch button that did nothing at all until it
hit its 60-second timeout. Nothing in either test suite covered the shape of the message
crossing the boundary, so both sides passed their own tests while disagreeing with each
other.

``tests/protocol/*.json`` are the shared fixtures. The Swift suite has a matching test
asserting it *produces* these; this one asserts Python *accepts* them. A change to either
side that is not made to both now fails a test instead of a device.
"""

import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "shell"))

from vnshell import mailbox as mailbox_module  # noqa: E402
from vnshell.mailbox import Mailbox  # noqa: E402

PROTOCOL_DIR = os.path.join(os.path.dirname(__file__), "protocol")


def load(name):
    with open(os.path.join(PROTOCOL_DIR, name), encoding="utf-8") as f:
        return json.load(f)


class StubTransport:
    def __init__(self, entries):
        self.entries = entries

    def receive(self):
        entries, self.entries = self.entries, []
        return entries


class LaunchCommandShapeTests(unittest.TestCase):
    def test_the_fixture_parses_into_a_launch_command(self):
        payload = load("launch-command.json")
        commands = Mailbox(StubTransport([payload])).poll()

        self.assertEqual(len(commands), 1, "the launch command did not survive the mailbox")
        self.assertEqual(commands[0].name, "launch")
        self.assertEqual(commands[0].args["gameId"], "bigbaddogs")
        self.assertTrue(commands[0].args["basedir"].endswith("Games/bigbaddogs"))
        self.assertIn("commandId", commands[0].args)

    def test_a_launch_command_reaches_a_registered_handler(self):
        # Parsing is not the same as dispatching. The bug was upstream of the handler,
        # so assert the whole path, not just the conversion.
        from vnshell import lifecycle

        self.assertIn("launch", lifecycle._HANDLERS)
        self.assertIn("quitToLibrary", lifecycle._HANDLERS)

        payload = load("launch-command.json")
        commands = Mailbox(StubTransport([payload])).poll()
        self.assertIn(commands[0].name, lifecycle._HANDLERS)

    def test_the_flat_shape_is_rejected_AND_reported(self):
        # The exact wrong shape that cost a device round-trip. It must not silently
        # vanish: a command channel that discards malformed messages without a word is
        # indistinguishable from one that is not running at all.
        flat = {
            "command": "launch",
            "gameId": "bigbaddogs",
            "basedir": "/somewhere/Games/bigbaddogs",
        }

        mailbox = Mailbox(StubTransport([flat]))
        commands = mailbox.poll()

        self.assertEqual(commands, [])
        self.assertIsNotNone(
            mailbox._last_report,
            "a command with no 'name' key was dropped without any report",
        )
        self.assertIn("name", mailbox._last_report)

    def test_quit_to_library_shape(self):
        payload = load("quit-command.json")
        commands = Mailbox(StubTransport([payload])).poll()
        self.assertEqual(len(commands), 1)
        self.assertEqual(commands[0].name, "quitToLibrary")


if __name__ == "__main__":
    unittest.main()
