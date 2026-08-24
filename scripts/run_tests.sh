#!/usr/bin/env bash
# Runs the unit suite.
#
# Deliberately NOT vendor/renpy-8.5.3-sdk/lib/py3-windows-x86_64/python.exe: the SDK
# ships a stripped, .pyc-only stdlib with no unittest module. That interpreter's job is
# running Ren'Py. Everything under test here is pure stdlib with no Ren'Py import at
# module scope, so a system CPython is both sufficient and correct.
#
# Never "fix" this by copying packages into vendor/: that tree is checksum-verified and
# fetch_deps.sh deletes it wholesale on any repair, so the fix would silently vanish.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

find_python() {
    for candidate in "${VNPLAYER_TEST_PYTHON:-}" python3 python py; do
        [ -n "$candidate" ] || continue
        command -v "$candidate" >/dev/null 2>&1 || continue
        # Probe for real: Windows ships a `python3` shim that exits non-zero and
        # advertises the Microsoft Store instead of running anything.
        if "$candidate" -c 'import sys, unittest; sys.exit(0 if sys.version_info >= (3, 10) else 1)' >/dev/null 2>&1; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

if ! PY="$(find_python)"; then
    echo "No suitable Python found." >&2
    echo "Need CPython 3.10+ with unittest on PATH, or set VNPLAYER_TEST_PYTHON." >&2
    echo "The Ren'Py SDK's bundled interpreter cannot be used: stripped stdlib, no unittest." >&2
    exit 1
fi

echo "Testing with: $("$PY" -c 'import sys; print(sys.executable, sys.version.split()[0])')"

cd "$ROOT"
exec "$PY" -m unittest discover -s tests -v "$@"
