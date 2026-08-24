import contextlib
import io
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "shell"))

from vnshell.mailbox import Command, Mailbox  # noqa: E402


class FakeTransport:
    def __init__(self, batches):
        self.batches = list(batches)

    def receive(self):
        return self.batches.pop(0) if self.batches else []


class Exploding:
    def receive(self):
        raise OSError("device on fire")


class MailboxTests(unittest.TestCase):
    def test_converts_dicts_to_commands(self):
        mb = Mailbox(FakeTransport([[{"name": "launch", "args": {"basedir": "/x"}}]]))
        got = mb.poll()
        self.assertEqual(got, [Command(name="launch", args={"basedir": "/x"})])

    def test_missing_args_defaults_to_empty(self):
        mb = Mailbox(FakeTransport([[{"name": "quitToLibrary"}]]))
        self.assertEqual(mb.poll(), [Command(name="quitToLibrary", args={})])

    def test_entry_without_name_is_dropped(self):
        mb = Mailbox(FakeTransport([[{"args": {}}, {"name": "quitToLibrary"}]]))
        self.assertEqual([c.name for c in mb.poll()], ["quitToLibrary"])

    def test_transport_failure_is_swallowed(self):
        # A broken transport must never take down a running game.
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(Mailbox(Exploding()).poll(), [])

    def test_transport_failure_is_reported_once(self):
        # Silence would present a dead command channel as "the buttons do nothing",
        # but poll() runs every frame — so the fault is reported once, not 60x/sec.
        mb = Mailbox(Exploding())
        out = io.StringIO()

        with contextlib.redirect_stdout(out):
            mb.poll()
            mb.poll()
            mb.poll()

        lines = [l for l in out.getvalue().splitlines() if l.strip()]
        self.assertEqual(len(lines), 1)
        self.assertIn("device on fire", lines[0])

    def test_non_dict_entry_does_not_raise(self):
        # Transport.receive()'s return type is a hint, not a guarantee: the iOS
        # bridge deserializes data we do not control. One bad entry must not raise,
        # and must not discard the good entries beside it.
        mb = Mailbox(FakeTransport([["not a dict", None, {"name": "quitToLibrary"}]]))
        out = io.StringIO()

        with contextlib.redirect_stdout(out):
            got = mb.poll()

        self.assertEqual([c.name for c in got], ["quitToLibrary"])
        self.assertIn("non-dict", out.getvalue())


if __name__ == "__main__":
    unittest.main()
