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
        class Exploding:
            def receive(self):
                raise OSError("device on fire")

        # A broken transport must never take down a running game.
        self.assertEqual(Mailbox(Exploding()).poll(), [])


if __name__ == "__main__":
    unittest.main()
