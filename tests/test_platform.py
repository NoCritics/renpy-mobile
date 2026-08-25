# tests/test_platform.py
import os
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "shell"))

import main as vnmain  # noqa: E402
from vnshell import platform as vnplatform  # noqa: E402
from vnshell.state import STATE  # noqa: E402


class EnvIsolated(unittest.TestCase):
    """Every test here reads process environment, so none may leak into the next."""

    KEYS = ("RENPY_PLATFORM", "VNPLAYER_DATA_ROOT", "VNPLAYER_SAVES_ROOT")

    def setUp(self):
        self._saved = {k: os.environ.get(k) for k in self.KEYS}
        for k in self.KEYS:
            os.environ.pop(k, None)

    def tearDown(self):
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


class IsIosTests(EnvIsolated):
    def test_false_when_unset(self):
        self.assertFalse(vnplatform.is_ios())

    def test_true_for_the_value_renios_actually_sets(self):
        # Not an invented sentinel: this exact string was read out of the shipped
        # librenpython.a, and it is the same variable renpy/__init__.py:168 tests.
        os.environ["RENPY_PLATFORM"] = "ios-arm64"
        self.assertTrue(vnplatform.is_ios())

    def test_false_for_other_platforms(self):
        for value in ("windows-x86_64", "linux-x86_64", "android-arm64", ""):
            with self.subTest(value=value):
                os.environ["RENPY_PLATFORM"] = value
                self.assertFalse(vnplatform.is_ios())


class DataRootTests(EnvIsolated):
    def test_returns_fallback_off_ios(self):
        self.assertEqual(vnplatform.data_root("/desktop/base"), "/desktop/base")

    def test_override_wins_over_fallback(self):
        os.environ["VNPLAYER_DATA_ROOT"] = "/scratch"
        self.assertEqual(vnplatform.data_root("/desktop/base"), "/scratch")

    def test_override_wins_over_ios_detection(self):
        os.environ["RENPY_PLATFORM"] = "ios-arm64"
        os.environ["VNPLAYER_DATA_ROOT"] = "/scratch"
        self.assertEqual(vnplatform.data_root("/bundle/base"), "/scratch")

    def test_ios_redirects_into_the_home_container(self):
        os.environ["RENPY_PLATFORM"] = "ios-arm64"
        with mock.patch("os.path.expanduser", return_value="/var/mobile/Data"):
            self.assertEqual(
                vnplatform.data_root("/bundle/base"),
                os.path.join("/var/mobile/Data", "Documents"),
            )

    def test_ios_never_returns_the_fallback(self):
        # The whole point: on iOS the fallback is inside the read-only bundle, so
        # returning it is the bug this module exists to prevent.
        os.environ["RENPY_PLATFORM"] = "ios-arm64"
        with mock.patch("os.path.expanduser", return_value="/var/mobile/Data"):
            self.assertNotEqual(vnplatform.data_root("/bundle/base"), "/bundle/base")


class EnsureDirTests(unittest.TestCase):
    def test_creates_missing_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = os.path.join(tmp, "a", "b")
            self.assertEqual(vnplatform.ensure_dir(target), target)
            self.assertTrue(os.path.isdir(target))

    def test_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = os.path.join(tmp, "a")
            vnplatform.ensure_dir(target)
            self.assertEqual(vnplatform.ensure_dir(target), target)
            self.assertTrue(os.path.isdir(target))

    def test_returns_path_even_when_creation_fails(self):
        # Raising here would abort bootstrap before anything could be displayed, so the
        # contract is "hand back the path and let the caller's write fail visibly".
        with mock.patch("os.makedirs", side_effect=OSError("read-only file system")):
            self.assertEqual(vnplatform.ensure_dir("/bundle/saves"), "/bundle/saves")


