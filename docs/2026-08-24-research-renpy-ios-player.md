# Research: Open-source Ren'Py player for iOS

Date: 2026-08-24. Status: research complete, pre-design.

## 1. The market we'd be entering

All four existing iOS Ren'Py players are closed-source. None is free-and-unlimited.

| App | Dev | Model | Notes |
|---|---|---|---|
| Renpy Pocket (id6748696950) | 小朋 蒯 | Free + $4.99 "Unlimited Games Unlock" + rewarded ads | 107.9 MB, iOS 15.6+, 4.1★/144, 18+. Ren'Py 8 only. Live2D added v2.66. Reviews: paywalled after 1 import; crashes burn the daily free allowance; ad cooldowns escalate 5→7→10→13 min; >1 GB imports fail. |
| Renpy 7 Pocket (id6748915172) | same | same | Separate app purely because Ren'Py 7 = Python 2 and can't share a binary with Ren'Py 8. |
| Spark – Ren'Py Novels (id6474479684) | Devon Lewis | **$6.99 up front** + tips + $5.99/mo or $19.99/yr sponsor | 4.8★/200. The feature leader: bundles **8 engine builds** (8.3.0/8.2.3/8.1.3/8.0.3/7.8.0/7.7.3/7.6.3/7.5.3), per-novel engine selection, zip/7z/apk import, save backup + iCloud sync, gallery viewer, **variable editor**, Apple Translate, controller support, visionOS. |
| RenpyReader | — | freemium | Also handles ONScripter. |

Read: Spark is the quality bar; Pocket is the one people resent. A genuinely free, ad-free, open-source player has clear oxygen — the complaint pattern is entirely about monetization friction, not missing features.

## 2. How Ren'Py actually runs on iOS (verified against source)

Official pipeline: **renpy-build** (github.com/renpy/renpy-build) — `renios` was archived 2026-08-09 and folded in. Ships prebuilt as `renpy-8.5.3-renios.zip`, **130 MB**, containing the Xcode "prototype" project + prebuilt static libs (`prototype/prebuilt/release/*.a` for `ios-arm64`, `debug/` for both simulator arches) + a `base/` tree with the Python runtime and Ren'Py itself.

Current stack (8.5.3, released 2026-05-15): **CPython 3.12.7**, **SDL3** + SDL3_image, MetalANGLE (GLES→Metal), FFmpeg 4.3.1, freetype 2.13.3, harfbuzz 8.0.1, fribidi, libavif/aom/yuv/jpeg/png/webp, openssl 3.3.2, assimp, **pyobjus** (Python→Objective-C bridge, the iOS analogue of pyjnius).

### The boot path — this is the whole ballgame

`renios/prototype/main.c`:

```c
int main(int argc, char **argv) { return SDL_RunApp(argc, argv, launcher_main, NULL); }
```

`runtime/librenpython.c` → `launcher_main()`:

- preinitializes Python **isolated**, UTF-8 mode
- `search_python_home()` — on iOS: `<exedir>/base`
- `search_pyname()` — on iOS: `<exedir>/base/main.py`
- **`config.parse_argv = 1`**, then `PyConfig_SetBytesArgv(argv0, pyname, ...rest)` → `Py_RunMain()`

`renpy/bootstrap.py`:

```python
if args.basedir:
    basedir = os.path.abspath(args.basedir)
else:
    basedir = renpy_base
```

**⇒ Passing `--basedir <path>` through `launcher_main`'s argv makes Ren'Py run a game from any directory on disk.** That is the single most important finding: no engine fork is required to point it at user-imported content.

### Switching games without killing the app

`bootstrap.py` (~lines 350–395) already contains a restart loop:

```python
while exit_status is None:
    basedir  = get_alternate_base(original_basedir)
    gamedir  = renpy.__main__.path_to_gamedir(basedir, name)
    renpy.config.basedir = basedir; renpy.config.gamedir = gamedir
    renpy.main.main()
    ...
    except renpy.game.UtterRestartException:
        renpy.reload_all(); exit_status = None
```

`get_alternate_base()` already has an explicit `renpy.ios` branch resolving Application Support via `NSFileManager` through pyobjus. So the supported, in-tree mechanism for "run a different tree on the next iteration" already exists. Overriding `get_alternate_base` to consult a "next game" pointer and raising `UtterRestartException` gives **in-process game switching** — no `exit(0)`, no process respawn (iOS forbids spawning processes anyway).

### Fallback if UtterRestart proves leaky

Ren'Py's own launcher *is a Ren'Py game*. Worst case, the library UI ships as a bundled `.rpy` app that is simply game #0 in the same loop.

## 3. The Ren'Py 7 problem

Ren'Py 7.x = Python 2.7; Ren'Py 8.x = Python 3.9+. `.rpyc` is marshalled Python bytecode — 8 always writes RPYC v2, 7 wrote v1. Distributed games ship `.rpyc` inside `.rpa` archives, usually without `.rpy` sources. **Therefore Ren'Py 8 cannot run most Ren'Py 7 games.** This is why Pocket shipped two separate apps and why Spark bundles eight engines.

Ren'Py 7.8 is the final 7.x line; official support ended at 8.4. A large share of the actually-popular catalogue (long-running Patreon VNs) is still 7.x.

Bundling multiple engines in one binary means multiple CPython runtimes — two `libpython` static archives cannot be linked into one Mach-O without symbol collisions. Spark almost certainly ships each engine as a separate embedded `.framework`/dylib and `dlopen`s the chosen one (legal on iOS for frameworks inside your own signed bundle). A real but v2-scoped problem.

