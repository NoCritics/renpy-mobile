#!/usr/bin/env bash
# Downloads and SHA-256-verifies the pinned Ren'Py SDK and renios package.
# Idempotent. Safe to run on CI or a developer machine.
set -euo pipefail

RENPY_VERSION="8.5.3"
SDK_SHA256="ff57648f9c04f27e381c48af6d8e3ee3cdec296bed4d3831f47f09b0a71b505e"
RENIOS_SHA256="c4fae153e8276ed0faed5e84ea3e0b7c4bf337f0e3208e9130c6a41748a83b2b"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VENDOR="$ROOT/vendor"
mkdir -p "$VENDOR"

# sha256sum on Linux, shasum -a 256 on macOS.
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

fetch() {
    # $4 (dirname) overrides the extracted directory name when the zip does
    # not unpack to "renpy-$RENPY_VERSION-$name" — renios does not.
    local name="$1" expected="$2" marker="$3"
    local dirname="${4:-renpy-$RENPY_VERSION-$name}"
    local zip="$VENDOR/renpy-$RENPY_VERSION-$name.zip"
    local dir="$VENDOR/$dirname"

    if [ -e "$dir/$marker" ]; then
        echo "$name already present at $dir"
        return 0
    fi

    if [ ! -f "$zip" ]; then
        echo "Downloading $name..."
        curl -fL --progress-bar -o "$zip.part" \
            "https://www.renpy.org/dl/$RENPY_VERSION/renpy-$RENPY_VERSION-$name.zip"
        mv "$zip.part" "$zip"
    fi

    local actual
    actual="$(sha256_of "$zip")"
    if [ "$actual" != "$expected" ]; then
        echo "CHECKSUM MISMATCH for $name" >&2
        echo "  expected: $expected" >&2
        echo "  actual:   $actual" >&2
        rm -f "$zip"
        exit 1
    fi

    echo "Unpacking $name..."
    rm -rf "$dir"
    unzip -qo "$zip" -d "$VENDOR"

    if [ ! -e "$dir/$marker" ]; then
        echo "Unpack did not produce $dir/$marker" >&2
        exit 1
    fi
}

fetch sdk    "$SDK_SHA256"    "renpy/bootstrap.py"
# renios's zip is named renpy-8.5.3-renios.zip but unpacks to vendor/renios,
# not vendor/renpy-8.5.3-renios. Confirmed from a CI run's raw directory
# listing (docs/IOS-BUILD.md) after the naive assumption failed.
fetch renios "$RENIOS_SHA256" "buildlib" "renios"

echo "iOS dependencies ready under $VENDOR"
