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

# Finding the tool is fiddlier than it looks, because "bash" on Windows can be Git Bash
# (paths like /c/Users/... or C:/Users/...) or WSL (/mnt/c/Users/...), and the same
# directory has a different spelling in each. Try every spelling rather than assuming
# which bash the user happens to have first on PATH.
SYSLOG=""
IDEVICE_ID=""

# Derive the Windows user directory from whichever variable this shell exposes.
WINHOME_RAW="${USERPROFILE:-${HOME:-}}"
WINHOME_TAIL="$(printf '%s' "$WINHOME_RAW" | tr '\\' '/' | sed 's|^[A-Za-z]:||')"

CANDIDATES=""
[ -n "${VNPLAYER_IMOBILEDEVICE:-}" ] && CANDIDATES="$VNPLAYER_IMOBILEDEVICE"
for prefix in "C:" "/c" "/mnt/c"; do
    CANDIDATES="$CANDIDATES ${prefix}${WINHOME_TAIL}/tools/libimobiledevice"
    CANDIDATES="$CANDIDATES ${prefix}/Users/$(whoami)/tools/libimobiledevice"
done
CANDIDATES="$CANDIDATES ${HOME:-}/tools/libimobiledevice"

for dir in $CANDIDATES; do
    if [ -x "$dir/idevicesyslog.exe" ]; then
        SYSLOG="$dir/idevicesyslog.exe"
        IDEVICE_ID="$dir/idevice_id.exe"
        break
    fi
done

if [ -z "$SYSLOG" ] && command -v idevicesyslog >/dev/null 2>&1; then
    SYSLOG="$(command -v idevicesyslog)"
    IDEVICE_ID="$(command -v idevice_id)"
fi

if [ -z "$SYSLOG" ]; then
    echo "idevicesyslog not found. Looked in:" >&2
    for dir in $CANDIDATES; do echo "  $dir" >&2; done
    echo "  ...and on PATH" >&2
    echo >&2
    echo "Set VNPLAYER_IMOBILEDEVICE to its directory if it lives elsewhere." >&2
    echo "Note: this needs Git Bash, not WSL — WSL cannot reach the USB device." >&2
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
