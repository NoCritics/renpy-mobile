#!/usr/bin/env bash
# Archives the generated Xcode project without code signing and packages the
# result as an unsigned .ipa.
#
# Deliberately does NOT use xcodebuild -exportArchive: that requires a signing
# identity, which would mean putting a certificate into CI. Sideloadly signs
# locally with the user's own free Apple ID instead, so CI holds no secrets.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="$ROOT/build"
ARCHIVE="$BUILD/VNPlayer.xcarchive"

PROJECT="$(find "$BUILD/xcode" -maxdepth 2 -name "*.xcodeproj" | head -1)"
[ -n "$PROJECT" ] || { echo "No .xcodeproj under $BUILD/xcode" >&2; exit 1; }

SCHEME="${VNPLAYER_SCHEME:-$(basename "$PROJECT" .xcodeproj)}"
# com.domain.<name> is Ren'Py's own placeholder (renios/buildlib/renios/create.py:112
# rewrites org.renpy.prototype to it) and is not something we ship. Override it on the
# command line -- this edits no file, so project.pbxproj in the generated tree stays
# untouched, per the plan's constraints.
BUNDLE_ID="${VNPLAYER_BUNDLE_ID:-io.github.nocritics.vnplayer}"
echo "Project:   $PROJECT"
echo "Scheme:    $SCHEME"
echo "Bundle ID: $BUNDLE_ID (override)"

rm -rf "$ARCHIVE" "$BUILD/Payload" "$BUILD/VNPlayer.ipa"

xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=NO \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    archive

APP="$(find "$ARCHIVE/Products/Applications" -maxdepth 1 -name "*.app" | head -1)"
[ -n "$APP" ] || { echo "Archive produced no .app" >&2; ls -R "$ARCHIVE/Products" >&2; exit 1; }

# The override is only real if it survives into the built bundle -- read it back out
# of the built app's own Info.plist rather than assuming the xcodebuild flag took
# effect. This is also what gets recorded in docs/IOS-BUILD.md, not the value passed in.
BUILT_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist")"
echo "Bundle ID read back from $APP/Info.plist: $BUILT_BUNDLE_ID"
[ "$BUILT_BUNDLE_ID" = "$BUNDLE_ID" ] || {
    echo "WARNING: built bundle id ('$BUILT_BUNDLE_ID') does not match the override ('$BUNDLE_ID')" >&2
}

mkdir -p "$BUILD/Payload"
cp -R "$APP" "$BUILD/Payload/"

( cd "$BUILD" && zip -qry VNPlayer.ipa Payload )
rm -rf "$BUILD/Payload"

# Assert the artifact, don't just describe it: existence, non-trivial size, and that
# it actually contains an .app inside Payload/ -- a passing xcodebuild and a listing
# printed to the log are not evidence of a working .ipa on their own.
[ -f "$BUILD/VNPlayer.ipa" ] || { echo "VNPlayer.ipa was not created" >&2; exit 1; }

IPA_BYTES="$(stat -f%z "$BUILD/VNPlayer.ipa" 2>/dev/null || stat -c%s "$BUILD/VNPlayer.ipa")"
MIN_BYTES=$((1 * 1024 * 1024))
[ "$IPA_BYTES" -ge "$MIN_BYTES" ] || {
    echo "VNPlayer.ipa is only $IPA_BYTES bytes -- too small to be a real archive" >&2
    exit 1
}

APP_NAME="$(basename "$APP")"
unzip -l "$BUILD/VNPlayer.ipa" | grep -q "Payload/$APP_NAME/" || {
    echo "VNPlayer.ipa does not contain Payload/$APP_NAME/" >&2
    unzip -l "$BUILD/VNPlayer.ipa" >&2
    exit 1
}

echo "=== built ==="
ls -lh "$BUILD/VNPlayer.ipa"
unzip -l "$BUILD/VNPlayer.ipa"
