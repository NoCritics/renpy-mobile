# M4 — Save transfer

**Status:** approved in conversation 2026-08-25, not yet planned.
**Parent:** `2026-08-24-renpy-ios-player-design.md`. **Precedes:** library polish (separate).

## 1. What this is for

Two jobs, one machine underneath.

**Backup against reinstall.** The sideload expires every seven days. Whether a re-sign
preserves the app's Data container is *unverified* (§9), and a reader who loses forty
hours of a visual novel to a provisioning detail will not be consoled by the explanation.

**Carrying a playthrough between the phone and a PC.** She reads on both. An export must
be openable on a desktop with nothing installed, and a save taken off a desktop must come
back in.

The binding constraint, in her words: *inside VNPlayer it works automatically, export and
import, in one click.* PC compatibility is a property of the bytes on disk. It is never a
question the app asks her.

## 2. What Ren'Py actually stores

Verified against the vendored 8.5.3 SDK, because every number here is load-bearing.

- A save slot named `3-2` (page 3, slot 2) is the file **`3-2-LT1.save`**.
  `renpy/__init__.py:144` sets `savegame_suffix = "-LT1.save"`, and
  `savelocation.py:150` joins `slotname + suffix`. **Not `<slot>.save`.** Anything that
  renames a slot must preserve the suffix or the file stops being a save.
- A `.save` file **is itself a ZIP archive** — `loadsave.py:110` writes it with
  `zipfile.ZipFile(..., "w", ZIP_DEFLATED)`. So an export is a zip of zips. Compressing
  it again buys nothing; store the entries rather than deflating them twice.
- Our saves live at `Documents/Saves/<gameId>/`, flat, one directory per game
  (`shell/main.py:44`, `VNPlayerPaths.swift:63`). Keyed on **our** game id, not on the
  game's `config.save_directory`, so two games that declare the same save directory do
  not collide. That decision is what makes per-game export a directory copy.
- On a desktop, the same game saves to (`renpy.py:189-204`):

  | platform | location |
  |---|---|
  | Windows | `%APPDATA%/RenPy/<save_directory>` |
  | macOS | `~/Library/RenPy/<save_directory>` |
  | Linux | `~/.renpy/<save_directory>` |

  A `Ren'Py Data` directory found above the game's own directory takes precedence over
  all three (`renpy.py:176-187`) — the portable-install case.
- **`config.save_directory` may be `None`** (`config.py:369`). Then the game saves to
  `<gamedir>/saves` and has no stable per-user location at all. §4.4 handles this rather
  than pretending it cannot happen.

## 3. The format

One format for both tiers. A plain **`.zip`**, because a PC opens it with nothing
installed and a custom extension would make the desktop half worse for no gain.

```
vnplayer-saves.json          the manifest
saves/                       one game: the save files, verbatim
games/<gameId>/              many games: the same, one directory each
WHERE-TO-PUT-THESE.txt       plain English, names her actual desktop folder
```

A single-game export uses `saves/`; a backup uses `games/`. The manifest says which, and
the reader is one code path over a list whose length happens to be 1.

```jsonc
{
  "format": 1,
  "kind": "game",                                 // or "backup"
  "exportedAt": "2026-08-25T14:03:11Z",
  "appVersion": "0.2.0",
  "games": [
    {
      "gameId": "bigbaddogs",
      "title": "Big Bad Dogs",
      "saveDirectory": "BigBadDogs-1489443940",   // config.save_directory, or null
      "files": [ { "name": "1-1-LT1.save", "bytes": 481203, "sha256": "..." } ]
    }
  ]
}
```

`format` is an integer that increments on any breaking change; a reader that meets a
higher number says so plainly instead of guessing. `sha256` per file is what lets import
report damage as damage rather than as a mysterious failure to load.

### 3.1 `saveDirectory` is the one field we do not have yet

Nothing in the app knows a game's `config.save_directory` today. `LibraryEntry` has no
such field, and it cannot be read from the archive at import time — it is set by Python
in the game's own script.

The engine knows it while the game runs. So the shell reports it **once, at
`gameReady`**, as a new key on that existing event, and Swift stores it on the library
entry. Cost: one field, one event key, no new channel.

Consequence, stated because it is a real limitation and not a bug: **a game that has
never been launched has no `saveDirectory`.** It also has no saves, so its export is
empty and the question does not arise. A game launched once has it forever.

## 4. The flows

Every one of these is one tap. Where a second tap exists, §4.1 says why.

**Export — overlay strip, while playing.** Replaces quick save. Zips the running game's
save directory, hands it to the share sheet. No dialog.

**Export — library, per game.** Same call, from the game's row.

**Back up everything — library.** Same machinery over every game. One file.

**Import — library.** File picker, then done.

**Import — overlay strip, while playing.** One confirmation first; §4.1.

### 4.1 Import while playing quits to the library first

Import replaces the strip's quick load. It is the only flow with a confirmation, and the
reason is mechanical rather than cautious: Ren'Py caches the slot list and holds the save
directory open, so writing files underneath a live engine is the one version of this that
can leave the game looking at saves that are not there.

So the strip's import reads *"This returns you to the library first"*, quits, then opens
the picker. `quitToLibrary` already exists and already tears the engine down properly
(`lifecycle._restart`).

### 4.2 Matching is automatic, and says so when it guesses

1. The manifest's `gameId` matches an installed game — import silently.
2. No id match, but the `title` matches exactly one installed game — import into it and
   say which. Ids are derived from the archive's distribution root, so the same game
   imported from a differently-named `.zip` legitimately has a different id.
3. Neither — name the game the saves are for, and offer the installed games to choose
   from. Refusing outright would strand exactly the case this feature exists for.

A backup restores every game in it that is installed and **names the ones that are not**,
rather than silently importing a subset.

