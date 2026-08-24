#!/usr/bin/env bash
# Overlays the shell layer proven in Milestone A into the generated base/.
# Mirrors scripts/make_rig.sh, which does the same for the desktop rig.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$(find "$ROOT/build/xcode" -maxdepth 2 -type d -name base | head -1)"
[ -n "$BASE" ] || { echo "No base/ under build/xcode; run generate_xcode.sh first" >&2; exit 1; }

echo "Overlaying shell layer into $BASE"

# Ren'Py's ios_populate writes its own base/main.py for the ios package: it is a
# shebang-stripped copy of the SDK's top-level renpy.py (launcher/game/ios.rpy's
# ios_populate(), fed by renpy/common/00build.rpy's package("ios", "directory",
# "ios all", ...) and distribute.rpy's scan_and_classify()/rename()). Ours replaces it.
cp "$ROOT/shell/main.py" "$BASE/main.py"

# Copy shell/vnshell/ sources only. __pycache__/ and *.pyc are excluded: a developer's
# Mac may hold CPython 3.14 bytecode there (git-ignored, so a clean CI checkout never
# has it -- this only bites on a dev machine), while iOS runs CPython 3.12. Shipping
# mismatched bytecode into the bundle is dead weight at best. Ren'Py's own ios_populate
# calls eliminate_pycache() on its distribution for the same reason
# (launcher/game/ios.rpy:159) -- match that. cp -R first, then prune, because BSD/macOS
# cp has no --exclude flag; the end state is identical to a filtered copy.
rm -rf "$BASE/vnshell"
cp -R "$ROOT/shell/vnshell" "$BASE/vnshell"
find "$BASE/vnshell" -type d -name "__pycache__" -exec rm -rf {} +
find "$BASE/vnshell" -type f -name "*.pyc" -delete

echo "=== overlay result ==="
ls -la "$BASE/main.py" "$BASE/vnshell"

echo "=== explicit assertions (a listing above is not a check) ==="

# "base/main.py exists" proves nothing on its own -- it existed, as Ren'Py's own
# generated launcher, before this script ran too. The discriminating marker is
# NoGameDirectory: a custom exception class defined only in shell/main.py. Confirmed
# absent from vendor/renpy-8.5.3-sdk/renpy.py (the exact file ios_populate copies into
# base/main.py) by direct inspection of the SDK source before relying on it here --
# see docs/IOS-BUILD.md for how this was confirmed. path_to_renpy_base /
# path_to_gamedir / path_to_common / path_to_saves would NOT discriminate: renpy.py
# defines functions of those same names, by design (shell/main.py mirrors renpy.py's
# structure so Ren'Py's bootstrap can call it the same way).
[ -f "$BASE/main.py" ] || { echo "ASSERT FAILED: $BASE/main.py does not exist" >&2; exit 1; }
grep -q "NoGameDirectory" "$BASE/main.py" || {
    echo "ASSERT FAILED: $BASE/main.py does not contain 'NoGameDirectory' -- this is Ren'Py's stock launcher, not ours" >&2
    exit 1
}
echo "OK: base/main.py is ours (contains NoGameDirectory)"

[ -d "$BASE/vnshell" ] || { echo "ASSERT FAILED: $BASE/vnshell does not exist" >&2; exit 1; }
# All seven modules, not just the five originally listed: __init__.py is what makes
# vnshell a package (its absence breaks "import vnshell" outright -- exactly the failure
# this task exists to catch), and harness.py is as much a part of the shell as the rest.
for f in __init__.py harness.py lifecycle.py purge.py mailbox.py state.py transports.py; do
    [ -f "$BASE/vnshell/$f" ] || { echo "ASSERT FAILED: $BASE/vnshell/$f does not exist" >&2; exit 1; }
done
echo "OK: base/vnshell/ contains __init__.py, harness.py, lifecycle.py, purge.py, mailbox.py, state.py, transports.py"

# base/game/ and base/renpy/ are needed for shell/main.py's own path_to_gamedir() /
# path_to_common() and "import renpy.bootstrap" to succeed at startup -- necessary,
# not sufficient on their own, but the app cannot boot without them either.
[ -d "$BASE/game" ] && [ -n "$(ls -A "$BASE/game")" ] || {
    echo "ASSERT FAILED: base/game is missing or empty -- the app will fail with NoGameDirectory" >&2
    exit 1
}
echo "OK: base/game/ exists and is non-empty"

[ -d "$BASE/renpy" ] || { echo "ASSERT FAILED: base/renpy does not exist -- 'import renpy.bootstrap' would fail" >&2; exit 1; }
echo "OK: base/renpy/ exists"

echo "Overlay complete: $BASE/main.py and $BASE/vnshell/ are ours."
