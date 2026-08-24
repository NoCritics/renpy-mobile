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
# Works from Git Bash, WSL, or MSYS. Requires libimobiledevice for Windows and Apple's
# Mobile Device Support (ships with iTunes). The phone must be unlocked and paired.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOGS="$ROOT/logs"
SECONDS_TO_CAPTURE="${1:-}"

# Are we under WSL? A Windows .exe still runs here via interop, but any path we hand it
# has to be a Windows path, because the .exe cannot read /mnt/c/... spellings.
IS_WSL=0
if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; then
    IS_WSL=1
fi

# Finding the tool is fiddlier than it looks: "bash" on Windows may be Git Bash, MSYS or
# WSL, and each spells the same directory differently (/c/..., C:/..., /mnt/c/...). Rather
# than guess the spelling or the username — the Linux user inside WSL is unrelated to the
# Windows one — derive it from $ROOT, which this shell has already spelled correctly.
USER_DIR="$(printf '%s' "$ROOT" | sed -E 's|(.*/Users/[^/]+)/.*|\1|')"

CANDIDATES=""
[ -n "${VNPLAYER_IMOBILEDEVICE:-}" ] && CANDIDATES="$VNPLAYER_IMOBILEDEVICE"
CANDIDATES="$CANDIDATES $ROOT/tools/libimobiledevice"
[ "$USER_DIR" != "$ROOT" ] && CANDIDATES="$CANDIDATES $USER_DIR/tools/libimobiledevice"
CANDIDATES="$CANDIDATES ${HOME:-}/tools/libimobiledevice"

SYSLOG=""
IDEVICE_ID=""
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
    echo "Set VNPLAYER_IMOBILEDEVICE to its directory and re-run." >&2
    exit 1
fi

# Fail early with a useful message rather than letting the relay hang on no device.
if ! "$IDEVICE_ID" -l 2>/dev/null | grep -q .; then
    echo "No device detected." >&2
    echo "Check: cable connected, phone unlocked, and 'Trust This Computer' accepted." >&2
    [ "$IS_WSL" -eq 1 ] && echo "Under WSL the Windows USB service is still used; if this" >&2
    [ "$IS_WSL" -eq 1 ] && echo "persists, try the same command from Git Bash." >&2
    exit 1
fi

# Pull out the parts of a 100k-line system-wide capture that are actually ours.
#
# Note on `grep -m` rather than `grep | head`: under `set -o pipefail`, head closing the
# pipe early sends grep SIGPIPE, the pipeline reports failure, and any `|| echo "none"`
# fallback then prints a flat lie about a grep that in fact matched plenty. That exact
# bug shipped in an earlier version of this script and reported "(none matched)" over a
# capture containing 1,515 matching lines.
summarize_capture() {
    local out="$1"

    echo
    echo "=== Ren'Py's own output (NSLog via renios prototype/Log.m) ==="
    echo "NOTE: iOS redacts NSLog arguments as <private> unless private-data logging is"
    echo "      enabled on the device. Lines below appearing as <private> ARE Ren'Py's"
    echo "      log; the device is hiding the text, not failing to emit it."
    grep -m 20 -E "^[A-Za-z]{3} [0-9]{2} [0-9:.]+ VNPlayer\[[0-9]+\]" "$out" || echo "(none)"

    echo
    echo "=== sandbox denials (what the app tried to do and could not) ==="
    # These are gold: they show real filesystem attempts the read-only bundle refused.
    grep -E "Sandbox: VNPlayer" "$out" | sed -E 's/.*deny\(1\) //' | sort | uniq -c | sort -rn || echo "(none)"

    echo
    echo "=== crashes, jetsam kills and terminations ==="
    grep -m 20 -iE "VNPlayer.*(crash|jetsam|terminat|killed|exhausted|exception)" "$out" || echo "(none)"
}

mkdir -p "$LOGS"
OUT="$LOGS/device.log"

# The tool is a Windows binary, so under WSL it needs the Windows spelling of the output
# path. Everywhere else the path we already have is the one it wants.
if [ "$IS_WSL" -eq 1 ] && command -v wslpath >/dev/null 2>&1; then
    OUT_ARG="$(wslpath -w "$OUT")"
else
    OUT_ARG="$OUT"
fi

echo "Writing to $OUT"
echo "Launch VNPlayer on the phone now; its output appears here."

if [ -n "$SECONDS_TO_CAPTURE" ]; then
    echo "Capturing for ${SECONDS_TO_CAPTURE}s..."
    # idevicesyslog exits non-zero when timeout kills it; that is the normal path here.
    timeout "$SECONDS_TO_CAPTURE" "$SYSLOG" --no-colors -o "$OUT_ARG" || true

    if [ ! -s "$OUT" ]; then
        echo "Capture produced nothing. The relay may not have connected." >&2
        exit 1
    fi

    echo "Captured $(wc -l < "$OUT") lines."
    summarize_capture "$OUT"
else
    echo "Streaming until Ctrl-C..."
    "$SYSLOG" --no-colors -o "$OUT_ARG"
fi
