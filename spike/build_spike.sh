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
