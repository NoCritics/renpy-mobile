"""Validates a harness run. Exits non-zero with a specific reason on failure."""

from __future__ import annotations

import fnmatch
import json
import os
import sys

OUT = os.path.join(os.path.dirname(__file__), "out")
# Each game declares its own config.name in its options.rpy. This assertion is
# self-validating: if game A stops reporting "Sentinel A", the instrument is broken and
# game B's reading means nothing — which is exactly the failure mode that let two earlier
# canary designs report meaningless verdicts.
EXPECTED_CONFIG_NAME = {"A": "Sentinel A", "B": "Sentinel B"}

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

        expected_name = EXPECTED_CONFIG_NAME[game]
        if record["config_name"] != expected_name:
            failures.append(
                f"cycle {i}: game {game} reports config.name "
                f"{record['config_name']!r}, expected {expected_name!r} — per-game init "
                "state survived the switch"
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

    # The checks above only compare record["saves_dir"] strings, which come from
    # path_to_saves(gamedir) -> os.path.join(STATE.saves_root, STATE.current_game_id).
    # current_game_id is supplied by the harness itself, so those checks reduce to
    # "game_a" != "game_b" — they prove our own function returns two different strings,
    # not that Ren'Py actually wrote anything to either of them. The real evidence is on
    # disk: each game's save directory must exist and contain at least one
    # cycle-marker-*.save file, written by `renpy.save("cycle-marker")` in each sentinel
    # game's script.rpy. That converts the claim from "our function returns two
    # different strings" to "Ren'Py wrote two isolated save sets".
    for game, saves_dir in seen_save_dirs.items():
        if not os.path.isdir(saves_dir):
            failures.append(
                f"game {game}: save directory {saves_dir!r} does not exist — "
                "Ren'Py never wrote saves there"
            )
            continue
        markers = [
            name
            for name in os.listdir(saves_dir)
            if fnmatch.fnmatch(name, "cycle-marker-*.save")
        ]
        if not markers:
            failures.append(
                f"game {game}: save directory {saves_dir!r} exists but contains no "
                "cycle-marker-*.save file — renpy.save() did not actually write there"
            )

    rss = load("rss.jsonl")
    measured = [r["rss_bytes"] for r in rss if r["rss_bytes"] > 0]

    growth_assessed = False

    if not measured:
        # Never report PASS on an unmeasured memory check. Memory growth is the one
        # failure that survives to iOS as a Jetsam kill, so "we could not measure it"
        # must look like a failure, not like success.
        failures.append(
            f"memory was never measured — all {len(rss)} samples read 0 bytes. "
            "The RSS probe is broken; fix it before trusting this run."
        )
    elif len(measured) >= 4:
        growth_assessed = True
        first, last = measured[1], measured[-1]
        if last > first * RSS_GROWTH_LIMIT:
            failures.append(
                f"memory grew from {first / 1e6:.1f} MB to {last / 1e6:.1f} MB "
                f"over {len(measured)} cycles — leak"
            )
    else:
        # Fewer than 4 measured samples is the same false-negative shape as "memory was
        # never measured": too short a run to tell growth from noise (see docs/BUILD.md,
        # "History of this baseline" — run 1 vs run 2). A run this short must say
        # explicitly that growth was not assessed, never claim "no leak" by default.
        print(
            f"NOTE: only {len(measured)} RSS samples measured — growth was NOT "
            "assessed. Run with at least 4 cycles to get a growth verdict.",
            file=sys.stderr,
        )

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        sys.exit(1)

    if growth_assessed:
        print(f"PASS: {len(observations)} launches, no contamination, no leak")
    else:
        print(
            f"PASS: {len(observations)} launches, no contamination; "
            "memory growth NOT assessed (too few cycles)"
        )


if __name__ == "__main__":
    main()
