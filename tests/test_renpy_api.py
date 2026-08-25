# tests/test_renpy_api.py
"""Guards the boundary between the `renpy` PACKAGE and `renpy.exports`.

The distinction is easy to miss and cost a device round-trip. `renpy/defaultstore.py:481`
does::

    globals()["renpy"] = renpy.exports

so inside a `.rpy` file the name `renpy` already *is* `renpy.exports`. Every example in
Ren'Py's documentation therefore writes `renpy.save(...)`, and the identical line fails
from a plain Python module, where `import renpy` yields the package -- which has `config`,
`game` and `loadsave`, but none of `save`, `load`, `rollback`, `can_rollback`,
`restart_interaction` or `music`.

On device that produced two unrelated-looking symptoms from one cause: "could not change
skipping (AttributeError)" while skipping visibly worked, and Roll back plus Quick save
permanently greyed out because the engine-state publisher died before emitting anything.

A mocked `renpy` cannot catch this -- the first attempt at these handlers had unit tests
that passed, because the fake was built to match the same wrong assumption the code made.
So this test reads the real SDK's export list instead.
"""

import io
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "shell"))

from vnshell import lifecycle  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE = os.path.join(HERE, "protocol", "renpy-exports.txt")
SDK_EXPORTS = os.path.join(
    HERE, "..", "vendor", "renpy-8.5.3-sdk", "renpy", "exports", "__init__.py"
)


def load_fixture():
    with io.open(FIXTURE, encoding="utf-8") as f:
        return {line.strip() for line in f if line.strip()}


def parse_sdk_exports():
    """Names re-exported by renpy/exports/__init__.py, read from the SDK itself."""
    import ast

    with io.open(SDK_EXPORTS, encoding="utf-8") as f:
        tree = ast.parse(f.read())

    names = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom):
            for alias in node.names:
                names.add(alias.asname or alias.name)
        elif isinstance(node, ast.Import):
            for alias in node.names:
                if alias.asname:
                    names.add(alias.asname)
    return {n for n in names if not n.startswith("_")}


class ExportedNameTests(unittest.TestCase):
    def test_the_fixture_is_not_empty(self):
        # Without this the comparisons below would pass over an empty file, which is the
        # shape of a check that cannot fail.
        names = load_fixture()
        self.assertGreater(len(names), 200, "the exported-names fixture looks truncated")

    def test_every_api_we_call_is_actually_exported(self):
        exported = load_fixture()

        for name in lifecycle.RENPY_API_NAMES:
            self.assertIn(
                name,
                exported,
                f"lifecycle calls renpy.exports.{name}, which the SDK does not export",
            )

    def test_the_names_we_call_are_NOT_on_the_package(self):
        # The actual trap, stated as a test. These live on renpy.exports only; reaching
        # them through `import renpy` raises AttributeError at run time, on device,
        # inside a frame callback where the traceback is invisible.
        package_only = {"config", "game", "loadsave", "bootstrap", "store"}
        for name in lifecycle.RENPY_API_NAMES:
            self.assertNotIn(
                name,
                package_only,
                f"{name} was treated as a package attribute; it is an export",
            )

    @unittest.skipUnless(os.path.exists(SDK_EXPORTS), "Ren'Py SDK not fetched")
    def test_the_fixture_still_matches_the_sdk(self):
        # vendor/ is gitignored, so this only runs where the SDK has been fetched. The
        # test above runs everywhere and is the one that guards the code; this one keeps
        # the fixture from going stale under an SDK upgrade.
        self.assertEqual(
            load_fixture(),
            parse_sdk_exports(),
            "tests/protocol/renpy-exports.txt is out of date with the vendored SDK",
        )


if __name__ == "__main__":
    unittest.main()
