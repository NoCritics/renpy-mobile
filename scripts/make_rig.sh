#!/usr/bin/env bash
# Builds .rig/ : a Ren'Py SDK copy with our shell overlay applied.
# Mirrors the iOS bundle layout, where shell/main.py becomes base/main.py.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="$ROOT/vendor/renpy-8.5.3-sdk"
RIG="$ROOT/.rig"

if [ ! -f "$SDK/renpy/bootstrap.py" ]; then
    echo "SDK missing. Run scripts/fetch_deps.sh first." >&2
    exit 1
fi

# Rebuild the overlay every time; only re-copy the SDK when absent, since it is large.
if [ ! -f "$RIG/renpy/bootstrap.py" ]; then
    echo "Copying SDK into $RIG (this takes a minute)..."
    rm -rf "$RIG"
    cp -r "$SDK" "$RIG"
fi

echo "Applying shell overlay..."
rm -rf "$RIG/vnshell"
cp "$ROOT/shell/main.py" "$RIG/main.py"
cp -r "$ROOT/shell/vnshell" "$RIG/vnshell"

rm -rf "$RIG/game"
cp -r "$ROOT/shell-project/game" "$RIG/game"

echo "Rig ready at $RIG"
