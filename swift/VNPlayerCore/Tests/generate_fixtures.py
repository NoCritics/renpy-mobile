#!/usr/bin/env python3
"""Generate the ZIP fixtures the Swift extractor tests read.

Why Python writes these and not our own Swift code: if the same implementation both
produced and consumed the fixtures, a shared misreading of the ZIP format would pass
every test. Python's ``zipfile`` is a mature, independent implementation, so a round-trip
through it actually tests something.

The output is committed to the repository. Regenerating is a deliberate act -- run this
script, look at the diff, and say in the commit message what changed and why. A fixture
that silently changes underneath a passing test is worse than no fixture.

    python3 swift/VNPlayerCore/Tests/generate_fixtures.py
"""

from __future__ import annotations

import os
import shutil
import struct
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "VNPlayerCoreTests", "Fixtures")

# A minimal but plausible Ren'Py 8 game tree.
GAME_FILES = {
    "game/script.rpy": b'label start:\n    "Hello."\n    return\n',
    "game/script.rpyc": b"RENPY RPC2" + b"\x00" * 36,
    "game/options.rpy": b'define config.name = "Fixture"\n',
    "game/gui/window_icon.png": b"\x89PNG\r\n\x1a\n" + b"\x00" * 64,
}


def write(name: str, builder) -> None:
    path = os.path.join(OUT, name)
    if os.path.exists(path):
        os.remove(path)
    builder(path)
    print(f"  {name}  ({os.path.getsize(path)} bytes)")


def simple(entries: dict, compression=zipfile.ZIP_DEFLATED):
    def build(path):
        with zipfile.ZipFile(path, "w", compression) as z:
            for name, data in entries.items():
                z.writestr(name, data)
    return build


def prefixed(prefix: str, extra: dict | None = None, compression=zipfile.ZIP_DEFLATED):
    entries = {f"{prefix}/{k}": v for k, v in GAME_FILES.items()}
    if extra:
        entries.update({f"{prefix}/{k}": v for k, v in extra.items()})
    return simple(entries, compression)


