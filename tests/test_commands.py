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


class RecordingEmitter:
    def __init__(self):
        self.events = []
        self.directory = ""

    def emit(self, payload):
        self.events.append(payload)
        return True


class FakeAPI:
    """Just enough of renpy.exports to exercise the showMenu routing.

    A mock proves routing, and nothing more. It CANNOT prove these names exist -- the
    handlers' first version had passing tests around a fake built to match the same wrong
    assumption the code made. `tests/test_renpy_api.py` is what covers that, by checking
    every name in `RENPY_API_NAMES` against the real SDK's export list.
    """

    def __init__(self, *, screens=(), labels=(), in_menu=False):
        self.screens = set(screens)
        self.labels = set(labels)
        self._context = types.SimpleNamespace(_menu=in_menu)
        self.calls = []

    def has_screen(self, name):
        return name in self.screens

    def has_label(self, name):
        return name in self.labels

    def context(self):
        return self._context

    def game_menu(self, screen=None):
        self.calls.append(("game_menu", screen))

    def show_screen(self, name, **kwargs):
        self.calls.append(("show_screen", name, kwargs))

    def restart_interaction(self):
        self.calls.append(("restart_interaction",))


class ShowMenuTests(unittest.TestCase):
    """Opening the game's OWN Save, Load and Preferences pages."""

    def setUp(self):
        self._real_renpy = sys.modules.get("renpy")
        self._real_api = lifecycle._api
        self._real_events = lifecycle._EVENTS
        self.events = RecordingEmitter()
        lifecycle._EVENTS = self.events
        sys.modules["renpy"] = fake_renpy()

    def tearDown(self):
        lifecycle._api = self._real_api
        lifecycle._EVENTS = self._real_events
        if self._real_renpy is None:
            sys.modules.pop("renpy", None)
        else:
            sys.modules["renpy"] = self._real_renpy

    def run_command(self, api, screen, command_id="c1"):
        lifecycle._api = lambda: api
        lifecycle._handle_show_menu(
            Command(name="showMenu", args={"commandId": command_id, "screen": screen}))
        return self.events.events

    def failures(self):
        return [e for e in self.events.events if e["event"] == "commandFailed"]

    def test_from_play_it_enters_a_new_context(self):
        api = FakeAPI(screens={"preferences"}, in_menu=False)
        self.run_command(api, "preferences")

        self.assertEqual(api.calls, [("game_menu", "preferences")])
        self.assertEqual(self.failures(), [])

    def test_inside_the_menu_it_switches_pages_instead_of_nesting(self):
        # The distinction that matters: a second game_menu() from inside the menu stacks
        # a second context, and the reader needs two dismissals to get back to the game.
        api = FakeAPI(screens={"save", "load"}, in_menu=True)
        self.run_command(api, "load")

        self.assertEqual(
            api.calls,
            [("show_screen", "load", {"_transient": True}), ("restart_interaction",)])
        self.assertNotIn("game_menu", [c[0] for c in api.calls])

    def test_a_label_page_falls_back_to_the_screen_suffix(self):
        # Ren'Py's own rule: if neither a screen nor a label matches, try "<name>_screen".
        api = FakeAPI(labels={"preferences_screen"}, in_menu=False)
        self.run_command(api, "preferences")

        self.assertEqual(api.calls, [("game_menu", "preferences_screen")])

    def test_a_missing_page_is_refused_in_words(self):
        api = FakeAPI(in_menu=False)
        self.run_command(api, "load")

        failures = self.failures()
        self.assertEqual(len(failures), 1)
        self.assertIn("load", failures[0]["reason"])
        self.assertEqual(api.calls, [])

    def test_an_unknown_screen_name_is_refused(self):
        api = FakeAPI(screens={"save", "load", "preferences"})
        self.run_command(api, "history")

        self.assertEqual(len(self.failures()), 1)
        self.assertEqual(api.calls, [])

    def test_save_obeys_the_same_guard_as_quick_save(self):
        sys.modules["renpy"] = fake_renpy(main_menu=True)
        api = FakeAPI(screens={"save"}, in_menu=True)
        self.run_command(api, "save")

        failures = self.failures()
        self.assertEqual(len(failures), 1)
        self.assertIn("main menu", failures[0]["reason"])
        self.assertEqual(api.calls, [])

    def test_load_and_preferences_still_work_at_the_main_menu(self):
        # They are legitimate there -- Ren'Py's own main menu offers both. Only save is
        # refused, so the guard must not be applied to all three.
        sys.modules["renpy"] = fake_renpy(main_menu=True)
        api = FakeAPI(screens={"load", "preferences"}, in_menu=True)
        self.run_command(api, "load")

        self.assertEqual(self.failures(), [])
        self.assertEqual(api.calls[0][0], "show_screen")

    def test_a_label_page_inside_the_menu_says_so_rather_than_doing_nothing(self):
        api = FakeAPI(labels={"save"}, in_menu=True)
        self.run_command(api, "save")

        failures = self.failures()
        self.assertEqual(len(failures), 1)
        self.assertIn("its own menu", failures[0]["reason"])
        self.assertEqual(api.calls, [])

    def test_every_refusal_is_a_sentence(self):
        for api, screen in ((FakeAPI(), "load"), (FakeAPI(), "history")):
            self.events.events = []
            self.run_command(api, screen)
            reason = self.failures()[0]["reason"]
            self.assertGreater(len(reason.split()), 3, reason)


class EngineStateTests(unittest.TestCase):
    def setUp(self):
        self._real_renpy = sys.modules.get("renpy")
        self._real_api = lifecycle._api
        self._real_events = lifecycle._EVENTS
        self.events = RecordingEmitter()
        self.events.directory = "somewhere"
        lifecycle._EVENTS = self.events
        lifecycle._last_state = None

    def tearDown(self):
        lifecycle._api = self._real_api
        lifecycle._EVENTS = self._real_events
        lifecycle._last_state = None
        if self._real_renpy is None:
            sys.modules.pop("renpy", None)
        else:
            sys.modules["renpy"] = self._real_renpy

    def test_in_menu_is_published(self):
        sys.modules["renpy"] = fake_renpy()
        api = FakeAPI(in_menu=True)
        api.can_rollback = lambda: True
        lifecycle._api = lambda: api

        lifecycle._publish_engine_state()

        self.assertEqual(len(self.events.events), 1)
        self.assertTrue(self.events.events[0]["inMenu"])

    def test_unchanged_state_is_not_republished(self):
        sys.modules["renpy"] = fake_renpy()
        api = FakeAPI(in_menu=False)
        api.can_rollback = lambda: False
        lifecycle._api = lambda: api

        lifecycle._publish_engine_state()
        lifecycle._publish_engine_state()

        self.assertEqual(len(self.events.events), 1)


if __name__ == "__main__":
    unittest.main()
