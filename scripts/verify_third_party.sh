#!/usr/bin/env bash
# Verifies that vendored third-party source is exactly what third_party/PROVENANCE.md
# says it is.
#
# Vendoring only means something if the copy is checked. A "pinned" dependency that has
# been quietly edited is worse than an unpinned one, because the pin makes everyone stop
# looking.
#
# Offline by default: it recomputes the tree hash and compares it against the recorded
# one. With --upstream it also clones the pinned commit and diffs, which needs network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROVENANCE="$ROOT/third_party/PROVENANCE.md"
VENDORED="$ROOT/swift/VNPlayerCore/Sources/ZIPFoundation"

[ -f "$PROVENANCE" ] || { echo "Missing $PROVENANCE" >&2; exit 1; }
[ -d "$VENDORED" ] || { echo "Missing $VENDORED" >&2; exit 1; }

# Pull the expected values out of the provenance table rather than duplicating them here,
# so the document stays the single source of truth.
#
# Two things here are deliberate, and both were bugs first.
#
# The backtick is NOT backslash-escaped. GNU grep reads \` as a start-of-buffer anchor,
# a GNU extension -- so the "escaped" version silently matched nothing at all.
#
# And each pipeline ends with `|| true`. Under `set -euo pipefail` a grep that matches
# nothing fails the whole assignment and exits the script immediately, which meant the
# "could not read the expected values" check below could never run: the script died two
# lines before reaching its own error message. It exited 1 with no output whatsoever.
EXPECTED_HASH="$(grep -oE '`[0-9a-f]{64}`' "$PROVENANCE" | head -1 | tr -d '`' || true)"
EXPECTED_COMMIT="$(grep -oE '`[0-9a-f]{40}`' "$PROVENANCE" | head -1 | tr -d '`' || true)"

if [ -z "$EXPECTED_HASH" ] || [ -z "$EXPECTED_COMMIT" ]; then
    echo "ASSERT FAILED: could not read the expected hash and commit out of" >&2
    echo "$PROVENANCE. The table format may have changed." >&2
    exit 1
fi

# Probe by RUNNING it, not by asking whether it exists. On Windows `command -v python3`
# succeeds against the Microsoft Store alias stub, which then refuses to execute and
# prints an advert -- so an existence check picks an interpreter that cannot run. That
# exact confusion has already cost this project one debugging session.
PY=""
for candidate in "${PYTHON:-}" python3 python; do
    [ -n "$candidate" ] || continue
    if "$candidate" -c "import sys" >/dev/null 2>&1; then
        PY="$candidate"
        break
    fi
done

if [ -z "$PY" ]; then
    echo "ASSERT FAILED: no working Python interpreter found (tried python3, python)." >&2
    exit 1
fi

ACTUAL_HASH="$("$PY" - "$VENDORED" <<'PYEOF'
import glob, hashlib, os, sys

directory = sys.argv[1]
files = sorted(glob.glob(os.path.join(directory, "*.swift")))

if not files:
    # Without this the hash of an empty directory would be a perfectly stable value that
    # this script would happily compare -- and every future run would agree with it.
    sys.stderr.write("ASSERT FAILED: no .swift files in %s\n" % directory)
    sys.exit(1)

digest = hashlib.sha256()
for path in files:
    digest.update(os.path.basename(path).encode())
    # Line endings are normalised before hashing. Git rewrites CRLF to LF on checkout
    # depending on platform and config, so a hash over raw bytes would be a hash of the
    # checkout rather than of the source -- it would pass on the machine that generated
    # it and fail everywhere else, including CI. That is worse than no check, because it
    # fails for a reason unrelated to the thing being verified.
    blob = open(path, "rb").read().replace(bytes([13, 10]), bytes([10]))
    digest.update(blob)

sys.stdout.write(digest.hexdigest())
PYEOF
)"

echo "ZIPFoundation"
echo "  expected: $EXPECTED_HASH"
echo "  actual:   $ACTUAL_HASH"

if [ "$ACTUAL_HASH" != "$EXPECTED_HASH" ]; then
    echo >&2
    echo "ASSERT FAILED: vendored ZIPFoundation does not match its recorded hash." >&2
    echo >&2
    echo "Either the copy was modified, or it was updated without updating" >&2
    echo "third_party/PROVENANCE.md. Both need saying out loud: a local patch has to be" >&2
    echo "recorded under 'Local modifications', and an upgrade has to move the commit," >&2
    echo "the version and this hash together." >&2
    exit 1
fi

echo "  OK ($(ls "$VENDORED"/*.swift | wc -l | tr -d ' ') files)"

if [ "${1:-}" = "--upstream" ]; then
    echo
    echo "Comparing against upstream $EXPECTED_COMMIT ..."
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT

    git clone --quiet https://github.com/weichsel/ZIPFoundation.git "$TMP/zf"
    git -C "$TMP/zf" checkout --quiet "$EXPECTED_COMMIT"

    if diff -r "$TMP/zf/Sources/ZIPFoundation" "$VENDORED" \
        --exclude=Resources > "$TMP/diff.txt"; then
        echo "  OK: byte-identical to upstream"
    else
        echo "ASSERT FAILED: our copy differs from upstream at the pinned commit:" >&2
        cat "$TMP/diff.txt" >&2
        exit 1
    fi
fi
