# Milestone A — Engine Shell & Multi-Game Switching Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove, on Windows with zero Apple dependencies, that one Ren'Py process can launch a game, cleanly tear it down, and launch a *different* game repeatedly without state leaking between them — and build the reusable Python shell layer that the iOS app will embed unchanged.

**Architecture:** Ren'Py's desktop entry point `renpy.py` is explicitly a distributor customization module, and Ren'Py assigns it to `renpy.__main__`. On iOS the equivalent file is `base/main.py`, which we ship. We therefore write one `main.py` that works in both places: it overrides the documented `path_to_*` hooks, monkey-patches `renpy.bootstrap.get_alternate_base` to act as a pure "which game next" selector, and drives game switching through `UtterRestartException` inside Ren'Py's existing restart loop. A pluggable mailbox transport lets the same code be driven by a test harness on desktop and by Swift on iOS.

**Tech Stack:** Ren'Py 8.5.3 SDK (bundled CPython 3.12.8), Python 3.12 `unittest` (stdlib only — no third-party test deps), Git Bash for scripts.

**Spec:** `docs/superpowers/specs/2026-08-24-renpy-ios-player-design.md`

## Scope of this plan

This plan covers **Milestone A only**. It deliberately reorders the spec's milestones:
the spec listed M0 (CI pipeline) first, but Milestone A needs nothing but the Windows
machine already in front of us, runs in seconds rather than 10-minute CI cycles, and
falsifies the *engine* risk — the one that has no workaround if it fails. The CI pipeline
(spec M0) and the iOS native layer become their own plans, written once Milestone A's
findings are known.

**Milestone A is done when:** a single Ren'Py process cycles between two sentinel games
100 times with no module contamination, no style bleed, no save-directory crossover, and
no monotonic memory growth — and the whole thing runs from one command on Windows.

If it turns out this is *not* achievable, that is a successful outcome for this
milestone: we learn it now, for free, and fall back to one-game-per-launch before
building an iOS app on a false premise.

## Global Constraints

- **Ren'Py version is pinned to 8.5.3.** SHA-256 of `renpy-8.5.3-sdk.zip` is
  `ff57648f9c04f27e381c48af6d8e3ee3cdec296bed4d3831f47f09b0a71b505e`.
  SHA-256 of `renpy-8.5.3-renios.zip` is
  `c4fae153e8276ed0faed5e84ea3e0b7c4bf337f0e3208e9130c6a41748a83b2b`.
- **Never modify Ren'Py's source.** All engine behaviour changes go in `shell/` or
  `main.py`, both of which we own. If a change seems to require editing `renpy/`, stop
  and report it — that is a design failure, not an implementation detail.
- **No third-party Python dependencies.** Tests use stdlib `unittest`. The runtime uses
  only what the Ren'Py SDK already bundles. Anything else has to be vendored into an
  iOS static build later, which we are not doing.
- **stdlib-only, Python 3.12 syntax.** The bundled interpreter is CPython 3.12.8.
- **No network access at runtime.** Scripts may download the SDK; the shell layer may not.
- **Working name is `VNPlayer`**; environment variables use the `VNPLAYER_` prefix.
  Renaming happens later and must be a single find-and-replace.
- **Vendored artifacts are never committed.** `vendor/` and `.rig/` are git-ignored.

---

## File Structure

```
renpy-moile/
  .gitignore
  LICENSE                          MIT
  README.md
  docs/                            (research + spec already present)
  scripts/
    fetch_deps.sh                  download + SHA-256 verify the Ren'Py SDK
    make_rig.sh                    build .rig/ — an SDK copy with our overlay applied
    run_harness.sh                 one-command entry point for the cycling harness
  shell/                           THE DELIVERABLE — copied verbatim into base/ on iOS
    main.py                        renpy.__main__ replacement; path_to_* + bootstrap
    vnshell/
      __init__.py
      state.py                     process-wide switching state
      mailbox.py                   command queue with pluggable transport
      transports.py                FileTransport (desktop) + NullTransport
      lifecycle.py                 get_alternate_base replacement, restart triggering
      purge.py                     between-game engine cleanup
      harness.py                   scripted cycling driver, enabled by env var
  shell-project/                   the bundled idle launcher project
    game/options.rpy
    game/script.rpy
  harness/
    games/game_a/game/{options.rpy,script.rpy,sentinel.py}
    games/game_b/game/{options.rpy,script.rpy,sentinel.py}
    assets/big.png                 generated, not committed
  tests/
    test_mailbox.py
    test_transports.py
    test_paths.py
  vendor/                          git-ignored: downloaded SDK
  .rig/                            git-ignored: generated test rig
```

**Why `shell/vnshell/` and not `shell/shell/`:** on iOS this package sits on `sys.path`
alongside the Ren'Py stdlib, and a package literally named `shell` risks colliding with
something in a user's imported game. `vnshell` is distinctive enough not to.

**Why `main.py` is flat and the package is nested:** the iOS loader hardcodes
`<exedir>/base/main.py`. Everything else it imports must be importable from that same
directory, which `shell/` mirrors exactly. `scripts/make_rig.sh` copies `shell/*` into
the rig root, so desktop and iOS layouts are byte-identical.

---

### Task 1: Repository skeleton and dependency fetching

**Files:**
- Create: `.gitignore`, `LICENSE`, `README.md`, `scripts/fetch_deps.sh`
- Test: `tests/test_fetch_deps.sh` is not needed; verification is running the script

**Interfaces:**
- Consumes: nothing
- Produces: `vendor/renpy-8.5.3-sdk/` — an unpacked Ren'Py SDK. Every later task assumes
  `vendor/renpy-8.5.3-sdk/renpy/bootstrap.py` and
  `vendor/renpy-8.5.3-sdk/lib/py3-windows-x86_64/python.exe` exist.

- [ ] **Step 1: Initialise local version control**

This creates a *local* repository only. No GitHub remote is added — that happens at MVP,
per the agreed plan. Local commits cost nothing and make every later step revertible.

```bash
cd /c/Users/user/source/repos/workstation/renpy-moile
git init
git branch -M main
```

- [ ] **Step 2: Write `.gitignore`**

```gitignore
vendor/
.rig/
harness/assets/
harness/out/
*.pyc
__pycache__/
.DS_Store
saves/
log.txt
traceback.txt
errors.txt
```

- [ ] **Step 3: Write `LICENSE`**

Use the standard MIT licence text, copyright `2026 VNPlayer contributors`. MIT is
required by the spec — GPLv3 would foreclose any future App Store route.

- [ ] **Step 4: Write `README.md`**

