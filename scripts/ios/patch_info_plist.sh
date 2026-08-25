#!/usr/bin/env bash
# Adds the keys that let the user get games in and saves out, to the GENERATED Info.plist.
#
# Scope, same rule as enable_public_log.sh: this edits build/xcode/<name>/Info.plist,
# which is our artifact, and never vendor/renios/prototype/. The generated tree is ours
# to configure; Ren'Py's source is not ours to modify.
#
# What each key buys:
#
#   UIFileSharingEnabled              the app's Documents folder appears in the Files app
#   LSSupportsOpeningDocumentsInPlace opening a game from Files does not silently copy it
#   CFBundleDocumentTypes             .zip files offer VNPlayer in the share sheet
#
# Only Documents/ is exposed, and by M2's design Documents holds nothing but Games/ and
# Saves/. The library index and the command spools live in Library/Application Support,
# where the Files app cannot reach them -- a user who deletes library.json out of
# curiosity should not be able to, and a user who deletes a command file mid-launch
# definitely should not.
#
# The exposure is deliberate and worth its risk: on a sideloaded app with no crash
# reporting and no iTunes sync, being able to copy saves out by hand, drop a fan
# translation in, or delete a game that will not start is the only recovery path there is.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PLIST="$(find "$ROOT/build/xcode" -maxdepth 2 -name "Info.plist" -print -quit)"
if [ -z "$PLIST" ]; then
    echo "No Info.plist under build/xcode; run generate_xcode.sh first" >&2
    exit 1
fi

echo "Patching $PLIST"

PB=/usr/libexec/PlistBuddy
[ -x "$PB" ] || { echo "PlistBuddy not found at $PB (macOS only)" >&2; exit 1; }

set_bool() {
    local key="$1" value="$2"
    "$PB" -c "Delete :$key" "$PLIST" 2>/dev/null || true
    "$PB" -c "Add :$key bool $value" "$PLIST"
}

set_bool UIFileSharingEnabled true
set_bool LSSupportsOpeningDocumentsInPlace true

# Declare that we open zip archives, so VNPlayer shows up in the share sheet and in
# "Open With" from Files. LSItemContentTypes uses the UTI, not the extension.
"$PB" -c "Delete :CFBundleDocumentTypes" "$PLIST" 2>/dev/null || true
"$PB" -c "Add :CFBundleDocumentTypes array" "$PLIST"
"$PB" -c "Add :CFBundleDocumentTypes:0 dict" "$PLIST"
"$PB" -c "Add :CFBundleDocumentTypes:0:CFBundleTypeName string 'Ren''Py game archive'" "$PLIST"
"$PB" -c "Add :CFBundleDocumentTypes:0:LSHandlerRank string Alternate" "$PLIST"
"$PB" -c "Add :CFBundleDocumentTypes:0:CFBundleTypeRole string Viewer" "$PLIST"
"$PB" -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes array" "$PLIST"
"$PB" -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes:0 string public.zip-archive" "$PLIST"

echo "=== assertions (PlistBuddy reports success for writes that do nothing useful) ==="

# Read each key back out of the file. PlistBuddy exits 0 for an Add that lands somewhere
# unexpected, and a plist that merely parses is not a plist that says what we meant.
assert_key() {
    local key="$1" expected="$2"
    local actual
    actual="$("$PB" -c "Print :$key" "$PLIST" 2>/dev/null || echo "<missing>")"
    if [ "$actual" != "$expected" ]; then
        echo "ASSERT FAILED: $key is '$actual', expected '$expected'" >&2
        exit 1
    fi
    echo "OK: $key = $actual"
}

assert_key UIFileSharingEnabled true
assert_key LSSupportsOpeningDocumentsInPlace true
assert_key CFBundleDocumentTypes:0:LSItemContentTypes:0 public.zip-archive

# And confirm the file is still a valid plist afterwards, rather than trusting that a
# sequence of successful edits left it well-formed.
plutil -lint "$PLIST"
