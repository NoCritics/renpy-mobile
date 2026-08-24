#!/usr/bin/env bash
# Makes Ren'Py's own log readable on a device, by patching the GENERATED Xcode project.
#
# Why this exists
# ---------------
# On iOS Ren'Py never writes log.txt (renpy/log.py:79 points the log at real stdout when
# renpy.ios is set), and renios routes that through NSLog via prototype/Log.m. The log
# therefore lands in the iOS unified log. But Log.m is:
#
#     NSLog(@"%s", s);
#
# and iOS redacts %s arguments as <private>. A device capture shows the lines exist and
# shows nothing of what they say.
#
# The documented alternative -- a configuration profile setting Enable-Private-Data -- was
# tried and REJECTED by iOS with "invalid signature": modern iOS will not install an
# unsigned profile, and signing one requires a certificate this project deliberately does
# not have. It is also device-wide, unredacting every app rather than ours.
#
# So we patch the format specifier to %{public}s instead. That unredacts ONLY this app,
# needs no device settings, and survives a reinstall.
#
# Scope
# -----
# This edits build/xcode/<name>/Log.m -- our generated artifact -- and never
# vendor/renios/prototype/Log.m. Same reasoning as overriding the bundle identifier on the
# xcodebuild command line: the generated tree is ours to configure, Ren'Py's source is not
# ours to modify.
#
# Privacy note
# ------------
# With this applied, anything Ren'Py logs is readable by anyone with USB access to the
# device -- including which game is open. That is a physical-access threat model, and
# acceptable for a pre-alpha personal sideload. Revisit before any wider release.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

LOG_M="$(find "$ROOT/build/xcode" -maxdepth 2 -name "Log.m" | head -1)"
if [ -z "$LOG_M" ]; then
    echo "No Log.m under build/xcode; run generate_xcode.sh first" >&2
    exit 1
fi

echo "Patching $LOG_M"

# Assert the thing we are about to replace is actually there. If renios ever changes this
# file, we must fail loudly rather than silently produce a build with a redacted log and a
# green checkmark.
if ! grep -q 'NSLog(@"%s", s);' "$LOG_M"; then
    if grep -q 'NSLog(@"%{public}s", s);' "$LOG_M"; then
        echo "Already patched; nothing to do."
        exit 0
    fi
    echo "ASSERT FAILED: Log.m does not contain the expected NSLog(@\"%s\", s);" >&2
    echo "renios may have changed this file. Its current contents:" >&2
    cat "$LOG_M" >&2
    exit 1
fi

# sed -i differs between GNU and BSD/macOS; write to a temp file and move instead.
sed 's/NSLog(@"%s", s);/NSLog(@"%{public}s", s);/' "$LOG_M" > "$LOG_M.new"
mv "$LOG_M.new" "$LOG_M"

# Verify the edit landed, rather than trusting sed's exit status.
if ! grep -q 'NSLog(@"%{public}s", s);' "$LOG_M"; then
    echo "ASSERT FAILED: patch did not take effect" >&2
    exit 1
fi

echo "Ren'Py log output will now be readable in the device console:"
grep -n "NSLog" "$LOG_M"