```markdown
# VNPlayer

A free, open-source iOS player for Ren'Py 8 visual novels. Import a `.zip`, tap, read.
No ads, no purchases, no time limits.

Status: pre-alpha. Milestone A (engine shell) in progress.

- Design: `docs/superpowers/specs/2026-08-24-renpy-ios-player-design.md`
- Research: `docs/2026-08-24-research-renpy-ios-player.md`

This project is not affiliated with or endorsed by the Ren'Py project.

Ren'Py is MIT-licensed with LGPL-derived portions. This program contains free software
licensed under a number of licenses, including the GNU Lesser General Public License.
```

- [ ] **Step 5: Write `scripts/fetch_deps.sh`**

```bash
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
# Clear any partially-extracted tree from an interrupted run. Without this, unzip
# finds existing files, prompts to overwrite, reads EOF on non-interactive stdin,
# treats that as "none", and exits 1 — which `set -e` turns into a silent abort
# before the diagnostic below can fire. -o additionally guarantees no prompt.
rm -rf "$SDK_DIR"
unzip -qo "$ZIP" -d "$VENDOR"

if [ ! -f "$SDK_DIR/renpy/bootstrap.py" ]; then
    echo "Unpack did not produce $SDK_DIR/renpy/bootstrap.py" >&2
    exit 1
fi

echo "SDK ready at $SDK_DIR"
```

- [ ] **Step 6: Run it and verify**

Run: `bash scripts/fetch_deps.sh`
Expected: downloads ~163 MB, prints `SDK ready at .../vendor/renpy-8.5.3-sdk`.

Then confirm the Windows interpreter is present — every later task depends on it:

Run: `ls vendor/renpy-8.5.3-sdk/lib/py3-windows-x86_64/python.exe`
Expected: the path is listed, no error.

Run: `bash scripts/fetch_deps.sh`
Expected: `SDK already present` and immediate exit (idempotency check).

- [ ] **Step 7: Record the actual SDK layout**

Run and paste the output into `docs/BUILD.md` under a heading `## Ren'Py 8.5.3 SDK layout`:

```bash
ls vendor/renpy-8.5.3-sdk/
ls vendor/renpy-8.5.3-sdk/lib/
```

This is reference material for the iOS plan, which has to reproduce this layout inside
the app bundle. Write down what is actually there rather than what we expect.

- [ ] **Step 8: Commit**

```bash
git add .gitignore LICENSE README.md scripts/fetch_deps.sh docs/BUILD.md
git commit -m "chore: repo skeleton and pinned Ren'Py SDK fetcher"
```

---

### Task 2: The desktop rig

**Files:**
- Create: `scripts/make_rig.sh`
- Test: verification is running the rig and seeing Ren'Py refuse to start (no project yet)

**Interfaces:**
- Consumes: `vendor/renpy-8.5.3-sdk/` from Task 1
- Produces: `.rig/` — an SDK copy with `shell/*` overlaid at its root, such that
  `.rig/main.py` occupies the same relative position as `base/main.py` does on iOS.
  Later tasks invoke: `.rig/lib/py3-windows-x86_64/python.exe .rig/main.py --basedir <dir>`

- [ ] **Step 1: Write `scripts/make_rig.sh`**

The rig deliberately mirrors the iOS layout. On iOS, `librenpython.c` sets the Python
home to `<exedir>/base` and runs `<exedir>/base/main.py`; `base/` also contains `renpy/`
and the Python stdlib. The rig reproduces that: SDK root plays the part of `base/`.

```bash
#!/usr/bin/env bash
# Builds .rig/ : a Ren'Py SDK copy with our shell overlay applied.
# Mirrors the iOS bundle layout, where shell/main.py becomes base/main.py.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="$ROOT/vendor/renpy-8.5.3-sdk"
RIG="$ROOT/.rig"

if [ ! -f "$SDK/renpy/bootstrap.py" ]; then
    echo "SDK missing. Run scripts/fetch_deps.sh first." >&2
    exit 1
fi

# Rebuild the overlay every time; only re-copy the SDK when absent, since it is large.
if [ ! -f "$RIG/renpy/bootstrap.py" ]; then
    echo "Copying SDK into $RIG (this takes a minute)..."
    rm -rf "$RIG"
    cp -r "$SDK" "$RIG"
fi

echo "Applying shell overlay..."
rm -rf "$RIG/vnshell"
cp "$ROOT/shell/main.py" "$RIG/main.py"
cp -r "$ROOT/shell/vnshell" "$RIG/vnshell"

echo "Rig ready at $RIG"
```

- [ ] **Step 2: Make both scripts executable and run the rig builder**

```bash
chmod +x scripts/*.sh
bash scripts/make_rig.sh
```

Expected: fails with `SDK missing` if Task 1 was skipped; otherwise it will fail copying
`shell/main.py`, which does not exist yet. That failure is expected at this point — it
confirms the script reaches the overlay stage. Task 3 creates the missing files.

- [ ] **Step 3: Commit**

```bash
git add scripts/make_rig.sh
git commit -m "chore: desktop rig builder mirroring the iOS bundle layout"
```

---

### Task 3: `main.py` — the distributor customization module

**Files:**
- Create: `shell/main.py`, `shell/vnshell/__init__.py`, `shell/vnshell/state.py`
- Create: `shell-project/game/options.rpy`, `shell-project/game/script.rpy`
- Test: `tests/test_paths.py`

**Interfaces:**
- Consumes: `vendor/` SDK, `scripts/make_rig.sh`
- Produces:
  - `main.py` module-level functions `path_to_gamedir(basedir, name) -> str`,
    `path_to_common(renpy_base) -> str | None`, `path_to_saves(gamedir, save_directory=None) -> str`,
    `path_to_logdir(basedir) -> str`, `predefined_searchpath(commondir) -> list[str]`,
    and `main() -> None`. Ren'Py assigns this module to `renpy.__main__` and calls these.
  - `vnshell.state.State` with attributes `next_basedir: str | None`,
    `current_game_id: str | None`, `shell_project_dir: str`, and a module-level
    singleton `vnshell.state.STATE`.

- [ ] **Step 1: Write the failing test**

`path_to_gamedir` is where Ren'Py decides what `config.gamedir` is. Stock Ren'Py tries a
list of candidate names; we want a strict rule, because an imported game directory is
untrusted and a surprising fallback (Ren'Py falls back to `basedir` itself when no
candidate matches) would make the engine treat the whole import as a game directory.

