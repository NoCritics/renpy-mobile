"""Validates a harness run. Exits non-zero with a specific reason on failure."""

from __future__ import annotations

import json
import os
import sys

OUT = os.path.join(os.path.dirname(__file__), "out")
EXPECTED = {"game_a": "A", "game_b": "B"}
RSS_GROWTH_LIMIT = 1.30  # last cycle may not exceed the first by more than 30%


def load(name: str) -> list[dict]:
    path = os.path.join(OUT, name)
    if not os.path.exists(path):
        print(f"FAIL: {path} missing — the run did not produce output", file=sys.stderr)
        sys.exit(1)
    with open(path, "r", encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


def main() -> None:
    observations = load("observations.jsonl")
    failures: list[str] = []

    if not observations:
        failures.append("no observations recorded")

    seen_save_dirs: dict[str, str] = {}

    for i, record in enumerate(observations):
        game = record["game"]
        expected = "A" if game == "A" else "B"

        if record["sentinel_value"] != expected:
            failures.append(
                f"cycle {i}: game {game} read sentinel {record['sentinel_value']!r}, "
                f"expected {expected!r} — sys.modules contamination"
            )

        if game == "B" and record["font"] != "None" and "DejaVu" in record["font"]:
            failures.append(
                f"cycle {i}: game B inherited game A's font {record['font']!r} — style bleed"
            )

        if game == "B" and record["leaked_store_var"] is not None:
            failures.append(
                f"cycle {i}: game B saw game A's store variable — store not cleaned"
            )

        previous = seen_save_dirs.get(game)
        if previous and previous != record["saves_dir"]:
            failures.append(f"cycle {i}: game {game} save dir moved between launches")
        seen_save_dirs[game] = record["saves_dir"]

    if len(set(seen_save_dirs.values())) < len(seen_save_dirs):
        failures.append(
            f"games share a save directory: {seen_save_dirs} — isolation failed"
        )

    rss = load("rss.jsonl")
    measured = [r["rss_bytes"] for r in rss if r["rss_bytes"] > 0]
    if len(measured) >= 4:
        first, last = measured[1], measured[-1]
        if last > first * RSS_GROWTH_LIMIT:
            failures.append(
                f"memory grew from {first / 1e6:.1f} MB to {last / 1e6:.1f} MB "
                f"over {len(measured)} cycles — leak"
            )

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        sys.exit(1)

    print(f"PASS: {len(observations)} launches, no contamination, no leak")


if __name__ == "__main__":
    main()
