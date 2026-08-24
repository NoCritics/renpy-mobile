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
#   bash scripts/ios/device_log.sh 30 --legacy  # ...via the plain-text legacy relay
#
# Works from Git Bash, WSL, or MSYS. Requires libimobiledevice for Windows and Apple's
# Mobile Device Support (ships with iTunes). The phone must be unlocked and paired.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOGS="$ROOT/logs"
SECONDS_TO_CAPTURE="${1:-}"

# Which relay service to read the log through.
#
# The default (os_trace_relay) gives richer, structured output and decodes system
# frameworks well, but it renders THIS app's messages as "<decode: missing data>" -- it is
# not delivering the string payload for a third-party binary's own os_log entries.
#
# The legacy syslog_relay service carries plain text instead, which is what NSLog also
# writes. If our lines come through as "<decode: missing data>", capture again with:
#
#     bash scripts/ios/device_log.sh 30 --legacy
#
# Neither mode is strictly better: legacy loses subsystem tagging and sub-second
# timestamps, so keep the default for iOS-level events like jetsam kills.
RELAY_ARGS=""
RELAY_NAME="os_trace_relay (default)"
if [ "${2:-}" = "--legacy" ] || [ -n "${VNPLAYER_LEGACY_RELAY:-}" ]; then
    RELAY_ARGS="--syslog-relay"
    RELAY_NAME="syslog_relay (legacy, plain text)"
fi

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
# Prints the lines from our process that actually SAY something, and accounts for the
# ones that do not.
#
# This replaced a plain `grep -m 40`, which took the first 40 matching lines in
# chronological order. That was actively misleading rather than merely incomplete: 38 of
# those 40 slots went to "<decode: missing data>" -- lines that by construction carry no
# information -- and the cap then truncated the capture BEFORE
# "[vnspike] overlay installed", the single line the run existed to produce. The summary
# therefore showed no overlay line at all while the raw log contained one, and the
# conclusion it invited ("the overlay never installed") was the opposite of the truth.
#
# So: drop the undecodable lines, show everything that remains, and print the count of
# what was dropped so the suppression is visible rather than silent. If the readable set
# is ever itself too long to show, say so explicitly instead of trimming quietly.
report_readable() {
    local out="$1"
    local ours readable dropped shown
    ours="$(grep -cE "VNPlayer\[[0-9]+\]" "$out" || true)"
    readable="$(grep -E "VNPlayer\[[0-9]+\]" "$out" | grep -vcF "<decode: missing data>" || true)"
    dropped=$(( ours - readable ))

    if [ "$ours" -eq 0 ]; then
        echo "(no lines from our process)"
        return
    fi

    shown="$READABLE_LINE_CAP"
    grep -E "VNPlayer\[[0-9]+\]" "$out" | grep -vF "<decode: missing data>" | head -n "$shown"

    if [ "$readable" -eq 0 ]; then
        echo "(nothing from our process decoded: all $ours lines were <decode: missing data>)"
    elif [ "$readable" -gt "$shown" ]; then
        echo "... $(( readable - shown )) further readable lines not shown; see $out"
    fi
    echo "[$readable readable, $dropped undecodable, $ours total from our process]"
}

# Generous by design: the readable lines are the whole point of the capture, and the
# undecodable ones no longer compete with them for room.
READABLE_LINE_CAP=200

summarize_capture() {
    local out="$1"

    echo
    echo "=== Ren'Py's own output (NSLog via renios prototype/Log.m) ==="
    echo "NOTE: <decode: missing data> here is expected -- this relay does not deliver"
    echo "      the payload for a third-party binary's own entries. The readable copy is"
    echo "      in the plain-text section above. <private> would mean something else:"
    echo "      the device redacting, which enable_public_log.sh's %{public}s patch fixes."
    report_readable "$out"

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
OUT_LEGACY="$LOGS/device-legacy.log"

# The tool is a Windows binary, so under WSL it needs the Windows spelling of any path we
# hand it. Everywhere else the path we already have is the one it wants.
win_path() {
    if [ "$IS_WSL" -eq 1 ] && command -v wslpath >/dev/null 2>&1; then
        wslpath -w "$1"
    else
        printf '%s' "$1"
    fi
}

echo "Writing to $OUT"
echo "        and $OUT_LEGACY"
echo "Launch VNPlayer on the phone now."

if [ -z "$SECONDS_TO_CAPTURE" ]; then
    echo "Streaming via $RELAY_NAME until Ctrl-C..."
    "$SYSLOG" --no-colors $RELAY_ARGS -o "$(win_path "$OUT")"
    exit 0
fi

# Capture through BOTH relay services at once, from a single app launch.
#
# They answer different questions and neither subsumes the other: os_trace_relay carries
# subsystem tags, sub-second timestamps and iOS-level events (jetsam kills, launch
# failures) but renders a third-party binary's own os_log entries as "<decode: missing
# data>"; syslog_relay carries this app's actual text but loses the structure. Asking the
# person holding the phone to launch the app twice, once per relay, is a worse answer than
# opening two connections.
echo "Capturing for ${SECONDS_TO_CAPTURE}s via both relays..."

timeout "$SECONDS_TO_CAPTURE" "$SYSLOG" --no-colors -o "$(win_path "$OUT")" >/dev/null 2>&1 &
PID_DEFAULT=$!
timeout "$SECONDS_TO_CAPTURE" "$SYSLOG" --no-colors --syslog-relay -o "$(win_path "$OUT_LEGACY")" >/dev/null 2>&1 &
PID_LEGACY=$!

wait "$PID_DEFAULT" 2>/dev/null || true
wait "$PID_LEGACY" 2>/dev/null || true

if [ ! -s "$OUT" ] && [ ! -s "$OUT_LEGACY" ]; then
    echo "Both captures produced nothing. The relay may not have connected." >&2
    exit 1
fi

echo "Captured $(wc -l < "$OUT" 2>/dev/null || echo 0) lines (structured)"
echo "     and $(wc -l < "$OUT_LEGACY" 2>/dev/null || echo 0) lines (plain text)"

echo
echo "=== Ren'Py's own output, as plain text (legacy relay) ==="
if [ -s "$OUT_LEGACY" ]; then
    report_readable "$OUT_LEGACY"
else
    echo "(legacy capture empty)"
fi

if [ -s "$OUT" ]; then
    summarize_capture "$OUT"
fi