```python
# tests/test_paths.py
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "shell"))

import main as vnmain  # noqa: E402


class PathToGamedirTests(unittest.TestCase):
    def test_returns_game_subdirectory_when_present(self):
        with tempfile.TemporaryDirectory() as base:
            os.mkdir(os.path.join(base, "game"))
            self.assertEqual(
                vnmain.path_to_gamedir(base, "irrelevant"),
                os.path.join(base, "game"),
            )

    def test_raises_when_game_subdirectory_absent(self):
        with tempfile.TemporaryDirectory() as base:
            with self.assertRaises(vnmain.NoGameDirectory):
                vnmain.path_to_gamedir(base, "irrelevant")

    def test_ignores_executable_name_candidates(self):
        # Stock Ren'Py would accept a directory named after the executable.
        # We must not: only "game" counts.
        with tempfile.TemporaryDirectory() as base:
            os.mkdir(os.path.join(base, "myapp"))
            with self.assertRaises(vnmain.NoGameDirectory):
                vnmain.path_to_gamedir(base, "myapp")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
vendor/renpy-8.5.3-sdk/lib/py3-windows-x86_64/python.exe -m unittest discover -s tests -v
```
Expected: FAIL — `ModuleNotFoundError: No module named 'main'`.

- [ ] **Step 3: Write `shell/vnshell/__init__.py`**

```python
"""VNPlayer engine shell. Runs inside Ren'Py's embedded CPython."""

__all__ = ["state", "mailbox", "transports", "lifecycle", "purge", "harness"]
```

- [ ] **Step 4: Write `shell/vnshell/state.py`**

```python
"""Process-wide switching state.

Deliberately a plain object rather than module globals scattered around: everything
that survives a game switch lives here, so the purge step has one place to look.
"""

from __future__ import annotations


class State:
    def __init__(self) -> None:
        # Absolute path of the base directory Ren'Py should load on its next
        # pass through the bootstrap restart loop. None means "the shell project".
        self.next_basedir: str | None = None

        # Stable identifier for the game currently loaded, used to isolate saves.
        # None while the shell project is loaded.
        self.current_game_id: str | None = None

        # Absolute path to the bundled idle launcher project. Set once at startup.
        self.shell_project_dir: str = ""

        # Absolute path to the directory holding per-game save directories.
        self.saves_root: str = ""

    def reset_for_shell(self) -> None:
        self.next_basedir = None
        self.current_game_id = None


STATE = State()
```

- [ ] **Step 5: Write `shell/main.py`**

This is adapted from the SDK's `renpy.py`, which carries the header *"Functions to be
customized by distributors"*. We keep the functions Ren'Py requires, change the three
that matter, and delegate the rest to stock behaviour.

```python
"""VNPlayer entry point.

Ren'Py assigns this module to ``renpy.__main__`` and calls the ``path_to_*`` functions
below. On iOS this file is ``base/main.py``; on desktop the rig places it at the SDK
root. The two layouts are identical by construction.
"""

from __future__ import annotations

import os
import sys
import warnings


class NoGameDirectory(Exception):
    """Raised when a base directory contains no ``game/`` subdirectory."""


def path_to_renpy_base() -> str:
    return os.path.abspath(os.path.dirname(os.path.abspath(__file__)))


def path_to_gamedir(basedir: str, name: str) -> str:
    """Return ``<basedir>/game``, strictly.

    Stock Ren'Py tries several candidate names and silently falls back to ``basedir``
    itself. For imported, untrusted games that fallback would make Ren'Py treat the
    whole import as its game directory, so we require ``game/`` and fail loudly.
    """

    gamedir = os.path.join(basedir, "game")

    if not os.path.isdir(gamedir):
        raise NoGameDirectory(f"No game/ directory in {basedir!r}")

    return gamedir


def path_to_common(renpy_base: str) -> str | None:
    path = os.path.join(renpy_base, "renpy", "common")
    return path if os.path.isdir(path) else None


def path_to_saves(gamedir: str, save_directory: str | None = None) -> str:
    """Return a per-game save directory, outside the game tree.

    Ren'Py's default derives the location from the game's own ``config.save_directory``,
    which means two imported games with the same configured name would share saves.
    We key on our own game id instead, and keep saves outside the game directory so
    deleting or re-importing a game never destroys progress.
    """

    from vnshell.state import STATE

    if STATE.saves_root and STATE.current_game_id:
        return os.path.join(STATE.saves_root, STATE.current_game_id)

    # The shell project, or a not-yet-identified game: keep saves beside the game.
    return os.path.join(gamedir, "saves")


def path_to_logdir(basedir: str) -> str:
    return basedir


def predefined_searchpath(commondir: str | None) -> list[str]:
    import renpy  # type: ignore

    searchpath = [renpy.config.gamedir]

    if commondir and os.path.isdir(commondir):
        searchpath.append(commondir)

    return searchpath


def main() -> None:
    renpy_base = path_to_renpy_base()
    sys.path.append(renpy_base)

    warnings.simplefilter("ignore", DeprecationWarning)

    import renpy.bootstrap  # type: ignore

    renpy.__main__ = sys.modules[__name__]  # type: ignore

    from vnshell import lifecycle

    lifecycle.install(renpy_base)

    renpy.bootstrap.bootstrap(renpy_base)


if __name__ == "__main__":
    main()
```

- [ ] **Step 6: Run the test to verify it passes**

Run:
```bash
vendor/renpy-8.5.3-sdk/lib/py3-windows-x86_64/python.exe -m unittest discover -s tests -v
```
Expected: 3 tests PASS.

- [ ] **Step 7: Write the shell project**

`shell-project/game/options.rpy`:

```renpy
define config.name = "VNPlayer"
define config.save_directory = "vnplayer-shell"
define config.window_title = "VNPlayer"

define config.has_autosave = False
define config.autosave_on_quit = False
define config.rollback_enabled = False
define config.developer = False
```

`shell-project/game/script.rpy` — the idle project. It exists so Ren'Py and SDL are in
their normal operating mode while the native library UI is on screen. It draws a plain
background and does nothing else; on iOS the native library window covers it entirely.

```renpy
init python:
    def _vnplayer_tick():
        import vnshell.lifecycle
        vnshell.lifecycle.tick()

    config.periodic_callbacks.append(_vnplayer_tick)

label start:
    scene black
    "" # placeholder so the label is well-formed; replaced by the idle loop below
    jump idle

label idle:
    $ renpy.pause(3600.0, hard=True)
    jump idle
```

- [ ] **Step 8: Commit**

```bash
git add shell/main.py shell/vnshell/__init__.py shell/vnshell/state.py \
        shell-project tests/test_paths.py
git commit -m "feat: renpy.__main__ replacement with strict gamedir and per-game saves"
```

---

### Task 4: The mailbox and its transports

**Files:**
- Create: `shell/vnshell/mailbox.py`, `shell/vnshell/transports.py`
- Test: `tests/test_mailbox.py`, `tests/test_transports.py`

**Interfaces:**
- Consumes: nothing from earlier tasks
- Produces:
  - `vnshell.mailbox.Command` — a frozen dataclass with fields `name: str` and
    `args: dict[str, str]`
  - `vnshell.mailbox.Mailbox` with `__init__(self, transport)`, `poll(self) -> list[Command]`
  - `vnshell.transports.Transport` — protocol with `receive(self) -> list[dict]`
  - `vnshell.transports.NullTransport` — always returns `[]`
  - `vnshell.transports.FileTransport(path)` — reads newline-delimited JSON commands
    from `path`, truncating it, so a harness or a debugging human can drive the shell
  - `vnshell.mailbox.MAILBOX` — module-level singleton, initialised by `lifecycle.install`