class PathToSavesTests(EnvIsolated):
    def setUp(self):
        super().setUp()
        self._saved_state = (STATE.saves_root, STATE.current_game_id)

    def tearDown(self):
        STATE.saves_root, STATE.current_game_id = self._saved_state
        super().tearDown()

    def test_uses_game_id_under_saves_root_when_a_game_is_loaded(self):
        with tempfile.TemporaryDirectory() as tmp:
            STATE.saves_root = os.path.join(tmp, "Saves")
            STATE.current_game_id = "some-game"
            result = vnmain.path_to_saves(os.path.join(tmp, "Games", "some-game"))
            self.assertEqual(result, os.path.join(tmp, "Saves", "some-game"))
            self.assertTrue(os.path.isdir(result))

    def test_desktop_fallback_stays_beside_the_game(self):
        with tempfile.TemporaryDirectory() as tmp:
            STATE.saves_root = ""
            STATE.current_game_id = None
            gamedir = os.path.join(tmp, "game")
            os.makedirs(gamedir)
            self.assertEqual(
                vnmain.path_to_saves(gamedir), os.path.join(gamedir, "saves")
            )

    def test_ios_fallback_leaves_the_read_only_bundle(self):
        # The regression this whole change exists for. Device-measured before the fix:
        #   deny(1) file-write-create .../VNPlayer.app/base/game/saves
        with tempfile.TemporaryDirectory() as tmp:
            STATE.saves_root = ""
            STATE.current_game_id = None
            os.environ["RENPY_PLATFORM"] = "ios-arm64"
            os.environ["VNPLAYER_DATA_ROOT"] = tmp

            bundle_gamedir = "/var/containers/Bundle/Application/X/VNPlayer.app/base/game"
            result = vnmain.path_to_saves(bundle_gamedir)

            self.assertFalse(result.startswith(bundle_gamedir))
            # Not Documents any more, and not by accident: the library screen is a Ren'Py
            # project that autosaves, so its own save files were piling up in the folder
            # the reader browses, mixed in with her real ones.
            self.assertEqual(
                result, os.path.join(tmp, "Application Support", "shell-saves"))
            self.assertTrue(os.path.isdir(result))


class PathToLogdirTests(EnvIsolated):
    def test_desktop_returns_basedir(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(vnmain.path_to_logdir(tmp), tmp)

    def test_ios_leaves_the_read_only_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            os.environ["RENPY_PLATFORM"] = "ios-arm64"
            os.environ["VNPLAYER_DATA_ROOT"] = tmp

            basedir = "/var/containers/Bundle/Application/X/VNPlayer.app/base"
            result = vnmain.path_to_logdir(basedir)

            self.assertFalse(result.startswith(basedir))
            self.assertEqual(result, tmp)


if __name__ == "__main__":
    unittest.main()



class ShellSaveFallbackTests(EnvIsolated):
    """Where saves go when there is no game -- i.e. the library screen itself.

    The library screen is a Ren'Py project like any other, so it inherits Ren'Py's
    defaults, including ``autosave_slots = 10`` (renpy/config.py:328). It writes save
    files whether or not anyone wants them. Observed on device: auto-1, auto-2, 1-1 and
    _reload-1 loose in Documents beside Games/ and Saves/, among the reader's real saves
    and distinguishable only by being smaller.

    Documents is exposed to the Files app deliberately -- the right home for her games
    and saves, and the wrong home for ours.
    """

    def test_the_no_game_fallback_stays_out_of_documents_on_ios(self):
        with tempfile.TemporaryDirectory() as tmp:
            STATE.saves_root = ""
            STATE.current_game_id = None
            os.environ["RENPY_PLATFORM"] = "ios-arm64"
            os.environ["VNPLAYER_DATA_ROOT"] = tmp

            result = vnmain.path_to_saves("/var/containers/.../base/game")

            self.assertNotIn(
                "Documents", result.replace("\\", "/").split("/"),
                f"the library screen's saves land where the reader browses: {result}")

    def test_a_real_game_is_unaffected(self):
        # The guard that keeps this change honest: moving the no-game fallback must not
        # move a game's actual saves, which stay per-game under the exposed Saves root.
        with tempfile.TemporaryDirectory() as tmp:
            STATE.saves_root = os.path.join(tmp, "Saves")
            STATE.current_game_id = "bigbaddogs"
            os.environ["RENPY_PLATFORM"] = "ios-arm64"
            os.environ["VNPLAYER_DATA_ROOT"] = tmp

            result = vnmain.path_to_saves("/var/containers/.../base/game")

            self.assertEqual(result, os.path.join(tmp, "Saves", "bigbaddogs"))

    def test_off_ios_the_fallback_is_unchanged(self):
        # The desktop cycling harness validated 200 game switches against <gamedir>/saves.
        # Nothing about the iOS layout may move it.
        with tempfile.TemporaryDirectory() as tmp:
            STATE.saves_root = ""
            STATE.current_game_id = None
            os.environ.pop("RENPY_PLATFORM", None)
            os.environ.pop("VNPLAYER_DATA_ROOT", None)

            gamedir = os.path.join(tmp, "base", "game")
            self.assertEqual(vnmain.path_to_saves(gamedir),
                             os.path.join(gamedir, "saves"))
