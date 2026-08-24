#!/usr/bin/env bash
# Downloads and verifies the pinned Ren'Py SDK. Idempotent.
set -euo pipefail

RENPY_VERSION="8.5.3"
SDK_SHA256="ff57648f9c04f27e381c48af6d8e3ee3cdec296bed4d3831f47f09b0a71b505e"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/vendor"
SDK_DIR="$VENDOR/renpy-$RENPY_VERSION-sdk"
ZIP="$VENDOR/renpy-$RENPY_VERSION-sdk.zip"
URL="https://www.renpy.org/dl/$RENPY_VERSION/renpy-$RENPY_VERSION-sdk.zip"

if [ -f "$SDK_DIR/renpy/bootstrap.py" ]; then
    echo "SDK already present at $SDK_DIR"
    exit 0
fi

mkdir -p "$VENDOR"

if [ ! -f "$ZIP" ]; then
    echo "Downloading $URL (163 MB)..."
    curl -fL --progress-bar -o "$ZIP.part" "$URL"
    mv "$ZIP.part" "$ZIP"
fi

echo "Verifying SHA-256..."
ACTUAL="$(sha256sum "$ZIP" | cut -d' ' -f1)"
if [ "$ACTUAL" != "$SDK_SHA256" ]; then
    echo "CHECKSUM MISMATCH" >&2
    echo "  expected: $SDK_SHA256" >&2
    echo "  actual:   $ACTUAL" >&2
    rm -f "$ZIP"
    exit 1
fi

echo "Unpacking..."
unzip -q "$ZIP" -d "$VENDOR"

if [ ! -f "$SDK_DIR/renpy/bootstrap.py" ]; then
    echo "Unpack did not produce $SDK_DIR/renpy/bootstrap.py" >&2
    exit 1
fi

echo "SDK ready at $SDK_DIR"