- [ ] **Step 1: Write the failing tests**

```python
# tests/test_transports.py
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "shell"))

from vnshell.transports import FileTransport, NullTransport  # noqa: E402


class NullTransportTests(unittest.TestCase):
    def test_receives_nothing(self):
        self.assertEqual(NullTransport().receive(), [])


class FileTransportTests(unittest.TestCase):
    def test_missing_file_yields_nothing(self):
        with tempfile.TemporaryDirectory() as d:
            t = FileTransport(os.path.join(d, "absent.jsonl"))
            self.assertEqual(t.receive(), [])

    def test_reads_and_consumes_commands(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "cmd.jsonl")
            with open(path, "w", encoding="utf-8") as f:
                f.write(json.dumps({"name": "launch", "args": {"basedir": "/x"}}) + "\n")
                f.write(json.dumps({"name": "quitToLibrary", "args": {}}) + "\n")

            t = FileTransport(path)
            got = t.receive()

            self.assertEqual(len(got), 2)
            self.assertEqual(got[0]["name"], "launch")
            self.assertEqual(got[1]["name"], "quitToLibrary")

            # Consumed: a second poll must be empty, or every tick would replay them.
            self.assertEqual(t.receive(), [])

    def test_malformed_line_is_skipped_not_fatal(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "cmd.jsonl")
            with open(path, "w", encoding="utf-8") as f:
                f.write("this is not json\n")
                f.write(json.dumps({"name": "quitToLibrary", "args": {}}) + "\n")

            got = FileTransport(path).receive()
            self.assertEqual([c["name"] for c in got], ["quitToLibrary"])


if __name__ == "__main__":
    unittest.main()
```

```python
# tests/test_mailbox.py
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "shell"))

from vnshell.mailbox import Command, Mailbox  # noqa: E402


class FakeTransport:
    def __init__(self, batches):
        self.batches = list(batches)

    def receive(self):
        return self.batches.pop(0) if self.batches else []


class MailboxTests(unittest.TestCase):
    def test_converts_dicts_to_commands(self):
        mb = Mailbox(FakeTransport([[{"name": "launch", "args": {"basedir": "/x"}}]]))
        got = mb.poll()
        self.assertEqual(got, [Command(name="launch", args={"basedir": "/x"})])

    def test_missing_args_defaults_to_empty(self):
        mb = Mailbox(FakeTransport([[{"name": "quitToLibrary"}]]))
        self.assertEqual(mb.poll(), [Command(name="quitToLibrary", args={})])

    def test_entry_without_name_is_dropped(self):
        mb = Mailbox(FakeTransport([[{"args": {}}, {"name": "quitToLibrary"}]]))
        self.assertEqual([c.name for c in mb.poll()], ["quitToLibrary"])

    def test_transport_failure_is_swallowed(self):
        class Exploding:
            def receive(self):
                raise OSError("device on fire")

        # A broken transport must never take down a running game.
        self.assertEqual(Mailbox(Exploding()).poll(), [])


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
vendor/renpy-8.5.3-sdk/lib/py3-windows-x86_64/python.exe -m unittest discover -s tests -v
```
Expected: FAIL — `ModuleNotFoundError: No module named 'vnshell.transports'`.

- [ ] **Step 3: Write `shell/vnshell/transports.py`**

```python
"""Command transports.

The shell is driven by commands from outside Ren'Py. On iOS that is Swift, through a
C extension. On desktop it is a file, which lets the harness — and a human debugging by
hand — drive the same code path. The transport is the only part that differs.
"""

from __future__ import annotations

import json
import os
from typing import Protocol


class Transport(Protocol):
    def receive(self) -> list[dict]:
        """Return and consume any pending commands. Must never block."""
        ...


class NullTransport:
    """No commands, ever. Used when nothing is driving the shell."""

    def receive(self) -> list[dict]:
        return []


class FileTransport:
    """Reads newline-delimited JSON commands from a file, consuming them.

    Consuming matters: this is polled every frame, so leaving the contents in place
    would replay the same command forever.
    """

    def __init__(self, path: str) -> None:
        self.path = path

    def receive(self) -> list[dict]:
        if not os.path.exists(self.path):
            return []

        try:
            with open(self.path, "r", encoding="utf-8") as f:
                raw = f.read()
            os.remove(self.path)
        except OSError:
            return []

        commands: list[dict] = []

        for line in raw.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                parsed = json.loads(line)
            except ValueError:
                continue
            if isinstance(parsed, dict):
                commands.append(parsed)

        return commands
```

- [ ] **Step 4: Write `shell/vnshell/mailbox.py`**

```python
"""The command queue between the host UI and the running engine.

While a game is running, Ren'Py owns the main loop and cannot be called into. Commands
are therefore queued by the host and drained by a periodic callback. This module is
transport-agnostic so the same logic runs under the desktop harness and under Swift.
"""

from __future__ import annotations

import dataclasses

from vnshell.transports import NullTransport, Transport


@dataclasses.dataclass(frozen=True)
class Command:
    name: str
    args: dict


class Mailbox:
    def __init__(self, transport: Transport) -> None:
        self.transport = transport

    def poll(self) -> list[Command]:
        """Return pending commands. Never raises — a broken transport must not
        take down a running game."""

        try:
            raw = self.transport.receive()
        except Exception:
            return []

        commands: list[Command] = []

        for entry in raw:
            name = entry.get("name")
            if not name:
                continue
            args = entry.get("args") or {}
            if not isinstance(args, dict):
                args = {}
            commands.append(Command(name=str(name), args=args))

        return commands


MAILBOX = Mailbox(NullTransport())
```

- [ ] **Step 5: Run the tests to verify they pass**

Run:
```bash
vendor/renpy-8.5.3-sdk/lib/py3-windows-x86_64/python.exe -m unittest discover -s tests -v
```
Expected: all tests PASS (3 path + 4 transport + 4 mailbox = 11).

- [ ] **Step 6: Commit**

```bash
git add shell/vnshell/mailbox.py shell/vnshell/transports.py \
        tests/test_mailbox.py tests/test_transports.py
git commit -m "feat: command mailbox with pluggable file and null transports"
```

---

### Task 5: Lifecycle — boot the shell project

**Files:**
- Create: `shell/vnshell/lifecycle.py`
- Modify: none
- Test: manual — launching the rig must show a window and stay up