### 4.3 Import never destroys a save

Not a preference. She must not be able to lose a playthrough by tapping the wrong icon.

A slot name is `<page>-<number>`, and **the page is everything before the final dash** —
`3` in `3-2`, `auto` in `auto-1`, `quick` in `quick-1`. Stated because the whole rule
below turns on it, and splitting on the *first* dash would put a restored `auto-1` on a
page called `auto` for one game and somewhere else for the next.

- Incoming file whose slot is free: copied as-is.
- Slot already taken: the incoming save goes to **the next free slot on that page**, with
  `savegame_suffix` preserved. Never overwritten, never deleted.
- Identical content (matching `sha256`) already present: skipped, counted as such. A
  restore run twice must not double every slot.

The result is a sentence: *"5 saves added, 2 placed in new slots, 1 already there."*

`auto-` and `quick-` pages are ordinary pages under this rule. A restored autosave
landing in `auto-3` instead of `auto-1` is correct behaviour, not a defect.

### 4.4 `WHERE-TO-PUT-THESE.txt`

Written per game, naming the three desktop paths from §2 with `<save_directory>`
substituted. When `saveDirectory` is `null`, it says instead that this game keeps its
saves next to the game itself, in a `saves` folder — which is what `renpy.py:170-171`
does — and that the files go there.

This file is why the PC half needs no app, and no instructions from us anywhere else.

## 5. Coming back from a PC

Import accepts, in addition to our own `.zip`:

- **A bare `-LT1.save` file.** One slot, straight off a desktop. No manifest, so it
  cannot name its game: it imports into the game she picks, under §4.2 case 3.
- **A `.zip` with no manifest** containing `*-LT1.save` files at any depth. Same
  treatment. This is what she gets by zipping a desktop save folder herself.

Both are foreign by definition and take §6's warning.

Rejected with a plain sentence: a zip that contains no save files, and a game archive
picked by mistake — its contents will be a `game/` directory, which is a recognisable and
reportable thing, not a generic failure.

## 6. Safety, stated honestly

**A Ren'Py save file is an unrestricted Python pickle.** `renpy/compat/pickle.py:278`
overrides `find_class` only to remap `datetime` and rewrite `_ast` nodes, then falls
through to `super().find_class`. No allowlist. Loading a save can execute arbitrary code,
and nothing the app does changes that.

This is not a new class of risk in this app: she installs games as `.zip`s and a Ren'Py
game *is* Python. A save is the same trust level as the game it belongs to. The design
consequence is therefore narrow and specific:

- Files carrying our manifest import without comment.
- Anything else — a bare `.save`, a manifest-free zip — shows **one** plain warning
  before it is loaded: this came from outside VNPlayer, Ren'Py saves can contain code,
  open it only if you trust where it came from.
- **No checkmark, ever.** The app must not display anything that reads as "verified
  safe", because it cannot verify that. `sha256` in the manifest proves the file is
  undamaged, which is a different claim, and the UI must not blur the two.

Structural limits reuse `EntryPolicy` unchanged — entry count, per-entry size, total
size, path traversal, absolute and drive-qualified paths, symlinks, duplicate names. It
already carries the tests for all of them. Save transfer adds no new policy and gets no
exemption from the old one.

## 7. Where the code goes

| file | responsibility |
|---|---|
| `swift/VNPlayerCore/.../SaveTransfer.swift` | manifest model, read and write |
| `swift/VNPlayerCore/.../SaveExporter.swift` | directory → `.zip` |
| `swift/VNPlayerCore/.../SaveImporter.swift` | `.zip` or bare `.save` → a plan |
| `swift/VNPlayerCore/.../SlotPlacement.swift` | §4.3, pure and separately testable |
| `spike/Sources/...` | share sheet, picker, the strip's two new icons |
| `shell/vnshell/lifecycle.py` | `saveDirectory` on the `gameReady` event |

`SlotPlacement` is its own file on purpose. It is the rule with the sharpest consequence
for being wrong, it is pure string and set logic, and it must be testable without a zip,
a file system or a device.

## 8. Testing

**Headless, in `VNPlayerCore`** — the bulk of it:

- manifest round-trip, and a `format` higher than we know is reported, not guessed
- export → import → the same files, byte for byte
- slot placement: free slot, taken slot, a full page, `auto-`/`quick-` pages, and the
  suffix preserved through every rename
- identical content is skipped rather than duplicated — run a restore twice
- bare `.save` accepted; manifest-free zip accepted; a game archive rejected *by name*
- `sha256` mismatch reported as damage
- every `EntryPolicy` rejection still fires through this path

**In Python:** `gameReady` carries `saveDirectory`, including the `None` case.

**On device**, in this order:

1. Export a game with real saves → AirDrop to a PC → unzip into the folder the txt names
   → the desktop game lists the slots.
2. Zip a desktop save folder → import → the slots appear on the phone.
3. Back up everything → delete a game → reinstall it → restore → saves are back.
4. Import a backup twice. Nothing duplicates.
5. Import from the strip mid-game. It returns to the library, then imports.

## 9. Open question this milestone should settle

**Does a Sideloadly re-sign at the seven-day expiry preserve the Data container, or wipe
it?** Unverified. If it preserves, backup is a convenience. If it wipes, backup is the
feature that makes the app usable at all, and the library should prompt for one. Cheap to
answer on the next expiry cycle, and it changes only how loudly the app asks — not any of
the machinery above.

## 10. Not in this milestone

Cover art, rename, re-import/update — the library polish punch-list, which gets its own
short design and needs no spec. App icon and battery measurement, both declined. Cloud
sync of any kind: never proposed, and out of scope for an app that must not need a
network.

**Versioning** here means the manifest's `format` integer plus a release tag at the end.
It is not a subsystem.
