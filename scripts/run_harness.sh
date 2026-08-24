#!/usr/bin/env bash
# One-command cycling harness. Usage: bash scripts/run_harness.sh [cycles]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CYCLES="${1:-10}"
RIG="$ROOT/.rig"
PY="$RIG/lib/py3-windows-x86_64/python.exe"

bash "$ROOT/scripts/make_rig.sh"

rm -rf "$ROOT/harness/out"
mkdir -p "$ROOT/harness/out"

export VNPLAYER_HARNESS_CYCLES="$CYCLES"
export VNPLAYER_HARNESS_GAMES="$ROOT/harness/games"
export VNPLAYER_OBSERVATIONS="$ROOT/harness/out/observations.jsonl"
export VNPLAYER_RSS_LOG="$ROOT/harness/out/rss.jsonl"
export VNPLAYER_SAVES_ROOT="$ROOT/harness/out/saves"

# A timeout is not optional here. The failure this harness exists to detect includes
# "the restart never fires and the engine idles forever" — without a bound, that
# outcome hangs the run instead of reporting it. Budget five seconds per cycle plus a
# minute of startup slack.
TIMEOUT=$(( CYCLES * 5 + 60 ))

echo "Running $CYCLES cycles (timeout ${TIMEOUT}s)..."
set +e
timeout "$TIMEOUT" "$PY" "$RIG/main.py"
STATUS=$?
set -e

if [ "$STATUS" -eq 124 ]; then
    echo "TIMED OUT after ${TIMEOUT}s — the engine never finished the cycle run." >&2
    echo "That usually means a switch did not happen: check harness/out/cycle.txt" >&2
    echo "against the requested $CYCLES, and look for harness/out/*/traceback.txt." >&2
elif [ "$STATUS" -ne 0 ]; then
    echo "Engine exited with status $STATUS (expected 0)." >&2
else
    echo "Engine exited cleanly."
fi

# check.py runs regardless of engine status: a partial run's observations are exactly
# the evidence needed to work out how far the cycling got before it broke.
"$PY" "$ROOT/harness/check.py"