**Interfaces:**
- Consumes: `vnshell.state.STATE`, `vnshell.mailbox.MAILBOX`, `vnshell.transports.FileTransport`
- Produces:
  - `vnshell.lifecycle.install(renpy_base: str) -> None` — called from `main.main()`
    *before* `bootstrap()`. Wires up state, the mailbox transport, and the
    `get_alternate_base` monkey-patch.
  - `vnshell.lifecycle.select_next_basedir(basedir: str, always: bool = False) -> str`
    — the `get_alternate_base` replacement. Signature must match stock Ren'Py's.
  - `vnshell.lifecycle.tick() -> None` — drains the mailbox; called from
    `config.periodic_callbacks`.

- [ ] **Step 1: Write `shell/vnshell/lifecycle.py`**

Note the signature of `select_next_basedir`: stock `get_alternate_base(basedir, always=False)`
is called from two places in `bootstrap.py`, and one passes `always`. Matching the
signature exactly is what keeps this a drop-in replacement.

```python
"""Game selection and switching.

Ren'Py's bootstrap already contains a restart loop that re-resolves the base directory
on every pass and catches UtterRestartException. We supply the resolver. It is a *pure
selector*: it reads state and returns a path. It never waits for input and never cleans
up — waiting happens in the running shell project, cleanup happens in vnshell.purge.
"""

from __future__ import annotations

import os

from vnshell import mailbox as mailbox_module
from vnshell.mailbox import Command, Mailbox
from vnshell.state import STATE
from vnshell.transports import FileTransport, NullTransport

_installed = False


def install(renpy_base: str) -> None:
    """Wire the shell into Ren'Py. Must run before bootstrap()."""

    global _installed

    # The shell project's game/ lives directly at renpy_base, mirroring iOS, where
    # Ren'Py's distributor packages the game into base/ alongside main.py and renpy/.
    # This also keeps bootstrap.py:315 happy: it calls path_to_gamedir(renpy_base, ...)
    # before the restart loop is ever entered, and our strict version needs game/ there.
    STATE.shell_project_dir = renpy_base
    STATE.saves_root = os.environ.get(
        "VNPLAYER_SAVES_ROOT", os.path.join(renpy_base, "saves")
    )

    command_file = os.environ.get("VNPLAYER_COMMAND_FILE")
    if command_file:
        mailbox_module.MAILBOX = Mailbox(FileTransport(command_file))
    else:
        mailbox_module.MAILBOX = Mailbox(NullTransport())

    import renpy.bootstrap  # type: ignore

    renpy.bootstrap.get_alternate_base = select_next_basedir

    _installed = True


def select_next_basedir(basedir: str, always: bool = False) -> str:
    """Replacement for renpy.bootstrap.get_alternate_base.

    Returns the base directory Ren'Py should load on this pass of the restart loop.
    Signature matches stock Ren'Py, which calls it with and without ``always``.
    """

    target = STATE.next_basedir or STATE.shell_project_dir

    if not os.path.isdir(target):
        # Never hand Ren'Py a path that does not exist; it exits the process.
        STATE.reset_for_shell()
        return STATE.shell_project_dir

    return target


def tick() -> None:
    """Drain the mailbox. Called every frame from config.periodic_callbacks."""

    for command in mailbox_module.MAILBOX.poll():
        _dispatch(command)


def _dispatch(command: Command) -> None:
    handler = _HANDLERS.get(command.name)
    if handler is None:
        return
    handler(command)


def _handle_launch(command: Command) -> None:
    basedir = command.args.get("basedir")
    if not basedir or not os.path.isdir(basedir):
        return

    STATE.next_basedir = os.path.abspath(basedir)
    STATE.current_game_id = command.args.get("gameId") or os.path.basename(
        os.path.normpath(basedir)
    )
    _restart()


def _handle_quit_to_library(command: Command) -> None:
    STATE.reset_for_shell()
    _restart()


def _restart() -> None:
    """Ask Ren'Py to tear down and re-enter the bootstrap restart loop."""

    import renpy.game  # type: ignore

    raise renpy.game.UtterRestartException()


_HANDLERS = {
    "launch": _handle_launch,
    "quitToLibrary": _handle_quit_to_library,
}
```

- [ ] **Step 2: Rebuild the rig and launch it**

```bash
bash scripts/make_rig.sh
cp -r shell-project/game .rig/game
.rig/lib/py3-windows-x86_64/python.exe .rig/main.py
```

Expected: a Ren'Py window opens showing a black screen and stays open. Close it.

Note the shell project's `game/` goes to `.rig/game`, **not** `.rig/shell-project/game`.
This mirrors iOS, where Ren'Py's distributor packages the game into `base/` alongside
`main.py` and `renpy/`, making `base/` itself a valid base directory. It is also load-
bearing: `bootstrap.py:315` calls `path_to_gamedir(basedir, name)` with
`basedir = args.basedir or renpy_base` **before** entering the restart loop. With no
`--basedir` argument that is the rig root, and our deliberately strict `path_to_gamedir`
raises `NoGameDirectory` unless `game/` is there — killing the process before the loop
is reached.

If it reports `No game/ directory`, the copy did not happen — check `.rig/game/script.rpy`.

- [ ] **Step 3: Fold the shell project into the rig builder**

Add to `scripts/make_rig.sh`, immediately before the final `echo`:

```bash
rm -rf "$RIG/game"
cp -r "$ROOT/shell-project/game" "$RIG/game"
```

Run: `bash scripts/make_rig.sh && .rig/lib/py3-windows-x86_64/python.exe .rig/main.py`
Expected: same window, now with no manual copy step.

- [ ] **Step 4: Commit**

```bash
git add shell/vnshell/lifecycle.py scripts/make_rig.sh
git commit -m "feat: lifecycle install, basedir selector, and mailbox tick"
```

---

### Task 6: Sentinel games

**Files:**
- Create: `harness/games/game_a/game/{options.rpy,script.rpy,sentinel.py}`
- Create: `harness/games/game_b/game/{options.rpy,script.rpy,sentinel.py}`
- Create: `scripts/make_assets.py`

**Interfaces:**
- Consumes: nothing
- Produces: two directories usable as `--basedir` targets, each of which records what it
  observed into `harness/out/observations.jsonl` as one JSON object per launch, with keys
  `game`, `sentinel_value`, `font`, `saves_dir`, `leaked_store_var`.

- [ ] **Step 1: Write the asset generator**

The games must load a large image to exercise the texture cache, but a multi-megabyte
binary should not live in git. Generate it instead.

