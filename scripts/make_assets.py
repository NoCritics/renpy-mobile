"""Generates the large test image used by the sentinel games.

Writes an uncompressed-ish 2048x2048 PNG so the texture cache is meaningfully
exercised. Uses only the standard library.
"""

import os
import struct
import zlib

SIZE = 2048
OUT = os.path.join(os.path.dirname(__file__), "..", "harness", "assets", "big.png")


def chunk(tag: bytes, data: bytes) -> bytes:
    return (
        struct.pack(">I", len(data))
        + tag
        + data
        + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    )


def main() -> None:
    os.makedirs(os.path.dirname(OUT), exist_ok=True)

    # One solid colour per row, rather than a per-pixel pattern.
    #
    # What this image is for is texture-cache pressure: 2048x2048 RGBA is ~16 MB once
    # decoded, whatever it depicts. A per-pixel Python loop over 4.2 million pixels
    # takes minutes and reads as a hang; a per-row one takes a moment and produces an
    # identically-sized texture.
    raw = bytearray()
    for y in range(SIZE):
        raw.append(0)  # PNG filter type 0
        raw += bytes(((y * 7) % 256, (y * 11) % 256, (y * 13) % 256, 255)) * SIZE

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 1))
    png += chunk(b"IEND", b"")

    with open(OUT, "wb") as f:
        f.write(png)

    print(f"Wrote {OUT} ({os.path.getsize(OUT)} bytes)")

    import shutil

    for game in ("game_a", "game_b"):
        dest = os.path.join(
            os.path.dirname(__file__), "..", "harness", "games", game, "game", "big.png"
        )
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copyfile(OUT, dest)
        print(f"Copied to {dest}")


if __name__ == "__main__":
    main()
