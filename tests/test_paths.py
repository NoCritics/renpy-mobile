# tests/test_paths.py
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "shell"))

import main as vnmain  # noqa: E402


class PathToGamedirTests(unittest.TestCase):
    def test_returns_game_subdirectory_when_present(self):
        with tempfile.TemporaryDirectory() as base:
            os.mkdir(os.path.join(base, "game"))
            self.assertEqual(
                vnmain.path_to_gamedir(base, "irrelevant"),
                os.path.join(base, "game"),
            )

    def test_raises_when_game_subdirectory_absent(self):
        with tempfile.TemporaryDirectory() as base:
            with self.assertRaises(vnmain.NoGameDirectory):
                vnmain.path_to_gamedir(base, "irrelevant")

    def test_ignores_executable_name_candidates(self):
        # Stock Ren'Py would accept a directory named after the executable.
        # We must not: only "game" counts.
        with tempfile.TemporaryDirectory() as base:
            os.mkdir(os.path.join(base, "myapp"))
            with self.assertRaises(vnmain.NoGameDirectory):
                vnmain.path_to_gamedir(base, "myapp")


if __name__ == "__main__":
    unittest.main()