```python
# scripts/make_assets.py
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

    raw = bytearray()
    for y in range(SIZE):
        raw.append(0)  # filter type 0
        for x in range(SIZE):
            raw += bytes(((x * 7) % 256, (y * 11) % 256, ((x ^ y) % 256), 255))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 1))
    png += chunk(b"IEND", b"")

    with open(OUT, "wb") as f:
        f.write(png)

    print(f"Wrote {OUT} ({os.path.getsize(OUT)} bytes)")


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Run it**

Run: `vendor/renpy-8.5.3-sdk/lib/py3-windows-x86_64/python.exe scripts/make_assets.py`
Expected: prints the written path and a size of roughly 1–3 MB.

- [ ] **Step 3: Write game A**

`harness/games/game_a/game/sentinel.py` — the contamination canary. Both games define a
module with the *same name* and different contents. If B ever reads `"A"`, `sys.modules`
leaked.

```python
VALUE = "A"
```

`harness/games/game_a/game/options.rpy`:

```renpy
define config.name = "Sentinel A"
define config.save_directory = "sentinel-shared-name"
define config.developer = False
define config.autosave_on_quit = False
```

Note both games deliberately use the **same** `config.save_directory`. That is the
crossover trap: with stock Ren'Py they would share saves. Our `path_to_saves` override
must keep them apart.

`harness/games/game_a/game/script.rpy`:

```renpy
init python:
    import os, sys, json

    def observe(game):
        import renpy.store as store
        gamedir = renpy.config.gamedir
        sys.path.insert(0, gamedir)
        import sentinel
        record = {
            "game": game,
            "sentinel_value": sentinel.VALUE,
            "font": str(style.default.font),
            "saves_dir": renpy.__main__.path_to_saves(gamedir),
            "leaked_store_var": getattr(store, "game_a_marker", None),
        }
        out = os.environ.get("VNPLAYER_OBSERVATIONS")
        if out:
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with open(out, "a", encoding="utf-8") as f:
                f.write(json.dumps(record) + "\n")

label start:
    $ observe("A")
    $ style.default.font = "DejaVuSans.ttf"
    $ game_a_marker = "leaked"
    scene expression "big.png"
    $ renpy.music.play("<silence 2.0>", channel="music", loop=True)
    $ renpy.save("cycle-marker")
    $ renpy.pause(0.2, hard=True)
    $ import vnshell.harness; vnshell.harness.advance()
    $ renpy.pause(3600.0, hard=True)
```

- [ ] **Step 4: Write game B**

`harness/games/game_b/game/sentinel.py`:

```python
VALUE = "B"
```

`harness/games/game_b/game/options.rpy`:

```renpy
define config.name = "Sentinel B"
define config.save_directory = "sentinel-shared-name"
define config.developer = False
define config.autosave_on_quit = False
```

`harness/games/game_b/game/script.rpy` — identical to A's except for the label body.
Repeated in full rather than cross-referenced, because these are separate Ren'Py
projects and must not share files.

```renpy
init python:
    import os, sys, json

    def observe(game):
        import renpy.store as store
        gamedir = renpy.config.gamedir
        sys.path.insert(0, gamedir)
        import sentinel
        record = {
            "game": game,
            "sentinel_value": sentinel.VALUE,
            "font": str(style.default.font),
            "saves_dir": renpy.__main__.path_to_saves(gamedir),
            "leaked_store_var": getattr(store, "game_a_marker", None),
        }
        out = os.environ.get("VNPLAYER_OBSERVATIONS")
        if out:
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with open(out, "a", encoding="utf-8") as f:
                f.write(json.dumps(record) + "\n")

label start:
    $ observe("B")
    scene expression "big.png"
    $ renpy.music.play("<silence 2.0>", channel="music", loop=True)
    $ renpy.save("cycle-marker")
    $ renpy.pause(0.2, hard=True)
    $ import vnshell.harness; vnshell.harness.advance()
    $ renpy.pause(3600.0, hard=True)
```

- [ ] **Step 5: Copy the shared asset into both games**

Add to `scripts/make_assets.py` after writing `OUT`:

```python
    import shutil

    for game in ("game_a", "game_b"):
        dest = os.path.join(
            os.path.dirname(__file__), "..", "harness", "games", game, "game", "big.png"
        )
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copyfile(OUT, dest)
        print(f"Copied to {dest}")
```

Run: `vendor/renpy-8.5.3-sdk/lib/py3-windows-x86_64/python.exe scripts/make_assets.py`
Expected: prints one write and two copies.

- [ ] **Step 6: Commit**

```bash
git add harness/games scripts/make_assets.py
git commit -m "test: sentinel games A and B for contamination detection"
```

---

### Task 7: The cycling harness

**Files:**
- Create: `shell/vnshell/harness.py`, `scripts/run_harness.sh`, `harness/check.py`

**Interfaces:**
- Consumes: `vnshell.state.STATE`, `vnshell.lifecycle`
- Produces:
  - `vnshell.harness.enabled() -> bool` — true when `VNPLAYER_HARNESS_CYCLES` is set
  - `vnshell.harness.advance() -> None` — called from a sentinel game once it has
    observed itself; switches to the next game or ends the run
  - `vnshell.harness.start() -> None` — called from `lifecycle.tick` when the shell
    project is loaded and the harness is enabled; kicks off cycle 1
  - `harness/out/observations.jsonl` — one JSON record per game launch
  - `harness/out/rss.jsonl` — one `{"cycle": int, "rss_bytes": int}` per cycle

- [ ] **Step 1: Write `shell/vnshell/harness.py`**

```python
"""Scripted game-cycling driver.

Enabled only when VNPLAYER_HARNESS_CYCLES is set, so it is inert in production. It
alternates between the two sentinel games, recording resident set size after each
switch, then exits the process with a status the shell script can check.
"""

from __future__ import annotations

import ctypes
import json
import os
import sys

from vnshell.state import STATE


# Cycle state is file-backed rather than held in module globals. Game switching runs
# renpy.reload_all(), and whether that reloads non-Ren'Py modules on sys.path is not
# something we have verified. If this module were reloaded, module-level counters would
# reset and the harness would cycle forever instead of terminating — a hang rather than
# a visible failure. A file is immune to whatever the reload semantics turn out to be.
def _cycle_file() -> str:
    return os.path.join(os.path.dirname(os.environ["VNPLAYER_RSS_LOG"]), "cycle.txt")


def _read_cycle() -> int:
    try:
        with open(_cycle_file(), "r", encoding="utf-8") as f:
            return int(f.read().strip() or "0")
    except (OSError, ValueError):
        return 0


def _write_cycle(value: int) -> None:
    path = _cycle_file()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(str(value))


def enabled() -> bool:
    return bool(os.environ.get("VNPLAYER_HARNESS_CYCLES"))


def _total_cycles() -> int:
    return int(os.environ.get("VNPLAYER_HARNESS_CYCLES", "0"))


def _games() -> list[str]:
    root = os.environ["VNPLAYER_HARNESS_GAMES"]
    return [os.path.join(root, "game_a"), os.path.join(root, "game_b")]


