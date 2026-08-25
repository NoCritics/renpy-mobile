# tests/test_commands.py
"""The command queue and the M3 control handlers.

The regression these exist for is specific. `tick()` used to dispatch a whole `poll()`
batch inline, so a handler that restarts the engine raised out of the loop and every
command behind it was destroyed with the frame. That was harmless while both handlers
restarted; M3 adds four that do not, so a rollback queued behind a quick save would have
vanished with no trace.
"""

import os
import sys
import types
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "shell"))

from vnshell import lifecycle  # noqa: E402
from vnshell import mailbox as mailbox_module  # noqa: E402
from vnshell.mailbox import Command, Mailbox  # noqa: E402


class ScriptedTransport:
    """Hands back one batch per receive(), then nothing."""

    def __init__(self, batches):
        self.batches = list(batches)

    def receive(self):
        if not self.batches:
            return []
        return self.batches.pop(0)


class QueueTests(unittest.TestCase):
    def setUp(self):
        self._handlers = dict(lifecycle._HANDLERS)
        self._mailbox = mailbox_module.MAILBOX
        lifecycle._pending.clear()
        lifecycle._announced = True  # skip the ready announcement
        self.ran = []

    def tearDown(self):
        lifecycle._HANDLERS.clear()
        lifecycle._HANDLERS.update(self._handlers)
        mailbox_module.MAILBOX = self._mailbox
        lifecycle._pending.clear()

    def install(self, batches, handlers):
        mailbox_module.MAILBOX = Mailbox(ScriptedTransport(batches))
        lifecycle._HANDLERS.clear()
        lifecycle._HANDLERS.update(handlers)

    def test_one_command_per_tick(self):
        batch = [
            {"name": "a", "args": {}},
            {"name": "b", "args": {}},
            {"name": "c", "args": {}},
        ]
        self.install([batch], {
            "a": lambda c: self.ran.append("a"),
            "b": lambda c: self.ran.append("b"),
            "c": lambda c: self.ran.append("c"),
        })

        lifecycle.tick()
        self.assertEqual(self.ran, ["a"])
        lifecycle.tick()
        self.assertEqual(self.ran, ["a", "b"])
        lifecycle.tick()
        self.assertEqual(self.ran, ["a", "b", "c"])

    def test_a_raising_handler_does_not_lose_the_queue(self):
        # THE regression. Before the queue, a handler that raised took every command
        # behind it with it, silently.
        def boom(command):
            self.ran.append("boom")
            raise RuntimeError("engine restarting")

        batch = [
            {"name": "boom", "args": {}},
            {"name": "after", "args": {}},
        ]
        self.install([batch], {
            "boom": boom,
            "after": lambda c: self.ran.append("after"),
        })

        with self.assertRaises(RuntimeError):
            lifecycle.tick()
        self.assertEqual(self.ran, ["boom"])

        # The frame after the raise: the queued command is still there.
        lifecycle.tick()
        self.assertEqual(self.ran, ["boom", "after"])

    def test_restart_clears_the_queue(self):
        # The opposite requirement, and it is not a contradiction. Commands queued behind
        # a quitToLibrary were aimed at the game being left; carrying a rollback across a
        # switch would apply it to whatever loads next.
        lifecycle._pending.append(Command(name="stale", args={}))
        self.assertEqual(len(lifecycle._pending), 1)

        try:
            lifecycle._restart()
        except BaseException:  # noqa: BLE001 - _restart raises to restart the engine
            pass

        self.assertEqual(lifecycle._pending, [])

    def test_unknown_command_is_reported_not_dropped(self):
        self.install([[{"name": "nonsense", "args": {"commandId": "x"}}]], {})

        lifecycle.tick()

        # A command the shell does not recognise means the two sides disagree about the
        # protocol. Silence made exactly that look like a dead channel once already.
        self.assertIsNotNone(mailbox_module.MAILBOX._last_report)
        self.assertIn("nonsense", mailbox_module.MAILBOX._last_report)


class FakeStore:
    def __init__(self, in_replay=None, main_menu=False):
        self._in_replay = in_replay
        self.main_menu = main_menu


def fake_renpy(*, in_replay=None, main_menu=False, save=True):
    module = types.SimpleNamespace()
    module.store = FakeStore(in_replay=in_replay, main_menu=main_menu)
    module.config = types.SimpleNamespace(save=save, skipping=None)
    return module


class SaveGuardTests(unittest.TestCase):
    """Mirrors Ren'Py's own FileSave.get_sensitive(), which is the authority."""

    def setUp(self):
        self._real = sys.modules.get("renpy")

    def tearDown(self):
        if self._real is None:
            sys.modules.pop("renpy", None)
        else:
            sys.modules["renpy"] = self._real

    def install(self, module):
        sys.modules["renpy"] = module

    def test_allowed_in_a_normal_game(self):
        self.install(fake_renpy())
        self.assertIsNone(lifecycle._save_blocked_reason())

    def test_blocked_during_a_replay(self):
        self.install(fake_renpy(in_replay="some_label"))
        reason = lifecycle._save_blocked_reason()
        self.assertIsNotNone(reason)
        self.assertIn("replay", reason)

    def test_blocked_at_the_main_menu(self):
        self.install(fake_renpy(main_menu=True))
        reason = lifecycle._save_blocked_reason()
        self.assertIsNotNone(reason)
        self.assertIn("main menu", reason)

    def test_blocked_when_the_game_disables_saving(self):
        self.install(fake_renpy(save=False))
        reason = lifecycle._save_blocked_reason()
        self.assertIsNotNone(reason)
        self.assertIn("turned off", reason)

    def test_reasons_are_sentences_a_reader_can_act_on(self):
        # These are rendered verbatim in the overlay. A reason like "ERR_SAVE_DENIED"
        # would be a defect, not a message.
        for module in (fake_renpy(in_replay="x"), fake_renpy(main_menu=True),
                       fake_renpy(save=False)):
            self.install(module)
            reason = lifecycle._save_blocked_reason()
            self.assertTrue(reason[0].islower() or reason[0].isalpha())
            self.assertGreater(len(reason.split()), 3, reason)


if __name__ == "__main__":
    unittest.main()
