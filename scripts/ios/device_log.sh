#!/usr/bin/env bash
# Streams a connected iPhone's system log to logs/, where Ren'Py's own output lands.
#
# On iOS Ren'Py never writes log.txt: renpy/log.py:79 sets the log file to real stdout
# when renpy.ios is true, and the renios shell routes stdout through NSLog
# (prototype/Log.m). So the engine's log is the DEVICE CONSOLE, and this is how you read
# it. There is no file on the phone to go and fetch.
#
# Usage:
#   bash scripts/ios/device_log.sh            # stream until Ctrl-C
#   bash scripts/ios/device_log.sh 30         # capture for 30 seconds, then stop
#
# Requires libimobiledevice for Windows and Apple's Mobile Device Support (ships with
# iTunes). The phone must be unlocked and paired.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOGS="$ROOT/logs"
SECONDS_TO_CAPTURE="${1:-}"

# Honour an explicit override, else look where setup put it, else hope it is on PATH.
TOOLS="${VNPLAYER_IMOBILEDEVICE:-C:/Users/user/tools/libimobiledevice}"

if [ -x "$TOOLS/idevicesyslog.exe" ]; then
    SYSLOG="$TOOLS/idevicesyslog.exe"
    IDEVICE_ID="$TOOLS/idevice_id.exe"
elif command -v idevicesyslog >/dev/null 2>&1; then
    SYSLOG="$(command -v idevicesyslog)"
    IDEVICE_ID="$(command -v idevice_id)"
else
    echo "idevicesyslog not found." >&2
    echo "Expected it at $TOOLS, or on PATH." >&2
    echo "Set VNPLAYER_IMOBILEDEVICE to its directory if it lives elsewhere." >&2
    exit 1
fi

# Fail early with a useful message rather than letting the relay hang on no device.
if ! "$IDEVICE_ID" -l 2>/dev/null | grep -q .; then
    echo "No device detected." >&2
    echo "Check: cable connected, phone unlocked, and 'Trust This Computer' accepted." >&2
    exit 1
fi

mkdir -p "$LOGS"
OUT="$LOGS/device.log"

echo "Writing to $OUT"
echo "Launch VNPlayer on the phone now; its output appears here."

if [ -n "$SECONDS_TO_CAPTURE" ]; then
    echo "Capturing for ${SECONDS_TO_CAPTURE}s..."
    # idevicesyslog exits non-zero when timeout kills it; that is the normal path here.
    timeout "$SECONDS_TO_CAPTURE" "$SYSLOG" --no-colors -o "$OUT" || true
    echo "Captured $(wc -l < "$OUT") lines."
    echo
    echo "=== lines mentioning VNPlayer, Ren'Py or Python ==="
    grep -iE "vnplayer|renpy|python|vnshell" "$OUT" | head -40 || echo "(none matched)"
else
    echo "Streaming until Ctrl-C..."
    "$SYSLOG" --no-colors -o "$OUT"
fi
