#!/usr/bin/env bash
# THROWAWAY SPIKE CODE — not the eventual design.
#
# Replaces the generated .xcodeproj with one XcodeGen builds from spike/project.yml,
# after Ren'Py's own ios_create/ios_populate have produced base/. Run AFTER
# generate_xcode.sh and overlay_shell.sh, BEFORE package_ipa.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJDIR="$(find "$ROOT/build/xcode" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[ -n "$PROJDIR" ] || { echo "No generated project under build/xcode" >&2; exit 1; }

echo "Project directory: $PROJDIR"

command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen not installed" >&2; exit 1; }

# Our sources go in beside Ren'Py's, where project.yml expects them.
rm -rf "$PROJDIR/vnspike"
mkdir -p "$PROJDIR/vnspike"
cp -R "$ROOT"/spike/Sources/. "$PROJDIR/vnspike/"
cp "$ROOT/spike/project.yml" "$PROJDIR/project.yml"

# Assert the inputs project.yml names actually exist, rather than letting xcodebuild
# fail later with something less legible.
for required in main.c Log.m VideoPlayer.m IAPHelper.m Info.plist base prebuilt/release Frameworks/MetalANGLE.xcframework; do
    [ -e "$PROJDIR/$required" ] || { echo "ASSERT FAILED: $PROJDIR/$required is missing" >&2; exit 1; }
done

# The Swift function's return codes and the ObjC switch that names them live in two
# files with nothing to hold them together -- no shared header, no compiler check. If
# they drift, the device log confidently prints the wrong reason, which is worse than
# printing none: we would chase "no window scene" while the real return was -3.
#
# This check extracts both sets and compares them. It also asserts each extraction
# found something first, because a regex that silently matches nothing would make this
# pass over any pair of files at all, including two empty ones.
SWIFT_CODES="$(awk '/_cdecl\("vnspike_install_overlay"\)/{on=1} on{print} on&&/^}$/{exit}' "$ROOT/spike/Sources/SpikeOverlay.swift" | grep -oE 'return -?[0-9]+' | grep -oE '[-]?[0-9]+' | sort -n -u)"
OBJC_CODES="$(grep -oE 'case -?[0-9]+:' "$ROOT/spike/Sources/VNSpikeBootstrap.m" | grep -oE '[-]?[0-9]+' | sort -n -u)"

SWIFT_N="$(echo "$SWIFT_CODES" | grep -c . || true)"
OBJC_N="$(echo "$OBJC_CODES" | grep -c . || true)"
if [ "$SWIFT_N" -lt 2 ] || [ "$OBJC_N" -lt 2 ]; then
    echo "ASSERT FAILED: return-code extraction found $SWIFT_N Swift / $OBJC_N ObjC codes;" >&2
    echo "expected several of each. The check cannot mean anything in this state." >&2
    exit 1
fi

if [ "$SWIFT_CODES" != "$OBJC_CODES" ]; then
    echo "ASSERT FAILED: install_overlay return codes and the bootstrap switch disagree." >&2
    echo "  Swift returns: $(echo $SWIFT_CODES)" >&2
    echo "  ObjC handles:  $(echo $OBJC_CODES)" >&2
    exit 1
fi
echo "OK: install_overlay return codes match the bootstrap switch: $(echo $SWIFT_CODES)"

# Ren'Py's generated project is what we are replacing. Remove it so a stale one cannot
# be built by accident if xcodegen fails.
rm -rf "$PROJDIR"/*.xcodeproj

( cd "$PROJDIR" && xcodegen generate --spec project.yml )

GENERATED="$(find "$PROJDIR" -maxdepth 1 -name "*.xcodeproj" -print -quit)"
[ -n "$GENERATED" ] || { echo "ASSERT FAILED: xcodegen produced no .xcodeproj" >&2; exit 1; }
echo "Generated: $GENERATED"

# The whole point is that our sources are IN the target. Check EVERY one of them, not a
# hand-picked two.
#
# The hand-picked version of this check passed while VNSpikeBootstrap.m was silently
# absent -- the copy above globbed *.h *.c *.swift and quietly omitted *.m -- so the
# overlay never installed and the failure looked like "SwiftUI does not work over SDL".
# A guard that names its subjects individually only ever guards those subjects.
MISSING=0
for f in "$ROOT"/spike/Sources/*; do
    name="$(basename "$f")"
    case "$name" in
        *.h) continue ;;   # headers are included, not compiled, and need no build ref
    esac
    if ! grep -q "$name" "$GENERATED/project.pbxproj"; then
        echo "ASSERT FAILED: $name is not referenced in the generated project" >&2
        MISSING=1
    fi
done
[ "$MISSING" -eq 0 ] || exit 1
echo "OK: every source under spike/Sources/ is a member of the target:"
ls "$PROJDIR/vnspike/"

xcodebuild -list -project "$GENERATED"