def _rss_bytes() -> int:
    """Resident set size, without third-party dependencies.

    Windows only for now; the iOS port will supply its own implementation. Returns 0
    when unavailable rather than failing the run, so a missing metric degrades to
    'not measured' instead of a false failure.
    """

    if sys.platform == "win32":
        class Counters(ctypes.Structure):
            _fields_ = [
                ("cb", ctypes.c_uint32),
                ("PageFaultCount", ctypes.c_uint32),
                ("PeakWorkingSetSize", ctypes.c_size_t),
                ("WorkingSetSize", ctypes.c_size_t),
                ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
                ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                ("PagefileUsage", ctypes.c_size_t),
                ("PeakPagefileUsage", ctypes.c_size_t),
            ]

        counters = Counters()
        counters.cb = ctypes.sizeof(Counters)
        handle = ctypes.windll.kernel32.GetCurrentProcess()  # type: ignore[attr-defined]
        ok = ctypes.windll.psapi.GetProcessMemoryInfo(  # type: ignore[attr-defined]
            handle, ctypes.byref(counters), counters.cb
        )
        return int(counters.WorkingSetSize) if ok else 0

    try:
        import resource

        return int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss) * 1024
    except Exception:
        return 0


def _record_rss(cycle: int) -> None:
    out = os.environ.get("VNPLAYER_RSS_LOG")
    if not out:
        return
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "a", encoding="utf-8") as f:
        f.write(json.dumps({"cycle": cycle, "rss_bytes": _rss_bytes()}) + "\n")


def start() -> None:
    """Begin cycling. Called from the shell project's tick; safe to call repeatedly."""

    if not enabled() or _read_cycle() > 0:
        return

    advance()


def advance() -> None:
    """Move to the next game, or finish the run."""

    if not enabled():
        return

    cycle = _read_cycle()
    _record_rss(cycle)

    cycle += 1
    _write_cycle(cycle)

    if cycle > _total_cycles():
        sys.exit(0)

    games = _games()
    target = games[(cycle - 1) % len(games)]

    from vnshell import lifecycle
    from vnshell.mailbox import Command

    lifecycle._handle_launch(
        Command(
            name="launch",
            args={"basedir": target, "gameId": os.path.basename(target)},
        )
    )
```

- [ ] **Step 2: Hook the harness into `lifecycle.tick`**

Modify `shell/vnshell/lifecycle.py`, replacing the body of `tick()`:

```python
def tick() -> None:
    """Drain the mailbox. Called every frame from config.periodic_callbacks."""

    from vnshell import harness

    if harness.enabled() and STATE.next_basedir is None:
        harness.start()

    for command in mailbox_module.MAILBOX.poll():
        _dispatch(command)
```

- [ ] **Step 3: Write `harness/check.py`**

```python
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
```

- [ ] **Step 4: Write `scripts/run_harness.sh`**

```bash
#!/usr/bin/env bash
# One-command cycling harness. Usage: bash scripts/run_harness.sh [cycles]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CYCLES="${1:-10}"
RIG="$ROOT/.rig"
PY="$RIG/lib/py3-windows-x86_64/python.exe"

bash "$ROOT/scripts/make_rig.sh"

rm -rf "$ROOT/harness/out"
mkdir -p "$ROOT/harness/out"

export VNPLAYER_HARNESS_CYCLES="$CYCLES"
export VNPLAYER_HARNESS_GAMES="$ROOT/harness/games"
export VNPLAYER_OBSERVATIONS="$ROOT/harness/out/observations.jsonl"
export VNPLAYER_RSS_LOG="$ROOT/harness/out/rss.jsonl"
export VNPLAYER_SAVES_ROOT="$ROOT/harness/out/saves"

echo "Running $CYCLES cycles..."
set +e
"$PY" "$RIG/main.py"
STATUS=$?
set -e

echo "Engine exited with status $STATUS"

"$PY" "$ROOT/harness/check.py"
```

- [ ] **Step 5: Run the harness with two cycles and expect failure**

Run: `bash scripts/run_harness.sh 2`

Expected: FAIL. There is no purge step yet, so the most likely first failure is
`sys.modules contamination` — game B reading sentinel `"A"`. Codex and Antigravity both
predicted this independently, and confirming it is the point of this step.

**Record the exact failure output in `docs/BUILD.md` under `## Harness baseline`.**
The purge layer in Task 8 is derived from these observed failures, not from guesswork.

- [ ] **Step 6: Commit**

```bash
git add shell/vnshell/harness.py shell/vnshell/lifecycle.py \
        harness/check.py scripts/run_harness.sh docs/BUILD.md
git commit -m "test: cycling harness — red, contamination reproduced"
```

---

### Task 8: The purge layer

**Files:**
- Create: `shell/vnshell/purge.py`
- Modify: `shell/vnshell/lifecycle.py` — call the purge before returning a new basedir

**Interfaces:**
- Consumes: `vnshell.state.STATE`
- Produces: `vnshell.purge.purge_engine_state(previous_basedir: str | None) -> list[str]`
  — performs cleanup and returns a list of human-readable descriptions of what it did,
  for logging. Never raises; collects failures into the returned list prefixed `failed:`.

- [ ] **Step 1: Write `shell/vnshell/purge.py`**

Ordered most-certain to least-certain. Only the module purge is known to be required
before running; the rest are hypotheses that Step 3 will confirm or discard.

```python
"""Between-game engine cleanup.

Ren'Py's bootstrap tears down the renderer, audio and image cache in a ``finally`` that
sits *outside* its restart loop (bootstrap.py: try at 354, while at 355, finally at 409).
Nothing is therefore released between games, and this module has to do it by hand.

Every step is defensive: a failure here must degrade the switch, not crash the app.
"""

from __future__ import annotations

import gc
import os
import sys


def purge_engine_state(previous_basedir: str | None) -> list[str]:
    actions: list[str] = []

    for step in (
        _stop_audio,
        _stop_video,
        _clear_image_cache,
        _free_renders,
        lambda: _purge_modules(previous_basedir),
        _collect,
    ):
        try:
            result = step()
            if result:
                actions.append(result)
        except Exception as exc:  # noqa: BLE001 — cleanup must never propagate
            actions.append(f"failed: {step.__name__ if hasattr(step, '__name__') else step}: {exc!r}")

    return actions


def _stop_audio() -> str:
    import renpy.audio.music  # type: ignore

    renpy.audio.music.stop(channel="music")
    renpy.audio.music.stop(channel="sound")
    renpy.audio.music.stop(channel="voice")
    return "stopped audio channels"


def _stop_video() -> str:
    import renpy.display.video  # type: ignore

    renpy.display.video.movie_stop(only_fullscreen=False)
    return "stopped video"


def _clear_image_cache() -> str:
    import renpy.display.im  # type: ignore

    renpy.display.im.cache.clear()
    return "cleared image cache"


def _free_renders() -> str:
    import renpy.display.render  # type: ignore

    renpy.display.render.free_memory()
    return "freed render cache"


def _purge_modules(previous_basedir: str | None) -> str:
    """Drop modules imported from the previous game's directory.

    Scoped by resolved path rather than by module name, so a game's ``utils.py`` cannot
    leak into the next game's ``utils.py`` — and so nothing belonging to Ren'Py or the
    standard library is ever touched.
    """

    if not previous_basedir:
        return ""

    root = os.path.abspath(previous_basedir)
    removed: list[str] = []

    for name, module in list(sys.modules.items()):
        origin = getattr(module, "__file__", None)
        if not origin:
            continue
        try:
            resolved = os.path.abspath(origin)
        except (TypeError, ValueError):
            continue
        if resolved.startswith(root + os.sep):
            sys.modules.pop(name, None)
            removed.append(name)

    # The game directory is pushed onto sys.path by the game itself and by
    # bootstrap; leaving stale entries there would let the next game import from
    # a directory that no longer holds the modules it expects.
    sys.path[:] = [p for p in sys.path if not os.path.abspath(p).startswith(root)]

    return f"purged {len(removed)} modules: {', '.join(sorted(removed))}" if removed else ""


def _collect() -> str:
    collected = gc.collect()
    return f"gc collected {collected} objects"
```