def main() -> None:
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)

    print("Writing fixtures to", OUT)

    # --- well-formed ---
    write("good-deflated.zip", prefixed("MyGame-1.2.3-pc"))
    write("good-stored.zip", prefixed("MyGame-1.2.3-pc", compression=zipfile.ZIP_STORED))
    write("game-at-root.zip", simple(GAME_FILES))

    # UTF-8 names. Python sets the UTF-8 flag (bit 11) automatically for non-ASCII.
    write("utf8-names.zip", prefixed("Game", {
        "game/audio/効果音.ogg": b"OggS" + b"\x00" * 32,
        "game/images/café.png": b"\x89PNG\r\n\x1a\n" + b"\x00" * 16,
    }))

    # --- structure rejections ---
    write("no-game-dir.zip", simple({
        "SomeFolder/readme.txt": b"nothing to see",
        "SomeFolder/data.bin": b"\x00\x01\x02",
    }))
    write("empty.zip", simple({}))

    # --- path attacks ---
    write("traversal.zip", simple({
        "Game/game/script.rpy": b"ok",
        "Game/../../../etc/passwd": b"root::0:0",
    }))
    write("absolute-path.zip", simple({
        "Game/game/script.rpy": b"ok",
        "/etc/passwd": b"root::0:0",
    }))
    write("backslash-traversal.zip", simple({
        "Game/game/script.rpy": b"ok",
        "..\\..\\windows\\system32\\evil.dll": b"MZ",
    }))
    write("drive-path.zip", simple({
        "Game/game/script.rpy": b"ok",
        "C:/Windows/evil.dll": b"MZ",
    }))

    # Case-insensitive duplicate: distinct in the archive, same file on iOS.
    write("duplicate-case.zip", simple({
        "Game/game/script.rpy": b"first",
        "Game/game/SCRIPT.rpy": b"second",
    }))

    # --- engine detection ---
    write("renpy7-lib.zip", prefixed("Old-pc", {
        "lib/py2-windows-x86_64/python.exe": b"MZ",
    }))
    write("renpy8-lib.zip", prefixed("New-pc", {
        "lib/py3-windows-x86_64/python.exe": b"MZ",
    }))
    write("renpy7-vcversion.zip", prefixed("Old-pc", {
        "renpy/vc_version.py": b"branch = 'fix'\nversion = '7.5.3.22090809'\n",
    }))
    write("renpy8-vcversion.zip", prefixed("New-pc", {
        "renpy/vc_version.py": b"branch = 'fix'\nversion = '8.5.3.26051504'\n",
    }))

    # --- pruning ---
    # Deliberately includes game/lib/, which must NOT be pruned: pruning is scoped to the
    # distribution root, and anything under game/ belongs to the game.
    write("desktop-cruft.zip", prefixed("Cruft-pc", {
        "MyGame.exe": b"MZ" + b"\x00" * 4096,
        "MyGame.sh": b"#!/bin/sh\n",
        "lib/py3-windows-x86_64/python.dll": b"MZ" + b"\x00" * 4096,
        "renpy/__init__.py": b"# engine\n",
        "game/lib/helper.rpy": b"# a REAL game file in a directory called lib\n",
        "game/cache/bytecode.rpyb": b"\x00" * 16,
    }))

    # --- ZIP64 ---
    # force_zip64 makes Python emit ZIP64 extra fields and a ZIP64 end-of-central-
    # directory record even though the payload is small, which is what we want to parse.
    def build_zip64(path):
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED, allowZip64=True) as z:
            for name, data in GAME_FILES.items():
                with z.open(f"Zip64Game/{name}", "w", force_zip64=True) as f:
                    f.write(data)
    write("zip64.zip", build_zip64)

    # --- damage ---
    def build_truncated(path):
        source = os.path.join(OUT, "good-deflated.zip")
        with open(source, "rb") as f:
            data = f.read()
        with open(path, "wb") as f:
            f.write(data[: len(data) // 2])
    write("truncated.zip", build_truncated)

    def build_crc_corrupt(path):
        """A structurally valid archive whose payload bytes do not match its CRC.

        Built by writing a stored entry and then flipping a byte inside the file data.
        Stored (not deflated) so the flip lands in the payload rather than breaking the
        deflate stream -- the point is to reach the CRC check, not to fail before it.
        """
        with zipfile.ZipFile(path, "w", zipfile.ZIP_STORED) as z:
            for name, data in GAME_FILES.items():
                z.writestr(f"Corrupt/{name}", data)
            z.writestr("Corrupt/game/payload.txt", b"A" * 64)

        with open(path, "rb") as f:
            blob = bytearray(f.read())

        marker = b"A" * 64
        index = blob.find(marker)
        assert index != -1, "payload not found; fixture generator needs updating"
        blob[index] = ord("B")

        with open(path, "wb") as f:
            f.write(blob)
    write("crc-corrupt.zip", build_crc_corrupt)

    def build_not_a_zip(path):
        with open(path, "wb") as f:
            f.write(b"This is not a zip file. " * 100)
    write("not-a-zip.bin", build_not_a_zip)

    # --- multi-disk ---
    def build_multidisk(path):
        """Rewrites the EOCD disk numbers to make a single-volume archive claim to be
        part of a set. Python's zipfile cannot produce a real split archive, and the
        thing under test is our EOCD reader, which only looks at these two fields."""
        source = os.path.join(OUT, "good-deflated.zip")
        with open(source, "rb") as f:
            blob = bytearray(f.read())

        signature = b"PK\x05\x06"
        index = blob.rfind(signature)
        assert index != -1, "no EOCD in the source fixture"
        # disk number at +4, central-directory start disk at +6, both UInt16 LE.
        struct.pack_into("<HH", blob, index + 4, 1, 1)

        with open(path, "wb") as f:
            f.write(blob)
    write("multi-disk.zip", build_multidisk)

    print(f"\n{len(os.listdir(OUT))} fixtures written.")


if __name__ == "__main__":
    main()
