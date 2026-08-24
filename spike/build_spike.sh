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
cp "$ROOT"/spike/Sources/*.h "$ROOT"/spike/Sources/*.c "$ROOT"/spike/Sources/*.swift "$PROJDIR/vnspike/"
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

# The whole point is that Swift is IN the target. Verify rather than assume.
grep -q "SpikeOverlay.swift" "$GENERATED/project.pbxproj" || {
    echo "ASSERT FAILED: SpikeOverlay.swift is not referenced in the generated project" >&2
    exit 1
}
grep -q "VNBridge.c" "$GENERATED/project.pbxproj" || {
    echo "ASSERT FAILED: VNBridge.c is not referenced in the generated project" >&2
    exit 1
}
echo "OK: Swift and C bridge sources are members of the target"

xcodebuild -list -project "$GENERATED"
