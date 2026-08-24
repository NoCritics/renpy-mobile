import os
import sys
import tempfile
import types
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "shell"))

from vnshell.harness import _rss_bytes  # noqa: E402
from vnshell.purge import _purge_modules  # noqa: E402


def _stub_module(name: str, file_path: str | None):
    """A minimal object standing in for a real module in sys.modules.

    _purge_modules only ever reads ``__file__`` off whatever it finds there, so a bare
    ModuleType with that one attribute set is a faithful stand-in — no need to actually
    import anything, and pure-stdlib tests must not import ``renpy``.
    """

    module = types.ModuleType(name)
    module.__file__ = file_path
    return module


class PurgeModulesTests(unittest.TestCase):
    """Coverage for vnshell.purge._purge_modules.

    One of the two functions with a history of shipped bugs (docs/BUILD.md, "Purge
    findings": the first version purged the whole basedir and killed the running
    interpreter's own modules). Pure stdlib, no renpy import at module scope — tests on
    the system CPython exactly like tests/test_paths.py tests main.py.
    """

    def setUp(self):
        self._injected: list[str] = []
        self._tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmpdir.cleanup)
        self.base = self._tmpdir.name

    def tearDown(self):
        for name in self._injected:
            sys.modules.pop(name, None)

    def _inject(self, name: str, file_path: str | None) -> None:
        sys.modules[name] = _stub_module(name, file_path)
        self._injected.append(name)

    def test_purges_module_under_game_directory(self):
        path = os.path.join(self.base, "game", "x.py")
        self._inject("vnshell_test_purge_x", path)

        result = _purge_modules(self.base)

        self.assertNotIn("vnshell_test_purge_x", sys.modules)
        self.assertIn("vnshell_test_purge_x", result)
        self.assertIn("purged 1 modules", result)

    def test_does_not_purge_sibling_game_assets_directory(self):
        # The directory-boundary guard: a bare startswith(root) would also strip
        # <base>/game_assets, since it prefix-matches the string "…/game". Currently
        # protected only by a comment, and a case the harness's sentinel games cannot
        # exercise at all (neither ships such a sibling).
        path = os.path.join(self.base, "game_assets", "y.py")
        self._inject("vnshell_test_purge_y", path)

        _purge_modules(self.base)

        self.assertIn("vnshell_test_purge_y", sys.modules)

    def test_does_not_purge_renpy_directory(self):
        path = os.path.join(self.base, "renpy", "z.py")
        self._inject("vnshell_test_purge_z", path)

        _purge_modules(self.base)

        self.assertIn("vnshell_test_purge_z", sys.modules)

    def test_module_with_none_file_is_skipped_without_raising(self):
        self._inject("vnshell_test_purge_none", None)

        try:
            _purge_modules(self.base)
        except Exception as exc:  # pragma: no cover - failure path
            self.fail(f"_purge_modules raised on a module with __file__ = None: {exc!r}")

        self.assertIn("vnshell_test_purge_none", sys.modules)


class RssBytesTests(unittest.TestCase):
    """Coverage for vnshell.harness._rss_bytes.

    The other function with a history of shipped bugs: a 64-bit HANDLE truncation on
    Windows silently returned 0 for an entire harness run (docs/BUILD.md, "History of
    this baseline", run 1) before check.py was changed to fail loudly on that case.
    """

    def test_returns_positive_int_on_this_platform(self):
        rss = _rss_bytes()

        self.assertIsInstance(rss, int)
        self.assertGreater(rss, 0)


if __name__ == "__main__":
    unittest.main()
