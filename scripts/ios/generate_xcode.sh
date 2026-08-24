#!/usr/bin/env bash
# Generates an Xcode project from the Ren'Py SDK + renios, headlessly.
#
# Runs Ren'Py's own "ios_create" / "ios_populate" launcher commands
# (launcher/game/ios.rpy). Both take positional arguments (project,
# destination) -- there is no --destination flag, despite what an
# earlier draft of this script assumed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SDK="$ROOT/vendor/renpy-8.5.3-sdk"
RENIOS="$ROOT/vendor/renios"
PROJECT="${1:-$ROOT/shell-project}"
DEST="$ROOT/build/xcode/VNPlayer"

[ -f "$SDK/renpy/bootstrap.py" ] || { echo "SDK missing; run fetch_ios_deps.sh" >&2; exit 1; }
[ -d "$RENIOS" ] || { echo "renios missing; run fetch_ios_deps.sh" >&2; exit 1; }

# The launcher looks for <sdk>/renios and will not proceed without it.
if [ ! -d "$SDK/renios" ]; then
    echo "Placing renios inside the SDK..."
    cp -R "$RENIOS" "$SDK/renios"
fi

PY="$SDK/lib/py3-mac-universal/python"
[ -x "$PY" ] || PY="$(find "$SDK/lib" -maxdepth 2 -name python -type f -perm +111 | head -1)"
[ -x "$PY" ] || { echo "No macOS Python found under $SDK/lib" >&2; exit 1; }

# DEST is the Xcode project directory itself (create_project() calls
# os.makedirs(dest) on it), not a parent to create projects under. Its
# parent must exist and DEST itself must not, or ios_create's
# iface.yesno() prompt fires -- which calls input() and dies with
# EOFError on a runner with no stdin.
rm -rf "$ROOT/build/xcode"
mkdir -p "$ROOT/build/xcode"

# Ren'Py CLI commands other than "run" do not open a window, but force a
# headless video driver anyway so a runner without a display cannot surprise us.
export SDL_VIDEODRIVER=dummy
export SDL_AUDIODRIVER=dummy

echo "=== ios_create ==="
CREATE_START=$(date +%s)
"$PY" "$SDK/renpy.py" "$SDK/launcher" ios_create "$PROJECT" "$DEST"
CREATE_END=$(date +%s)
echo "ios_create took $((CREATE_END - CREATE_START))s"

echo "=== ios_populate ==="
POPULATE_START=$(date +%s)
"$PY" "$SDK/renpy.py" "$SDK/launcher" ios_populate "$PROJECT" "$DEST"
POPULATE_END=$(date +%s)
echo "ios_populate took $((POPULATE_END - POPULATE_START))s"

echo "=== result ==="
find "$DEST" -maxdepth 2 | sort