- [ ] **Step 2: Call the purge from the lifecycle**

Modify `shell/vnshell/lifecycle.py`. Add a module-level `_previous_basedir` and rewrite
`select_next_basedir` — this is the one place guaranteed to run between games:

```python
_previous_basedir: str | None = None


def select_next_basedir(basedir: str, always: bool = False) -> str:
    """Replacement for renpy.bootstrap.get_alternate_base.

    Returns the base directory Ren'Py should load on this pass of the restart loop.
    Signature matches stock Ren'Py, which calls it with and without ``always``.
    """

    global _previous_basedir

    from vnshell import purge

    target = STATE.next_basedir or STATE.shell_project_dir

    if not os.path.isdir(target):
        STATE.reset_for_shell()
        target = STATE.shell_project_dir

    if _previous_basedir and _previous_basedir != target:
        for action in purge.purge_engine_state(_previous_basedir):
            print(f"[vnshell] purge: {action}")

    _previous_basedir = target
    return target
```

- [ ] **Step 3: Run the harness and read the failures**

Run: `bash scripts/run_harness.sh 4`

Expected: the `sys.modules` contamination failure is gone. Other failures — style bleed,
store leakage, save crossover, memory growth — may remain.

**For each remaining failure, add exactly one step to `purge_engine_state` and re-run.**
Do not add speculative steps for failures the harness does not report. Candidates, in
the order they are most likely to be needed:

- style bleed → `renpy.style.reset()` before reload
- store leakage → `renpy.python.clean_stores()`
- font cache → `renpy.text.font.free_memory()`

Record in `docs/BUILD.md` under `## Purge findings` which steps proved necessary and
which did not. That list is a deliverable: the iOS plan depends on it, and it is the
empirical answer to the spec's biggest open question.

- [ ] **Step 4: Run the full harness**

Run: `bash scripts/run_harness.sh 100`

Expected: `PASS: 100 launches, no contamination, no leak`.

If memory still grows, that is a genuine finding, not a failure of the plan. Record the
growth curve from `harness/out/rss.jsonl` in `docs/BUILD.md` and report it — it decides
whether the iOS app can switch games freely or must cap switches per session.

- [ ] **Step 5: Commit**

```bash
git add shell/vnshell/purge.py shell/vnshell/lifecycle.py docs/BUILD.md
git commit -m "feat: between-game engine purge — harness green over 100 cycles"
```

---

### Task 9: Report findings and update the spec

**Files:**
- Modify: `docs/superpowers/specs/2026-08-24-renpy-ios-player-design.md`
- Modify: `docs/BUILD.md`

**Interfaces:**
- Consumes: everything above
- Produces: a spec whose §8 lists the *verified* purge steps rather than hypotheses, and
  a `docs/BUILD.md` the iOS plan can be written against.

- [ ] **Step 1: Replace the spec's hypothesis list with findings**

In §8 of the spec, replace the paragraph beginning *"This is a **hypothesis list**"* with
the actual verified list from `docs/BUILD.md`, and state the measured memory behaviour
across 100 cycles.

- [ ] **Step 2: Add the better seam to the spec**

§5.2 currently describes only the `get_alternate_base` monkey-patch. Add that `main.py`
is `renpy.__main__`, Ren'Py's documented distributor customization module, and that
`path_to_saves` and `path_to_gamedir` are overridden there — this is how per-game save
isolation is actually achieved, superseding §6's mention of `config.save_directory`.

- [ ] **Step 3: Update §6 for consistency**

§6 says *"`config.save_directory` is overridden per game."* That is now wrong. Replace it
with the `path_to_saves` override, keeping the same rationale about generically-named
games sharing saves.

- [ ] **Step 4: Commit**

```bash
git add docs/
git commit -m "docs: fold Milestone A findings back into the spec"
```

---

## Self-Review

**Spec coverage.** This plan covers spec §5.2 (no engine fork), §5.4 (game switching),
§8 (engine lifecycle and purge), the save-isolation half of §6, and §10.1's assertions
— re-homed to desktop, where they run in seconds. Deliberately **not** covered, and
requiring their own plans: §5.1/§5.3/§5.5 iOS specifics, §7 import, §9 native UI, §11
build and distribution. §10.1's *simulator* execution moves to the iOS plan; the
assertions themselves are written and proven here first.

**Known gap, accepted:** the desktop harness cannot exercise MetalANGLE texture
retention or Jetsam behaviour, which are iOS-only. Milestone A therefore proves the
*logical* isolation of game switching but not its *memory* behaviour on device. The iOS
plan must re-run this harness on the simulator and on hardware before the result is
trusted.

**Placeholder scan.** No TBDs. Task 8 Step 3 deliberately leaves which purge steps get
added to be determined by harness output — that is empiricism, not a placeholder: the
candidate list, the decision rule, and the recording location are all specified.

**Type consistency.** `select_next_basedir(basedir, always=False)` matches stock
`get_alternate_base`'s signature at both call sites in `bootstrap.py`. `Command(name, args)`
is constructed identically in `mailbox.py`, `lifecycle.py` and `harness.py`.
`purge_engine_state(previous_basedir)` returns `list[str]` and is consumed as such in
`lifecycle.select_next_basedir`. `STATE` attribute names are consistent across
`state.py`, `main.py`, `lifecycle.py` and `harness.py`.

**One risk worth naming:** Task 7 Step 5 assumes the first failure is `sys.modules`
contamination. If instead the engine crashes or hangs on the first switch, the harness
cannot even produce observations — in which case stop, report, and treat it as evidence
that `UtterRestartException` is not a viable switching mechanism. That is the scenario
Milestone A exists to detect early, and it is the trigger for the spec's stated fallback
of one game per app launch.