## 4. App Store legality — the actual risk

Verbatim, current guidelines:

- **2.5.2**: "Apps should be self-contained in their bundles... nor may they download, install, or execute code which introduces or changes features or functionality of the app." Executing user-supplied `.rpyc` is, on a strict reading, exactly this.
- **4.7** carve-out covers only HTML5/JS mini-apps, streaming games, chatbots, plug-ins, plus "retro game console and **PC emulator** apps can offer to download games." A Ren'Py player is not obviously an emulator.

But four such apps are live and approved. The posture that works in practice: **the app never downloads anything; the user imports a local file via Files/Share Sheet.** Same shape as Pythonista, a-Shell, iSH, Delta. Our app must never fetch a game over the network — no built-in browser, no game catalogue, no URL import. That is a hard architectural constraint, and it also keeps 4.7.1/4.7.4 (content index, filtering, universal links) from attaching at all.

Other real risks:

- **Age rating.** 2025 overhaul: tiers are now 4+/9+/13+/16+/18+. Existing players are rated 18+. From 2026-02-24, AU/BR/SG block 18+ downloads without verified adult status. Expect 18+, and it costs reach.
- **1.2 / UGC** may be argued at us even though content is local-only.
- **3.1.1** is irrelevant to us — we sell nothing.

TestFlight external testing goes through **Beta App Review**, materially lighter than full App Review. Limits: 100 internal / 10,000 external testers; builds expire **90 days** after upload; a fresh Beta App Review triggers on the first build of each version and on changes to entitlements, encryption declaration, privacy labels, or beta description.

Escape hatches if App Review says no: AltStore/SideStore sideloading of the `.ipa`, TrollStore, and AltStore PAL in the EU. Open-sourcing means users can always build and sign it themselves — the repo is the real deliverable; TestFlight is a distribution convenience.

## 5. Licensing

- Ren'Py core: **MIT**, but parts derive from LGPL, so "Ren'Py games must be distributed in a manner that satisfies the LGPL."
- **FFmpeg: LGPL** → must ship license text and permit relinking. Static linking plus published corresponding source (which we do anyway, being open source) satisfies this. Ren'Py's iOS docs recommend the blurb: *"This program contains free software licensed under a number of licenses, including the GNU Lesser General Public License."*
- SDL/SDL3_image/freetype: Zlib. Python: PSF. libpng: PNG. harfbuzz: Old MIT. bzip2, zlib: own permissive.
- **Live2D Cubism Core is proprietary** — cannot be redistributed in an open-source app without a Live2D license agreement. **Exclude Live2D from v1.** Pocket has it; that is a differentiator we cannot legally match for free.
- **unrar** is source-available but not OSS-licensed → prefer zip + 7z; skip RAR, or make it user-supplied.
- Our own app: **MIT / Apache-2.0 / MPL-2.0 recommended, not GPLv3** — GPLv3 is famously awkward on the App Store (Apple ToS vs. anti-DRM terms; the VLC precedent).

## 6. Build & CI reality

iOS builds require macOS + Xcode. The user is on Windows 11 — but **GitHub Actions `macos-15` runners are free for public repositories**, and fastlane plus an App Store Connect API key can archive and push to TestFlight in ~8–12 min per run. So no Mac purchase is required; an **Apple Developer Program membership ($99/yr) is unavoidable** for TestFlight.

Size budget: App Store hard cap is 4 GB uncompressed; anything over 200 MB needs Wi-Fi. One engine ≈ Pocket's 108 MB. Eight engines ≈ Spark-scale. Comfortable either way.

## 7. Proposed shape (pre-design sketch)

- **Native SwiftUI shell**: library grid, import (UIDocumentPicker + Share Sheet + Files "Open In"), per-game settings, save backup/restore, storage management.
- **Embedded Ren'Py runtime**: the prebuilt renios static libs plus `base/` tree, launched via `SDL_RunApp` → `launcher_main` with `--basedir <Documents/Games/<id>>`.
- **Thin engine patch layer**: override `get_alternate_base` (or a small `sitecustomize` shim) to read the "next game" pointer; return-to-library = `UtterRestartException` back to the bundled library game or a Swift-side signal.
- **Importer**: zip + 7z + apk extracted natively in Swift (apk is a zip; the game lives in `assets/x-game/`), no Python involvement.
- **Hard rule**: zero network game acquisition, ever.
- **v1 = Ren'Py 8 only.** Multi-engine 7.x coverage is a v2 that pays for itself in catalogue reach but multiplies build complexity.

## 8. Open questions for the human

1. Apple Developer Program account — have one, or willing to pay $99/yr?
2. v1 scope: Ren'Py 8 only, or is Ren'Py 7 coverage table stakes?
3. Which Spark features are must-have vs. nice-to-have (translate, variable editor, gallery, iCloud saves, controller)?
4. License choice for our code.
5. Repo/product name.

## Sources

renpy.org/doc/html/ios.html · github.com/renpy/renpy-build · github.com/renpy/renios (archived) · renpy/renpy `renpy/bootstrap.py` · renpy-build `runtime/librenpython.c`, `renios/prototype/main.c`, `runtime/iossupport.py` · developer.apple.com/app-store/review/guidelines · renpy.org/doc/html/license.html · App Store listings for Renpy Pocket / Renpy 7 Pocket / Spark
