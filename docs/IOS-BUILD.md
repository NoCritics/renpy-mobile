# iOS build notes

Recorded from real GitHub Actions runs on `macos-15`, triggered by
`.github/workflows/ios-build.yml` (job `discover`) on branch `milestone-b`. It started as
a discovery-only workflow — it fetched the pinned Ren'Py 8.5.3 SDK and `renios` package
and inventoried what `renios` actually contains, so Tasks 2-4 of the Milestone B plan
could be written against real facts instead of assumptions, since nobody on this project
had opened `renpy-8.5.3-renios.zip` before this task. The `discover` job name is a
holdover from that original scope: the same workflow now also generates the Xcode
project, overlays the shell layer, archives and packages the unsigned `.ipa`, and (on a
tag push) attaches it to a GitHub Release. This document now records Tasks 1 through 6 —
including the first physical-device install — not just the original discovery pass.

**Every figure below is quoted or directly derived from a specific CI log line or a
downloaded workflow artifact — see the run links.** Anything not captured by the
workflow is marked "not determined" rather than guessed.

## CI runs (evidence trail)

All runs: https://github.com/NoCritics/renpy-mobile/actions/workflows/ios-build.yml

| Run | Outcome | What happened |
|---|---|---|
| [32739725370](https://github.com/NoCritics/renpy-mobile/actions/runs/32739725370) | FAILED at "Fetch dependencies" | `fetch_ios_deps.sh`'s original assumption — that `renpy-8.5.3-renios.zip` unpacks to `vendor/renpy-8.5.3-renios/`, containing `buildlib/` — was wrong. Script correctly refused to weaken its own assertion and exited 1: `Unpack did not produce /Users/runner/work/renpy-mobile/renpy-mobile/vendor/renpy-8.5.3-renios/buildlib`. This is the anticipated finding from the task brief, now confirmed. |
| [32739844364](https://github.com/NoCritics/renpy-mobile/actions/runs/32739844364) | FAILED (same, expected) | Added a temporary diagnostic step (`find vendor -maxdepth 3`) that ran regardless of the later assertion failure, to read the true unpack layout out of the log rather than guess it. It showed the zip unpacks to `vendor/renios/`, not `vendor/renpy-8.5.3-renios/`. |
| [32740043788](https://github.com/NoCritics/renpy-mobile/actions/runs/32740043788) | FAILED at "Fetch dependencies" | Corrected the script to use `vendor/renios` as the unpack directory, but introduced a `set -u` bug: `scripts/ios/fetch_ios_deps.sh: line 26: name: unbound variable`. A single `local a=... b=${4:-$a}` statement evaluates all right-hand sides before any assignment lands, so `$a` is still unset under `nounset` when computing `b`'s default. Reproduced and confirmed in isolation with `bash -c 'set -u; f(){ local x="$1" y="${2:-$x}"; ...}; f hello'`. |
| [32740201093](https://github.com/NoCritics/renpy-mobile/actions/runs/32740201093) | **GREEN** | Split the `local` statement into two. Full job passed: toolchain recorded, both archives fetched and checksum-verified, `renios` inventoried, artifact uploaded. First clean inventory. |
| [32740372920](https://github.com/NoCritics/renpy-mobile/actions/runs/32740372920) | **GREEN** | Added `xcrun --sdk iphoneos --show-sdk-version` / `xcodebuild -showsdks` to the toolchain step — the brief's Step 4 explicitly asks for the runner's default iOS SDK version, and the original toolchain step never captured it. Also downloaded via `gh run download` to inspect the uploaded `Info.plist` / `project.pbxproj` artifact directly (`renios-inventory`, artifact ID 9524825897). |
| [32741864714](https://github.com/NoCritics/renpy-mobile/actions/runs/32741864714) | **GREEN** | Review fix: an earlier draft of this document claimed the `prebuilt/debug/` `.a` set matched `prebuilt/release/` "by name prefix" based on a combined, `head -50`-truncated listing that could not actually see the debug directory's contents. Split the inventory step into separate, unbounded, sorted `find` calls per directory (also removing the `head` cap, which was a latent `SIGPIPE`/`pipefail` hazard). This run is the actual evidence for the 40/40 split and identical filename set recorded below. |

Final green run for the toolchain/Xcode-project/Info.plist facts: **32740372920**.
Final green run for the prebuilt-library facts: **32741864714**. All facts below are
traced to whichever of these (or 32740201093, where all three overlap) actually shows
them.

## Toolchain on the runner

From `Record toolchain` (run 32740372920):

```
ProductName:            macOS
ProductVersion:         15.7.7
BuildVersion:            24G720
Xcode 16.4
Build version 16F6
/Applications/Xcode_16.4.app/Contents/Developer
```

- **macOS 15.7.7** (build 24G720) — this is what `runs-on: macos-15` currently resolves to.
- **Xcode 16.4** (build 16F6) is the *default* selected toolchain (`xcode-select -p` points
  at `Xcode_16.4.app`).
- Other Xcode versions are installed side-by-side and selectable via `xcode-select` or
  `DEVELOPER_DIR` if ever needed: `16.0`, `16.1`, `16.2`, `16.3`, `16.4`, `26.0`, `26.1`,
  `26.2`, `26.3` (each present as both a plain and a `.0`-suffixed app bundle), plus a
  `Xcode.app` alias.
- **Default iOS SDK: 18.5** (`xcrun --sdk iphoneos --show-sdk-version` → `18.5`).
  `xcodebuild -showsdks` confirms: `iOS 18.5 -sdk iphoneos18.5` and
  `Simulator - iOS 18.5 -sdk iphonesimulator18.5`. Only one SDK version is installed;
  there is no explicit choice to make here unless a different Xcode is selected.

## renios: the critical finding

**`renpy-8.5.3-renios.zip` unpacks to a top-level directory named `renios`, not
`renpy-8.5.3-renios`.** The zip *file* keeps the versioned name
(`renpy-$VERSION-renios.zip`, matching the download URL), but its internal top-level
directory does not carry the version — unlike the SDK zip, whose internal directory
does match its filename (`renpy-8.5.3-sdk/`). This is exactly the asymmetry
`launcher/game/ios.rpy:49` implies by looking for `<sdk>/renios`.

`scripts/ios/fetch_ios_deps.sh` now accounts for this via an optional 4th argument to its
`fetch()` helper (`dirname`, defaulting to `renpy-$RENPY_VERSION-$name` but overridden to
`renios` for the renios package). The `buildlib` marker check now passes for real, not
because it was weakened.

## renios top-level layout

From `Inventory renios` (run 32740201093 and 32740372920, identical). The step's actual
command was `ls -la "$RENIOS"`; the three names below are the entries it listed, not a
verbatim reproduction of the full `ls -la` output (permissions/size/date columns
omitted for brevity):

- `buildlib/`
- `hash.txt`
- `prototype/`

Depth-2:
```
vendor/renios/buildlib
vendor/renios/buildlib/__pycache__
vendor/renios/buildlib/renios
vendor/renios/prototype
vendor/renios/prototype/Frameworks
vendor/renios/prototype/Media.xcassets
vendor/renios/prototype/prebuilt
vendor/renios/prototype/prototype.xcodeproj
```

- `buildlib/` holds a Python package (`buildlib/renios/`) and `xcodeprojer.py` — presumably
  Ren'Py's own iOS build driver (referenced from the launcher's `ios.rpy`). Its contents
  were **not inventoried** in this task; that is out of scope for "what does the package
  contain," and is a candidate for closer reading before Task 2/3 if the build needs to
  invoke it rather than drive Xcode directly.
- `hash.txt` exists at the top level — not opened, contents presumed a build hash/version
  stamp, **not determined**. (Its size was previously stated here as "64 bytes"; that
  figure traces to no quoted CI log line and has been removed rather than repeated
  unverified.)
- `prototype/` is the actual Xcode project skeleton: `Frameworks/`, `IAPHelper.m`,
  `Info.plist`, `Launch Screen.storyboard`, `LaunchImage-background.png`,
  `LaunchImage-foreground.png`, `Log.m`, `main.c`, `Media.xcassets`, `prebuilt/`,
  `prototype.xcodeproj`, `VideoPlayer.m`.

## The Xcode project

- **Location:** `vendor/renios/prototype/prototype.xcodeproj` (only one `.xcodeproj`
  found under `renios`, at depth 2 relative to it).
- **Scheme:** `xcodebuild -list -project .../prototype.xcodeproj` reports exactly one
  target and one scheme, both named **`prototype`**:
  ```
  Information about project "prototype":
      Targets:
          prototype
      Build Configurations:
          Debug
          Release
      If no build configuration is specified and -scheme is not passed then "Release" is used.
      Schemes:
          prototype
  ```
- **Deployment target:** `IPHONEOS_DEPLOYMENT_TARGET = 13.0` (from `project.pbxproj`,
  both Debug and Release configs — not exposed in `Info.plist`, contrary to the task
  brief's phrasing "deployment target ... from `Info.plist`"; it lives in the project's
  build settings instead. Confirmed by downloading the `renios-inventory` artifact and
  reading `prototype/prototype.xcodeproj/project.pbxproj` directly).
- **Bundle identifier:** `PRODUCT_BUNDLE_IDENTIFIER = org.renpy.prototype` (from
  `project.pbxproj`, both target configs). `Info.plist` itself does **not** hardcode a
  bundle identifier — it uses the build-setting placeholder `$(PRODUCT_BUNDLE_IDENTIFIER)`,
  which Xcode resolves from the pbxproj value at build time. This placeholder is
  `org.renpy.prototype` out of the box; our fork will need to override
  `PRODUCT_BUNDLE_IDENTIFIER` (and `PRODUCT_NAME`, currently `prototype`) when driving the
  build, presumably via an xcconfig or build-setting override rather than editing the
  project file (the project ships unmodified per plan constraints on Ren'Py's own files —
  though `prototype.xcodeproj` is arguably "ours to configure" rather than "Ren'Py source";
  this line needs a ruling before Task 2/3).
- **Other build settings of note** (from `project.pbxproj`):
  - `SDKROOT = iphoneos`, `SUPPORTED_PLATFORMS = "iphonesimulator iphoneos"`.
  - `TARGETED_DEVICE_FAMILY = "1,2"` — both iPhone and iPad, out of the box.
  - `INFOPLIST_FILE = "$(SRCROOT)/Info.plist"`.
  - `LIBRARY_SEARCH_PATHS[sdk=iphoneos*] = "$(SRCROOT)/prebuilt/release"` but
    `LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*] = "$(SRCROOT)/prebuilt/debug"` for the
    Debug configuration — release libraries linked for on-device Debug builds, debug
    libraries for the simulator. This looks backwards at a glance; not investigated
    further, flagged as a genuine oddity for whoever writes the actual build task.
  - `CODE_SIGN_IDENTITY[sdk=iphoneos*] = "iPhone Developer"` — a signing identity is named
    in the project, but nothing in this task supplied one; consistent with "unsigned
    `.ipa`" being the actual Task 2-4 goal (codesign step deliberately skipped/overridden).

## Info.plist (verbatim, `prototype/Info.plist`)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>$(PRODUCT_NAME)</string>
	<key>CFBundleExecutable</key>
	<string>$(EXECUTABLE_NAME)</string>
	<key>CFBundleIdentifier</key>
	<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$(PRODUCT_NAME)</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleSignature</key>
	<string>????</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSRequiresIPhoneOS</key>
	<true/>
	<key>UILaunchStoryboardName</key>
	<string>Launch Screen</string>
	<key>UIRequiresFullScreen</key>
	<true/>
	<key>UIStatusBarHidden</key>
	<true/>
	<key>UISupportedInterfaceOrientations</key>
	<array>
		<string>UIInterfaceOrientationLandscapeRight</string>
		<string>UIInterfaceOrientationLandscapeLeft</string>
	</array>
</dict>
</plist>
```

**Notable:** `UISupportedInterfaceOrientations` lists only the two landscape
orientations — no portrait. Milestone A's shell layer and design docs do not appear to
have settled an orientation policy; this is a real decision Task 2/3 (or the UI work)
needs to make, not an assumption to inherit silently. Flagging rather than guessing.

## Prebuilt static libraries

Originally the inventory step listed `.a` files with a single `find ... | head -50`
across both `prebuilt/release/` and `prebuilt/debug/` combined — that cap made it
impossible to actually see the full debug-directory listing, and an earlier version of
this document claimed the debug set was "confirmed same library set by name prefix"
without evidence for that claim. Caught in review. The inventory step now runs
`find` separately per directory, unbounded and sorted, so this is independently
verified from run
[32741864714](https://github.com/NoCritics/renpy-mobile/actions/runs/32741864714)
(green):

- **`prototype/prebuilt/release/`: 40 `.a` files.** **`prototype/prebuilt/debug/`: 40
  `.a` files.** Both counts are `wc -l` on their own directory-scoped `find`, not a
  combined/truncated listing.
- **The two directories contain the identical 40 filenames**, verified by comparing the
  two full sorted listings from the same run (not inferred from a shared prefix). Sorted
  list (same in both directories): `libaom`, `libassimp`, `libavcodec`, `libavfilter`,
  `libavformat`, `libavif`, `libavresample`, `libavutil`, `libbrotlicommon`,
  `libbrotlidec`, `libbrotlienc`, `libbz2`, `libcrypto`, `libffi`, `libfreetype`,
  `libfribidi`, `libharfbuzz-cairo`, `libharfbuzz-subset`, `libharfbuzz`, `libjpeg`,
  `liblzma`, `libmockrt`, `libpng16`, `libpython3.12`, `librenpy`, `librenpython`,
  `libSDL2_image`, `libSDL2_test`, `libSDL2`, `libSDL2main`, `libsharpyuv`, `libssl`,
  `libswresample`, `libswscale`, `libturbojpeg`, `libwebp`, `libwebpdemux`, `libwebpmux`,
  `libyuv`, `libz`.
- **`du -sh vendor/renios` = 378M** (run 32741864714). An earlier green run
  ([32740201093](https://github.com/NoCritics/renpy-mobile/actions/runs/32740201093))
  measured **364M** for the same, checksum-pinned, byte-identical archive on a different
  ephemeral runner instance. This 14M delta between two runs of an identical input is
  itself unexplained — plausibly APFS disk-usage accounting variance between VM
  instances rather than a real content difference (file names, counts, and timestamps
  match exactly across both runs), but that is a guess, not a finding; treat the
  directory-size figure as **approximate, not exact**, and don't be surprised if a future
  run reports a third number. This is the combined size of the *entire* `renios`
  directory (both `.a` sets, the Xcode project, image assets, the `buildlib/` Python
  package, `__pycache__`, etc.) — **not** a `.a`-files-only figure. No command in this
  task isolated the static-library-only byte total; that is **not determined**.
- **Also present, and not caught by the `.a` search:** `prototype/Frameworks/` contains
  `MetalANGLE.xcframework` (with `Info.plist` at three levels: the xcframework root, an
  `ios-arm64_armv7` slice, and an `ios-arm64_i386_x86_64-simulator` slice). This is a
  prebuilt `.xcframework`, a different packaging format than a bare `.a`, and any build
  script driven purely by `find -name "*.a"` will silently miss it. Confirmed by
  downloading the `renios-inventory` artifact (its glob `**/Info.plist` happened to catch
  the xcframework's plists as a side effect).

## Does `prototype/base/` ship, or is it generated?

**It does not ship.** From the log:

```
=== does base/ ship, or is it generated? ===
ls: vendor/renios/prototype/base: No such file or directory
no prototype/base — generated by ios_populate
```

Confirmed independently by the depth-2 `find` listing above, which enumerates every
directory under `prototype/` and does not include `base/`. **This means whatever step
populates `prototype/base/` (game files, generated Xcode-ready assets, or similar) is a
real, required step for Task 2 — it is not something the renios package ships ready to
use.** The exact mechanism (`buildlib/renios`? `xcodeprojer.py`? a launcher-side command?)
was not investigated in this task and is **not determined** — that discovery belongs to
whichever task first needs to produce a buildable Xcode project.

## Findings that contradict or refine the plan's assumptions

1. **Directory name mismatch (the headline finding).** `renpy-8.5.3-renios.zip` unpacks
   to `renios/`, not `renpy-8.5.3-renios/`. `fetch_ios_deps.sh` and `ios-build.yml` are
   now written against the real name.
2. **Deployment target and bundle identifier are not in `Info.plist`.** The plan's Step 4
   phrasing ("deployment target and bundle identifier from `Info.plist`") assumes they're
   plist-visible; they're actually build settings in `project.pbxproj`, referenced from
   `Info.plist` only as `$(...)` placeholders. Anyone changing them for our fork edits the
   Xcode project / build settings, not the plist.
3. **The bundle identifier and product name are Ren'Py's own placeholders**
   (`org.renpy.prototype` / `prototype`), not something we choose freely inside a vendored,
   unmodified template — they live inside `prototype.xcodeproj`, which sits in the
   downloaded (not vendored-into-git) `renios` package. Whether overriding them counts as
   "modifying Ren'Py's source" (forbidden by the plan) or "configuring our build" needs an
   explicit ruling before Task 2/3 touch the project.
4. **A prebuilt `.xcframework` ships alongside the `.a` files** (`MetalANGLE.xcframework`,
   3 architecture slices). Any later script that inventories or copies "prebuilt
   libraries" by `*.a` glob alone will miss it.
5. **Interface orientation is hardcoded to landscape-only** in the shipped `Info.plist`.
   Not previously decided anywhere in Milestone A or B planning docs.
6. **`prototype/base/` genuinely does not ship** — confirms the plan's own suspicion
   (recorded in the task brief) rather than contradicting it. This determines that some
   generation/population step is a hard requirement of Task 2, not an optional nicety.
7. **`LIBRARY_SEARCH_PATHS` for the Debug configuration point at `release` libs for device
   and `debug` libs for the simulator** — looks inverted; unexplained, flagged for whoever
   writes the real build task.
8. **The runner ships many Xcode versions** (16.0–16.4, 26.0–26.3), not just one; the
   default is 16.4 with iOS SDK 18.5. If a later task needs a different Xcode (e.g. to
   match the deployment target's minimum supported Xcode, or for `xcodebuild` flags only
   present in a newer version), `DEVELOPER_DIR`/`xcode-select` can select among the
   pre-installed set without any extra install step.

## Not determined (do not infer these)

- Exact byte size of the `.a` files alone (only the whole-package `du` figure — 364M or
  378M depending on the run, see "Prebuilt static libraries" above — and the 80-file
  count are known).
- Why `du -sh vendor/renios` reported two different totals (364M, then 378M) across two
  runs of the same checksum-pinned zip.
- Contents/purpose of `buildlib/renios/` and `xcodeprojer.py` beyond their filenames.
- Contents/purpose of `hash.txt`.
- The actual mechanism that populates `prototype/base/` (name of the script, its inputs,
  whether it needs network access, whether it runs inside the SDK's bundled Python or
  system Python).
- Whether the workflow's push trigger successfully triggers from a fork (untested; only
  exercised from `NoCritics/renpy-mobile` itself, which is the repo, not a fork of it).

---

# Task 2 — headless Xcode project generation

`scripts/ios/generate_xcode.sh` drives Ren'Py's own `ios_create` and `ios_populate`
launcher commands (`launcher/game/ios.rpy`) against `shell-project/`, producing a
generated Xcode project under `build/xcode/VNPlayer/`. Wired into `ios-build.yml`'s
`discover` job as two new steps, "Generate Xcode project" and "Inspect generated
project", inserted directly after "Fetch dependencies".

**Both commands run headlessly, without incident, on the first CI attempt after the
brief's own command line was corrected.** The brief as originally written
(`ios_create "$PROJECT" --destination "$DEST"`) cannot work — `ios.rpy:430-431` declares
both `project` and `destination` as positional arguments, not a `--destination` flag —
so the script uses the positional form from the start; this was never observed to fail
in CI because it was caught by reading `ios.rpy`'s source before the first push (see
`task-2-context.md` §1). No other command-line correction was needed.

## CI runs (evidence trail)

All runs: https://github.com/NoCritics/renpy-mobile/actions/workflows/ios-build.yml

| Run | Outcome | What happened |
|---|---|---|
| [32742797871](https://github.com/NoCritics/renpy-mobile/actions/runs/32742797871) | **GREEN** | First attempt. `generate_xcode.sh` committed with the correction sheet's fixes (positional args, `DEST` = project dir itself, `rm -rf` before creating, SDK-bundled Python) applied from the outset. `ios_create` completed in 9s, `ios_populate` in 4s. `base/`, `base/game/`, `base/main.py` all confirmed present in the generated tree. Scheme name confirmed as `VNPlayer` from real `xcodebuild -list` output. |
| [32743037562](https://github.com/NoCritics/renpy-mobile/actions/runs/32743037562) | **GREEN** | Added a `grep` for `PRODUCT_BUNDLE_IDENTIFIER` / `PRODUCT_NAME` to the same inspection step, to record (not fix) the placeholder bundle id per correction sheet §6. `ios_create` completed in 5s, `ios_populate` in 3s — confirms the first run's timings were not a fluke and gives two independent samples. Bundle id and scheme name reproduced identically. |

Both runs are green; no failure mode was hit for this task. The two failure modes the
brief and correction sheet name as worth distinguishing (CLI surface mismatch vs. an
empty/incomplete `base/`) were both **not encountered** — evidence below.

## Timings (`ios_create` and `ios_populate` timed separately, wall-clock, via `date +%s`
around each command)

| Run | `ios_create` | `ios_populate` |
|---|---|---|
| 32742797871 | 9s | 4s |
| 32743037562 | 5s | 3s |

Both phases complete in single-digit seconds on a `macos-15` runner. Note `ios_create`
itself ends by calling `ios_populate(p, gui=gui, target=target)` internally
(`ios.rpy:156`), so the Distributor actually runs during the `ios_create` phase too; the
standalone `ios_populate` call is a second, redundant run of the same Distributor logic
— this is why its own timing (3-4s) is smaller than `ios_create`'s (5-9s), which pays for
both the project-copy/rename step and its own internal populate pass. This matches
correction sheet §8's prediction exactly.

## Generated tree layout

From run 32742797871's `=== result ===` (`find "$DEST" -maxdepth 2 | sort`, `$DEST` =
`build/xcode/VNPlayer`):

```
build/xcode/VNPlayer
build/xcode/VNPlayer/base
build/xcode/VNPlayer/base/game
build/xcode/VNPlayer/base/lib
build/xcode/VNPlayer/base/main.py
build/xcode/VNPlayer/base/renpy
build/xcode/VNPlayer/Frameworks
build/xcode/VNPlayer/Frameworks/MetalANGLE.xcframework
build/xcode/VNPlayer/IAPHelper.m
build/xcode/VNPlayer/Info.plist
build/xcode/VNPlayer/Launch Screen.storyboard
build/xcode/VNPlayer/LaunchImage-background.png
build/xcode/VNPlayer/LaunchImage-foreground.png
build/xcode/VNPlayer/Log.m
build/xcode/VNPlayer/main.c
build/xcode/VNPlayer/Media.xcassets
build/xcode/VNPlayer/Media.xcassets/AppIcon.appiconset
build/xcode/VNPlayer/prebuilt
build/xcode/VNPlayer/prebuilt/debug
build/xcode/VNPlayer/prebuilt/release
build/xcode/VNPlayer/VideoPlayer.m
build/xcode/VNPlayer/VNPlayer.xcodeproj
build/xcode/VNPlayer/VNPlayer.xcodeproj/project.pbxproj
```

**`base/` verified populated, not just exit-code-0-trusted.** The "Inspect generated
project" step's `ls -la build/xcode/*/base` (same run) shows:

```
total 24
drwxr-xr-x   6 runner  staff   192 Aug 24 15:06 .
drwxr-xr-x  15 runner  staff   480 Aug 24 15:06 ..
drwxr-xr-x   8 runner  staff   256 Aug 24 15:06 game
drwxr-xr-x   3 runner  staff    96 Aug 24 15:06 lib
-rw-r--r--   1 runner  staff  8922 Aug 24 15:06 main.py
drwxr-xr-x  68 runner  staff  2176 Aug 24 15:06 renpy
```

`base/game/` (`ls -la build/xcode/*/base/game`) contains our shell project's own files,
not placeholder content — confirming the Distributor packaged `shell-project/`, not
Ren'Py's own launcher/prototype game:

```
total 40
drwxr-xr-x  8 runner  staff   256 Aug 24 15:06 .
drwxr-xr-x  6 runner  staff   192 Aug 24 15:06 ..
drwxr-xr-x  6 runner  staff   192 Aug 24 15:06 cache
-rw-r--r--  1 runner  staff   266 Aug 24 15:06 options.rpy
-rw-r--r--  1 runner  staff  1422 Aug 24 15:06 options.rpyc
-rw-r--r--  1 runner  staff     9 Aug 24 15:06 script_version.txt
-rw-r--r--  1 runner  staff   583 Aug 24 15:06 script.rpy
-rw-r--r--  1 runner  staff  1288 Aug 24 15:06 script.rpyc
```

`options.rpy` and `script.rpy` are `shell-project/game/`'s own two source files (see
Task 2 context §"shell-project" layout) — the `.rpyc` siblings are Ren'Py's own
compilation output, and `cache/` is generated. This is direct evidence `base/game/`
holds our project, not an empty or placeholder tree.

## The scheme name (verbatim, for Task 3)

From run 32742797871's `xcodebuild -list -project build/xcode/VNPlayer/VNPlayer.xcodeproj`
(reproduced identically in run 32743037562):

```
Information about project "VNPlayer":
    Targets:
        VNPlayer

    Build Configurations:
        Debug
        Release

    If no build configuration is specified and -scheme is not passed then "Release" is used.

    Schemes:
        VNPlayer
```

**Scheme name: `VNPlayer`** (also the target name and the `.xcodeproj` basename). This
matches correction sheet §5's prediction from `shell-project/game/options.rpy`'s
`config.name = "VNPlayer"` exactly — confirmed from real output, not assumed.

## Bundle identifier and product name (recorded, not fixed — Task 3's job)

From the same runs' `grep -h "PRODUCT_BUNDLE_IDENTIFIER\|PRODUCT_NAME"
build/xcode/*/*.xcodeproj/project.pbxproj`:

```
PRODUCT_BUNDLE_IDENTIFIER = com.domain.VNPlayer;
PRODUCT_NAME = VNPlayer;
```

Matches correction sheet §6's prediction (`org.renpy.prototype` → `com.domain.<shortname>`)
exactly. `com.domain.VNPlayer` is Ren'Py's placeholder; per the correction sheet this is
Task 3's responsibility to override on the `xcodebuild` command line, not something Task 2
edits.

## Neither failure mode named in the brief was encountered

- **CLI surface mismatch:** not encountered. `ios_create` and `ios_populate` are
  registered exactly as `ios.rpy` describes; the correction sheet's positional-argument
  fix, applied before the first push, was sufficient. No `--help` output was needed
  because no "unrecognized arguments" error occurred.
- **Empty/incomplete `base/`:** not encountered. `base/`, `base/game/`, and `base/main.py`
  all exist and `base/game/` holds our actual project files (verified above, not inferred
  from exit code 0).

## Files changed

- `scripts/ios/generate_xcode.sh` (new) — the generation script.
- `.github/workflows/ios-build.yml` — added "Generate Xcode project" and "Inspect
  generated project" steps after "Fetch dependencies".
- `.gitignore` — added `build/` (the script writes `build/xcode/`, which must not be
  committed).
- `docs/IOS-BUILD.md` — this section.

## Not determined (Task 2)

- Whether `ios_create`/`ios_populate` remain headless-safe if `shell-project/` grows
  large numbers of assets — both runs used the current, minimal two-file
  `shell-project/game/` (`options.rpy`, `script.rpy`); timing and memory behavior at
  realistic game size is untested.
- Whether the generated project actually **builds** with `xcodebuild build`/`archive` —
  out of scope for Task 2, which only proves project *generation*; that is Task 3's job.
- Contents of `base/lib/` and `base/renpy/` beyond their directory names — not opened,
  only their presence and the presence of `base/main.py` was verified, per the brief's
  Step 3 checklist.

---

# Task 3 — archive unsigned and package an `.ipa`

`scripts/ios/package_ipa.sh` drives `xcodebuild archive` against the Task-2-generated
`build/xcode/VNPlayer/VNPlayer.xcodeproj`, with `CODE_SIGN_IDENTITY=""`,
`CODE_SIGNING_REQUIRED=NO`, `CODE_SIGNING_ALLOWED=NO` on the command line (no
`-exportArchive`, no certificate, no repository secret — the plan's binding constraint).
`PRODUCT_BUNDLE_IDENTIFIER=io.github.nocritics.vnplayer` is likewise passed on the command
line to override Ren'Py's `com.domain.VNPlayer` placeholder, editing no file. The
resulting `.xcarchive`'s `Products/Applications/VNPlayer.app` is copied into a `Payload/`
directory and zipped by hand into `build/VNPlayer.ipa` — the whole of what an unsigned
`.ipa` is. Wired into `ios-build.yml` as two new steps, "Package unsigned .ipa" and
"Upload .ipa", after "Upload inventory"; `timeout-minutes` raised from 45 to 90.

**The archive succeeded on the first CI attempt.** Nothing in this project had been
through `xcodebuild` before this task.

## CI run (evidence trail)

Run: [32744985444](https://github.com/NoCritics/renpy-mobile/actions/runs/32744985444) —
**GREEN**, all 11 steps, on branch `milestone-b`.

| Step | Started | Completed | Duration |
|---|---|---|---|
| discover (whole job) | 15:27:41Z | 15:28:56Z | **75s** |
| Package unsigned .ipa | 15:28:11Z | 15:28:50Z | **39s** |

The 39s figure covers the full `xcodebuild archive` (linking 40 prebuilt `.a` files, one
`.xcframework`, and four small `.c`/`.m` sources) plus the hand-packaging into `.ipa`. It
is fast because none of Ren'Py's C/Objective-C sources are compiled from source here —
`prebuilt/release/*.a` are prebuilt static libraries; `xcodebuild` only compiles
`main.c`, `IAPHelper.m`, `Log.m`, `VideoPlayer.m` and links.

`xcodebuild`'s own verdict, verbatim from the log:

```
** ARCHIVE SUCCEEDED **
```

(timestamp `2026-08-24T15:28:35.4251470Z`, ~24s into the step — the remaining ~15s is the
`Payload/` copy, `zip`, and this script's own assertions/`unzip -l`.)

## Correction-sheet §4 failure shapes: none of them hit

- **Embedded-framework signing (MetalANGLE).** Not encountered. No `CodeSign` invocation
  appears anywhere in the step's log (`grep -c "CodeSign " ` on the full raw log = 0).
  `ProcessXCFramework`/`builtin-process-xcframework` and a plain `strip`/`bitcode_strip`
  pair handled `MetalANGLE.xcframework` without ever attempting to sign it — consistent
  with `CODE_SIGNING_ALLOWED=NO` actually taking effect.
- **Architecture slices (armv7).** Not encountered, despite the on-disk slice directory
  being misleadingly named `ios-arm64_armv7` (confirmed from the log itself):
  ```
  Copy .../InstallationBuildProductsLocation/Applications/VNPlayer.app/Frameworks/MetalANGLE.framework
       .../build/xcode/VNPlayer/Frameworks/MetalANGLE.xcframework/ios-arm64_armv7/MetalANGLE.framework
  ```
  `-destination generic/platform=iOS` selected only the `arm64` binary slice from within
  that directory; no armv7-related link or launch error occurred. The directory name is a
  leftover label from when the slice held both architectures, not evidence the armv7 code
  itself was linked.
- **Inverted `LIBRARY_SEARCH_PATHS`.** Not encountered, and not applicable as predicted:
  the log's link warnings reference `.../prebuilt/release/libavcodec.a`,
  `libavutil.a`, `libswresample.a`, `libswscale.a` — i.e. the Release configuration
  correctly searched `prebuilt/release/`, matching correction sheet §4's expectation that
  building `-configuration Release` avoids the Debug configuration's inverted paths.
- **Only non-fatal output:** nine `ld` warnings of the form `skipping debug map object
  with duplicate name and timestamp: 1970-01-01 00:00:00.000000000
  .../prebuilt/release/libX.a(obj.o)` — expected noise from linking prebuilt static
  libraries whose object files share a zeroed mtime, not a build defect.

## The `.ipa`: verified, not just produced

**Size:** `27M` as reported by the CI job's own `ls -lh` (`-rw-r--r-- 1 runner staff 27M
... build/VNPlayer.ipa`); independently re-measured by downloading the `VNPlayer-ipa`
artifact from run 32744985444 to a local machine: **28,006,947 bytes** (≈26.7 MiB, matches
the `27M`-rounded figure).

**Internal structure**, from the CI step's own `unzip -l` (verbatim excerpt — GitHub
Actions truncated the log's final summary/totals line for this very verbose step, so the
count below is from an independent re-check, not this excerpt):

```
Archive:  /Users/runner/work/renpy-mobile/renpy-mobile/build/VNPlayer.ipa
        0  08-24-2026 15:28   Payload/
        0  08-24-2026 15:28   Payload/VNPlayer.app/
    19577  08-24-2026 15:28   Payload/VNPlayer.app/AppIcon60x60@2x.png
        0  08-24-2026 15:28   Payload/VNPlayer.app/Launch Screen.storyboardc/
     2735  08-24-2026 15:28   Payload/VNPlayer.app/Launch Screen.storyboardc/01J-lp-oVM-view-Ze5-6b-2t3.nib
      924  08-24-2026 15:28   Payload/VNPlayer.app/Launch Screen.storyboardc/UIViewController-01J-lp-oVM.nib
      258  08-24-2026 15:28   Payload/VNPlayer.app/Launch Screen.storyboardc/Info.plist
   205320  08-24-2026 15:28   Payload/VNPlayer.app/LaunchImage-foreground.png
  1325199  08-24-2026 15:28   Payload/VNPlayer.app/Assets.car
 27201304  08-24-2026 15:28   Payload/VNPlayer.app/VNPlayer
    29537  08-24-2026 15:28   Payload/VNPlayer.app/AppIcon76x76@2x~ipad.png
     1911  08-24-2026 15:28   Payload/VNPlayer.app/LaunchImage-background.png
        0  08-24-2026 15:28   Payload/VNPlayer.app/Frameworks/
        0  08-24-2026 15:28   Payload/VNPlayer.app/Frameworks/MetalANGLE.framework/
 16014288  08-24-2026 15:28   Payload/VNPlayer.app/Frameworks/MetalANGLE.framework/MetalANGLE
      704  08-24-2026 15:28   Payload/VNPlayer.app/Frameworks/MetalANGLE.framework/Info.plist
     1252  08-24-2026 15:28   Payload/VNPlayer.app/Info.plist
        0  08-24-2026 15:28   Payload/VNPlayer.app/base/
        0  08-24-2026 15:28   Payload/VNPlayer.app/base/game/
      266  08-24-2026 15:28   Payload/VNPlayer.app/base/game/options.rpy
        9  08-24-2026 15:28   Payload/VNPlayer.app/base/game/script_version.txt
      583  08-24-2026 15:28   Payload/VNPlayer.app/base/game/script.rpy
        0  08-24-2026 15:28   Payload/VNPlayer.app/base/game/cache/
    41119  08-24-2026 15:28   Payload/VNPlayer.app/base/game/cache/screens.rpyb
       75  08-24-2026 15:28   Payload/VNPlayer.app/base/game/cache/build_info.json
   447997  08-24-2026 15:28   Payload/VNPlayer.app/base/game/cache/bytecode-312.rpyb
    16299  08-24-2026 15:28   Payload/VNPlayer.app/base/game/cache/py3analysis.rpyb
     1282  08-24-2026 15:28   Payload/VNPlayer.app/base/game/script.rpyc
     1424  08-24-2026 15:28   Payload/VNPlayer.app/base/game/options.rpyc
        0  08-24-2026 15:28   Payload/VNPlayer.app/base/lib/
        0  08-24-2026 15:28   Payload/VNPlayer.app/base/lib/python3.12/
   ... (base/renpy/ and base/lib/python3.12/ contents: ~1300 more entries, Ren'Py's
        own runtime and stdlib, elided here)
```

`base/game/options.rpy` and `base/game/script.rpy` are `shell-project/game/`'s own two
files (confirmed byte-for-byte matching sizes to Task 2's `base/game/` inventory: 266 and
583 bytes respectively) — direct evidence the packaged app contains our project, not a
placeholder.

**Independent re-verification** (not trusting the CI script's own assertions): the
`VNPlayer-ipa` artifact was downloaded from run 32744985444 via `gh run download` and
opened locally with `System.IO.Compression.ZipFile` (.NET), on a machine with no
connection to the CI script that built it:

- **1,424 total zip entries**, of which **1,423** are under `Payload/VNPlayer.app/` (the
  remaining 1 is the bare `Payload/` directory entry itself).
- `Payload/VNPlayer.app/VNPlayer` (the executable) present, **27,201,304 bytes** — exact
  match to the CI log's `unzip -l` figure for the same file.
- `Payload/VNPlayer.app/Info.plist` present and readable as a valid binary plist
  (`bplist00` magic); its bytes contain the literal string
  `io.github.nocritics.vnplayer`, `VNPlayer`, `13.0` (deployment target),
  `arm64`, `iphoneos`/`18.5` (SDK) — confirming the same facts the CI script's own
  `PlistBuddy` readback reported, via a completely independent code path (.NET zip
  reading vs. the script's own `unzip`/`PlistBuddy`).

## Bundle identifier: read back from the built app, not assumed

The override was passed as `PRODUCT_BUNDLE_IDENTIFIER=io.github.nocritics.vnplayer` on
the `xcodebuild` command line. Per the correction sheet, the value recorded here is what
was read back **out of the built app's own `Info.plist`**, not the value passed in:

```
$ /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
    build/VNPlayer.xcarchive/Products/Applications/VNPlayer.app/Info.plist
io.github.nocritics.vnplayer
```

**Bundle identifier actually present in the built app: `io.github.nocritics.vnplayer`.**
It matches the override exactly (the script's own guard, which would print a `WARNING` to
stderr on any mismatch, did not fire). Independently reconfirmed above by reading the
binary plist directly out of the downloaded `.ipa` on a separate machine, outside the CI
script's own trust boundary.

## Files changed (Task 3)

- `scripts/ios/package_ipa.sh` (new) — the archive-and-package script.
- `.github/workflows/ios-build.yml` — added "Package unsigned .ipa" and "Upload .ipa"
  steps after "Upload inventory"; `timeout-minutes` raised from 45 to 90.
- `docs/IOS-BUILD.md` — this section.

## Not determined (Task 3)

- Whether the resulting `.app`/`.ipa` actually launches and renders the visual novel on a
  real device via Sideloadly — that requires a physical iOS device and a free Apple ID,
  neither available in CI; out of scope for this task, which only proves the archive and
  packaging steps.
- Whether `shell/`'s own native layer (out of this task's scope per the plan) is present
  inside the `.app` — Task 4's stated job, not checked here.
- GitHub Actions truncated the "Package unsigned .ipa" step's log output before the final
  `unzip -l` totals line (no footer "N files" line appears in the captured log, for either
  `gh run view --log` or the raw `gh api .../logs` job log) despite the step completing
  successfully (exit 0, job conclusion `success`). This looks like a GitHub Actions log
  buffering/capture limit hit by ~1,940 rapid log lines in one step, not a script defect —
  confirmed by independently downloading and inspecting the artifact itself (above), which
  shows the complete, correct content regardless of what the log capture kept.

# Task 4 — overlay the shell layer and prove it reaches the `.ipa`

Tasks 1–3 proved CI can build *a* Ren'Py app. This task is the first evidence for or
against Milestone A's central claim: that `shell/main.py` and `shell/vnshell/` — proven
over 200 in-process game switches on desktop — are portable and run unchanged on iOS.

`scripts/ios/overlay_shell.sh` runs between "Generate Xcode project" and "Package unsigned
.ipa". It copies `shell/main.py` over the `base/main.py` that `ios_populate` generates, and
copies `shell/vnshell/` into `base/vnshell/`, pruning `__pycache__/` and `*.pyc` after the
copy (BSD `cp` has no `--exclude`; a developer's Mac may hold CPython 3.14 bytecode there,
git-ignored so CI never sees it, and iOS runs CPython 3.12 — shipping mismatched bytecode
would be dead weight at best). `shell/` and `shell/vnshell/` are copied verbatim; neither was
edited.

## Why "a `main.py` exists" is not a check

`ios_populate` (`launcher/game/ios.rpy`) already writes its own `base/main.py` before the
overlay runs, so file existence discriminates nothing. Tracing the exact code path
confirmed what it actually is: `renpy/common/00build.rpy:431` declares
`package("ios", "directory", "ios all", ...)`; `distribute.rpy`'s `scan_and_classify()`
picks up the SDK's own top-level `renpy.py` under the `all` file list, `rename()` renames it
to the executable name, and `ios_populate`'s own code
(`launcher/game/ios.rpy:213-230`) copies whichever `.py` file lands in `base/` into
`main.py`, stripping only the `#!` shebang line. **`base/main.py`, before our overlay, is a
shebang-stripped copy of `vendor/renpy-8.5.3-sdk/renpy.py`.**

That matters because `vendor/renpy-8.5.3-sdk/renpy.py` defines `path_to_renpy_base()`,
`path_to_gamedir()`, `path_to_common()`, and `path_to_saves()` — **the same function names**
`shell/main.py` defines, by design (`shell/main.py` mirrors `renpy.py`'s structure so
Ren'Py's bootstrap can call it the same way). Confirmed directly, not assumed:

```
$ grep -rl "path_to_renpy_base" vendor/
vendor/renpy-8.5.3-sdk/renpy.py
```

Using any of those names as the discriminating marker would have repeated the exact
failure mode that lost three canary designs in Milestone A — a marker also present in the
thing it's supposed to distinguish from. `NoGameDirectory` — the custom exception class
`shell/main.py` raises when `base/game/` is missing — was checked the same way and returned
no hits anywhere under `vendor/`:

```
$ grep -rl "NoGameDirectory" vendor/
$
```

`NoGameDirectory` is the marker both `overlay_shell.sh` and the `.ipa`-level CI guard use.

## The overlay script's assertions

`overlay_shell.sh` fails (non-zero exit, explicit message to stderr) if any of the
following is false, after the copy:

- `base/main.py` exists **and** contains `NoGameDirectory` (i.e. is ours, not Ren'Py's).
- `base/vnshell/` exists and contains all seven modules: `__init__.py`, `harness.py`,
  `lifecycle.py`, `purge.py`, `mailbox.py`, `state.py`, `transports.py`.
- `base/game/` exists and is non-empty.
- `base/renpy/` exists.

Each of these is a real gate, not a log line: every one is a `[ ... ] || { echo ...; exit
1; }` (or equivalent), so a false condition stops the job before packaging ever runs.

*(Revised after review — see "Fix round" below. The list originally checked only five of
the seven modules, omitting `__init__.py` — whose absence breaks `import vnshell` outright
— and `harness.py`.)*

## CI runs (evidence trail)

Run: [32747837073](https://github.com/NoCritics/renpy-mobile/actions/runs/32747837073) —
**GREEN on the first attempt**, all 13 steps including the two new ones ("Overlay shell
layer", "Verify shell layer is in the .ipa"), on branch `milestone-b`.

"Overlay shell layer" step output (verbatim):

```
Overlaying shell layer into /Users/runner/work/renpy-mobile/renpy-mobile/build/xcode/VNPlayer/base
=== overlay result ===
-rw-r--r--  1 runner  staff  2698 Aug 24 15:57 .../base/main.py

.../base/vnshell:
total 104
-rw-r--r--  1 runner  staff    147 Aug 24 15:57 __init__.py
drwxr-xr-x  9 runner  staff    288 Aug 24 15:57 .
drwxr-xr-x  7 runner  staff    224 Aug 24 15:57 ..
-rw-r--r--  1 runner  staff   6260 Aug 24 15:57 harness.py
-rw-r--r--  1 runner  staff   6304 Aug 24 15:57 lifecycle.py
-rw-r--r--  1 runner  staff   4136 Aug 24 15:57 mailbox.py
-rw-r--r--  1 runner  staff  12490 Aug 24 15:57 purge.py
-rw-r--r--  1 runner  staff   1035 Aug 24 15:57 state.py
-rw-r--r--  1 runner  staff   1636 Aug 24 15:57 transports.py
=== explicit assertions (a listing above is not a check) ===
OK: base/main.py is ours (contains NoGameDirectory)
OK: base/vnshell/ contains lifecycle.py, purge.py, mailbox.py, state.py, transports.py
OK: base/game/ exists and is non-empty
OK: base/renpy/ exists
Overlay complete: .../base/main.py and .../base/vnshell/ are ours.
```

`base/main.py` dropped from Task 2's 8,922 bytes (Ren'Py's generated launcher) to 2,698
bytes — the exact size of `shell/main.py` — direct evidence the overlay replaced the file,
not merely touched it.

"Verify shell layer is in the .ipa" step output (verbatim, matched paths the guard printed):

```
=== vnshell/ modules present in build/VNPlayer.ipa ===
    12490  08-24-2026 15:59   Payload/VNPlayer.app/base/vnshell/purge.py
     6304  08-24-2026 15:59   Payload/VNPlayer.app/base/vnshell/lifecycle.py
     4136  08-24-2026 15:59   Payload/VNPlayer.app/base/vnshell/mailbox.py
     1636  08-24-2026 15:59   Payload/VNPlayer.app/base/vnshell/transports.py
     1035  08-24-2026 15:59   Payload/VNPlayer.app/base/vnshell/state.py
=== locating base/main.py inside build/VNPlayer.ipa ===
Found: Payload/VNPlayer.app/base/main.py
OK: Payload/VNPlayer.app/base/main.py contains NoGameDirectory -- this is our main.py
=== shell layer verified in build/VNPlayer.ipa ===
```

*(The output above is from the original run, 32747837073, before the fix round below. At
that time the CI guard's `vnshell` check covered 5 of the 7 files present — `harness.py`
and `__init__.py` were not individually asserted at the `.ipa` level, though both were
asserted to exist in `base/vnshell/` by `overlay_shell.sh` before packaging, and both were
already present in the packaged `.ipa` at that point too — confirmed below. The "Fix round"
section records the corrected guard checking all seven, and quotes its output.)*

## Independent re-verification (not trusting the CI script's own assertions)

The `VNPlayer-ipa` artifact was downloaded from run 32747837073 via `gh run download` and
inspected locally with `unzip`, outside the CI script's own trust boundary:

```
$ unzip -l VNPlayer.ipa | grep -E "base/main.py|vnshell/"
        0  2026-08-24 17:59   Payload/VNPlayer.app/base/vnshell/
     6260  2026-08-24 17:59   Payload/VNPlayer.app/base/vnshell/harness.py
      147  2026-08-24 17:59   Payload/VNPlayer.app/base/vnshell/__init__.py
    12490  2026-08-24 17:59   Payload/VNPlayer.app/base/vnshell/purge.py
     6304  2026-08-24 17:59   Payload/VNPlayer.app/base/vnshell/lifecycle.py
     4136  2026-08-24 17:59   Payload/VNPlayer.app/base/vnshell/mailbox.py
     1636  2026-08-24 17:59   Payload/VNPlayer.app/base/vnshell/transports.py
     1035  2026-08-24 17:59   Payload/VNPlayer.app/base/vnshell/state.py
     2698  2026-08-24 17:59   Payload/VNPlayer.app/base/main.py
```

**All seven `vnshell` modules are present** — `lifecycle.py`, `purge.py`, `mailbox.py`,
`state.py`, `transports.py`, `harness.py`, `__init__.py` — with **no `__pycache__/`
directory anywhere in the archive**:

```
$ unzip -l VNPlayer.ipa | grep -i pycache
(no output)
```

`base/main.py` (2,698 bytes) begins `"""VNPlayer entry point.` and contains
`NoGameDirectory` when extracted and grepped directly — it is `shell/main.py`, not the
8,922-byte file `ios_populate` generates.

## `.ipa` size

Downloaded artifact: **28,019,887 bytes** (≈26.72 MiB), vs. Task 3's **28,006,947 bytes** —
**+12,940 bytes (+0.05%)**. The `Payload/VNPlayer.app/VNPlayer` executable is byte-identical
to Task 3's (27,201,304 bytes both times — expected, since the executable does not embed
`base/main.py` or `base/vnshell/`). The growth is accounted for by the overlay's net content
change: `main.py` shrank by 6,224 bytes (8,922 → 2,698) while `base/vnshell/` added 7 new
files totalling 32,008 uncompressed bytes; the two combine to +25,784 bytes of uncompressed
content, which compresses down to the +12,940 bytes actually observed in the zip. Total zip
entry count: **1,432 files** (unzip's own footer), vs. Task 3's **1,424** — a difference of
8, matching exactly what the overlay added: 6 new `vnshell/*.py` files (`lifecycle`,
`purge`, `mailbox`, `state`, `transports`, `harness`) + `__init__.py` + the `vnshell/`
directory entry itself (`main.py` replaced an existing entry, not a new one).

## Files changed (Task 4)

- `scripts/ios/overlay_shell.sh` (new, later revised in the fix round to assert all seven
  `vnshell` modules) — the overlay script.
- `.github/workflows/ios-build.yml` — added "Overlay shell layer" between "Generate Xcode
  project" and "Inspect generated project"; added "Verify shell layer is in the .ipa"
  between "Package unsigned .ipa" and "Upload .ipa". Fix round added "Assert pre-overlay
  base/main.py is Ren'Py's, not ours" (before the overlay), expanded the `.ipa` guard's
  `vnshell` check to all seven modules, and added the scoped `__pycache__`/`*.pyc` gate.
- `docs/IOS-BUILD.md` — this section, including the fix round.

No new files were added in the fix round; the same two files (`overlay_shell.sh`,
`ios-build.yml`) were revised.

## Fix round (review response)

Code review on the first Task 4 round found two Important gaps, plus authorized one bounded
addition. All three are fixed and re-verified live in CI, not just reasoned about.

**1. The guard covered 5 of 7 `vnshell` modules.** `__init__.py` (missing it breaks `import
vnshell` outright) and `harness.py` were not individually checked, in either
`overlay_shell.sh`'s assertion loop or the `.ipa`-level regex. Both scripts now iterate all
seven: `__init__.py`, `harness.py`, `lifecycle.py`, `purge.py`, `mailbox.py`, `state.py`,
`transports.py`.

**2. The `NoGameDirectory`-absent-from-stock-`main.py` claim was inferred, never observed
live.** The original evidence was a source-code trace of `vendor/renpy-8.5.3-sdk/renpy.py`
— correct, but never checked against the actual `base/main.py` that CI itself generates,
because the overlay ran immediately after generation and nothing captured the pre-overlay
file. Fixed by adding a new step, **"Assert pre-overlay `base/main.py` is Ren'Py's, not
ours"**, immediately after "Generate Xcode project" and before the overlay runs. It greps
the as-generated `base/main.py` for `NoGameDirectory`, logs the file's size, and fails the
build if the marker is present — turning the discrimination claim into a fact re-confirmed
on every build, not a one-time inference. It would also catch the day a future Ren'Py
release starts generating a `main.py` that happens to contain the marker, which would
otherwise silently destroy the guard's ability to discriminate downstream.

**3. (Authorized addition) No regression gate for `__pycache__`/`*.pyc` reaching the
`.ipa`.** Previously confirmed only by a manual one-off check on a downloaded artifact.
Added to the "Verify shell layer is in the .ipa" step, scoped to entries under `vnshell/`
in the archive listing.

### CI runs (fix round)

Three runs, in order:

1. **[32769659714](https://github.com/NoCritics/renpy-mobile/actions/runs/32769659714) —
   RED.** Fixes 1 and 2 above landed clean; the pycache gate (fix 3), as first written,
   checked the *entire* `.ipa` listing for `__pycache__`/`*.pyc` rather than scoping to
   `vnshell/`. It correctly failed — against `Payload/VNPlayer.app/base/lib/python3.12/*.pyc`,
   Ren'Py's own precompiled stdlib, legitimately shipped and unrelated to
   `shell/vnshell/`'s exclusion requirement. This is the gate doing its job: it caught an
   overbroad condition before it merged clean, on the very first CI check of that
   assertion.
2. Fix: scoped the pycache/`.pyc` grep to listing lines containing `vnshell/`.
3. **[32770078436](https://github.com/NoCritics/renpy-mobile/actions/runs/32770078436) —
   GREEN.** All 15 steps (13 from the original round + the new pre-overlay assertion +
   the same "Verify shell layer is in the .ipa" step, now checking all seven modules and
   the scoped pycache gate).

### The pre-overlay assertion, live (closing the inference gap)

"Assert pre-overlay `base/main.py` is Ren'Py's, not ours" step output, run 32770078436,
verbatim:

```
Pre-overlay build/xcode/VNPlayer/base/main.py is 8922 bytes (Ren'Py's own ios_populate output, not yet overlaid).
OK: pre-overlay build/xcode/VNPlayer/base/main.py does not contain NoGameDirectory -- confirmed on THIS build, not inferred from source alone. NoGameDirectory remains a valid marker for 'this is ours, not Ren'Py's'.
```

8,922 bytes matches Task 2's recorded figure for Ren'Py's generated `main.py` exactly. This
is now a fact this build produced, not a source-trace inference about a different Ren'Py
copy.

### "Verify shell layer is in the .ipa", all seven modules, live

Run 32770078436, verbatim (all matched paths the corrected guard printed):

```
=== vnshell/ modules present in build/VNPlayer.ipa ===
      147  08-24-2026 19:47   Payload/VNPlayer.app/base/vnshell/__init__.py
     6260  08-24-2026 19:47   Payload/VNPlayer.app/base/vnshell/harness.py
     6304  08-24-2026 19:47   Payload/VNPlayer.app/base/vnshell/lifecycle.py
    12490  08-24-2026 19:47   Payload/VNPlayer.app/base/vnshell/purge.py
     4136  08-24-2026 19:47   Payload/VNPlayer.app/base/vnshell/mailbox.py
     1035  08-24-2026 19:47   Payload/VNPlayer.app/base/vnshell/state.py
     1636  08-24-2026 19:47   Payload/VNPlayer.app/base/vnshell/transports.py
=== locating base/main.py inside build/VNPlayer.ipa ===
Found: Payload/VNPlayer.app/base/main.py
OK: Payload/VNPlayer.app/base/main.py contains NoGameDirectory -- this is our main.py
=== confirming no __pycache__/*.pyc reached build/VNPlayer.ipa under vnshell/ ===
OK: no __pycache__/*.pyc under vnshell/ anywhere in build/VNPlayer.ipa
=== shell layer verified in build/VNPlayer.ipa ===
```

### `.ipa` size (fix round)

Downloaded artifact from run 32770078436: **28,025,375 bytes**, vs. this task's own earlier
figure of 28,019,887 bytes (run 32747837073) — **+5,488 bytes**. This delta is **not**
attributable to the fix-round changes above: `base/main.py` and every `base/vnshell/*.py`
file are byte-identical between the two downloads (verified directly:
`Payload/VNPlayer.app/base/main.py` is 2,698 bytes both times, and every `vnshell/*.py`
file matches its earlier size exactly), and the fix round touched only CI assertion logic,
not overlay content. Between the two runs, unrelated commits landed on `milestone-b` for
Task 5 (`shell: render proof-of-life diagnostics instead of a bare black screen`, device
log capture) that changed `shell-project/game/` content — accounting for the size and
uncompressed-content growth instead. Entry count held at **1,432 files** both times.

## Not determined (Task 4)

- Whether the app actually boots and renders on a real device — determined by Task 5
  (below): **confirmed working** on a physical iPhone.
- Whether `shell/vnshell/lifecycle.install()` and the rest of the shell's runtime behavior
  (not just its presence on disk) behaves the same on iOS as on the 200-switch desktop
  rig — this task proves the files reach the bundle unchanged; Task 5 is the first evidence
  they also execute correctly there (`vnshell: imported OK`, interaction loop alive).

---

# Task 5 — first device install (CONFIRMED WORKING)

Installed via Sideloadly on a physical iPhone by the project owner, 2026-08-24. Developer
mode enabled, developer certificate trusted. **The app launches and runs our shell layer.**

`TODO(device): model and iOS version not yet recorded — required before this claims
which iOS versions are proven.` The install plan called for capturing both; neither was
supplied by the time this task closed. Nothing in this document should be read as
implying a specific device model or iOS version — only that at least one physical
iPhone, of unrecorded model and OS version, ran this build successfully.

Evidence is a screenshot of the running app (1280x591), kept at
`logs/photo_2026-08-24_21-26-45.jpg`. Everything below is transcribed from that screen —
it is device output, not a build-time inference.

```
VNPlayer shell is running
alive for 7s
Ren'Py 8.5.3.26051504
Python 3.12.8
platform: darwin
basedir: /var/containers/Bundle/Application/436F2A24-EB7D-4517-8C7B-4A2E5B926939/VNPlayer.app/base
logdir:  /var/containers/Bundle/Application/436F2A24-EB7D-4517-8C7B-4A2E5B926939/VNPlayer.app/base
logdir writable: NO (PermissionError)
home: /private/var/mobile/Containers/Data/Application/9894BE3B-E2B7-46B9-8F8D-29CC687A0EB6
Documents exists: True
vnshell: imported OK
```

## What this proves

- **Milestone A's shell layer is portable.** `vnshell` imported on iOS from the same source
  that runs the desktop rig, with no iOS-specific edit. That was the architecture's central
  unproven claim and it is now evidence, not hypothesis.
- **`alive for 7s` means the interaction loop is live**, not a single frame painted before a
  hang. A static screen would have proven only that Ren'Py reached its first redraw.
- The whole no-Mac, no-Developer-Program, no-secrets pipeline produces an artifact that
  actually runs on hardware.

## Measured facts that differ from what was recorded earlier

1. **Python on iOS is 3.12.8**, not the 3.12.7 the desktop SDK ships. Both are 3.12, so
   `create.py`'s `-lpython3.12` rewrite still matches `libpython3.12.a` — but the two
   interpreters are not the same patch release, and anything that pins an exact patch
   version would be wrong.
2. **`sys.platform` is `darwin` on iOS, not `ios`.** Any future iOS detection must NOT use
   `sys.platform`. Ren'Py's own mechanism is `renpy/__init__.py:167`:
   `os.environ.get("RENPY_PLATFORM", "").startswith("ios")` sets `renpy.ios`. Use
   `renpy.ios`.
3. **The two container paths are different UUIDs**, as iOS intends: the read-only Bundle
   container holds the app, and a separate writable Data container holds `~/Documents`.

## Correction: `logdir writable: NO` is expected, and log.txt is not the log

An earlier reading of this project concluded that `path_to_logdir()` returning the basedir
was an iOS portability defect, because the bundle is read-only. The first half is right and
the device confirms it. **The conclusion was wrong.**

`renpy/log.py:79` reads:

```python
if renpy.ios:
    self.file = real_stdout
```

On iOS Ren'Py deliberately never opens `log.txt` at all — every log line goes to **stdout**,
which the renios shell routes to the iOS system log (`prototype/Log.m` wraps `NSLog`).
Repointing `path_to_logdir` at `~/Documents` would therefore have fixed nothing: it would
have changed a path that iOS builds do not use.

**Consequence for diagnostics:** the log already exists and already leaves the process. It is
read with a device-console tool over USB (`idevicesyslog`), not by retrieving a file. Writing
an additional in-app log copy into `~/Documents` remains worthwhile — a reader with no PC to
hand cannot run a console tool — but it is an enhancement, not a repair.

## Still not measured on device

- The ~22 MB-per-switch native memory leak. Spec §14 requires re-measurement using
  `task_info(TASK_VM_INFO).phys_footprint`; nothing here does that. Milestone C.
- Any real visual novel. `shell-project/` is two `.rpy` files; timings and footprint do not
  generalize.
- Touch input, orientation behaviour, and audio: unexercised by this screen.

## Device log capture — findings from the first real capture

`scripts/ios/device_log.sh` streams the device console over USB with `idevicesyslog`
(libimobiledevice for Windows, `jrjr/libimobiledevice-windows` build). First capture:
123,141 lines over 30 seconds, of which 1,515 came from our process.

### Correction: Ren'Py's log IS emitted, but iOS redacts it

An earlier note here said the engine's log "goes to stdout, which the renios shell routes
to the iOS system log", and implied it would therefore be readable. The routing claim is
correct; the readability implication was not.

The capture shows 67 lines of the form:

```
Aug 24 21:44:13.591752 VNPlayer[748] <Notice>: <private>
```

Those are Ren'Py's log lines. `prototype/Log.m` is `NSLog(@"%s", s)`, and iOS's unified
logging **redacts `%s` arguments as `<private>` by default**. The device is hiding the
text, not failing to emit it — a distinction that matters, because the fix is a device
setting, not a code change.

Two ways to read the text, neither yet applied:

1. **Install Apple's logging configuration profile** enabling private-data logging
   (`com.apple.system.logging`, `Enable-Private-Data`). No code change, reversible by
   removing the profile, and applies to any app.
2. **Rewrite `Log.m`'s `%s` to `%{public}s` in the GENERATED project** — permitted under
   the same ruling that lets us override the bundle identifier, since the generated tree
   is our artifact and `vendor/` is untouched. But it would make *everything* Ren'Py logs
   public, including which game is open, so it should not be the default for a reader
   application. Debug configuration only, if at all.

### Kernel-level confirmation that the shell layer imported

```
kernel(Sandbox)[0] <Error>: Sandbox: VNPlayer(791) deny(1) file-write-create
  /private/var/containers/Bundle/Application/.../VNPlayer.app/base/vnshell/__pycache__
```

Python tried to write bytecode next to our modules and the read-only bundle refused it.
This is independent evidence — from the kernel, not from our own diagnostic screen — that
`import vnshell` really executed against the files we overlaid. Harmless: Python proceeds
without caching. It does mean our `.py` sources are recompiled on every launch.

### REAL BUG FOUND — saves cannot be written on iOS

```
Sandbox: VNPlayer(791) deny(1) file-write-create
  .../VNPlayer.app/base/game/saves
```

`shell/main.py`'s `path_to_saves()` falls back to `os.path.join(gamedir, "saves")` when
`STATE.saves_root` is unset. On iOS `gamedir` is inside the read-only bundle, so that
fallback **cannot work** — the sandbox denies it outright.

It did not surface as a visible failure here because the shell project saves nothing. It
would surface the moment a real game tried to autosave or a reader tried to save.

**This must be fixed in Milestone C**: `path_to_saves()` needs a writable base on iOS
(the app's `Documents` or `Library` directory in the Data container, which the device
confirmed exists at `/private/var/mobile/Containers/Data/Application/<uuid>/Documents`).
Recorded here rather than patched now because the shell layer is under a
ships-unchanged constraint for Milestone B, and this is exactly the kind of finding that
constraint exists to surface rather than bury.

Also observed and benign: `deny(1) process-fork` (iOS forbids fork; nothing depends on
it), `deny(1) sysctl-read kern.bootargs`, and the denial of the write probe our own
diagnostic screen deliberately attempts.

### A script bug worth recording, because it is the third of its kind

The first version of the summary step ran `grep ... | head -40 || echo "(none matched)"`.
Under `set -o pipefail`, `head` closing the pipe sends `grep` SIGPIPE, the pipeline
reports failure, and the fallback printed **"(none matched)" over a capture containing
1,515 matching lines**. Fixed by using `grep -m N` instead of a pipe to `head`.

This is the same `grep`/`head`-under-`pipefail` trap raised in the Task 1 and Task 4
reviews. Three occurrences in one milestone: treat any `| head` inside a `pipefail` script
as a defect on sight.

---

# Task 6 — release automation

Two changes to `.github/workflows/ios-build.yml`, plus the README pointers below. No
new script; nothing under `scripts/ios/` changed.

## The trigger gap, found and fixed

The workflow already ran on `push: branches: [main, milestone-b]` and
`workflow_dispatch`, but **not on tag pushes** — `startsWith(github.ref, 'refs/tags/')`
in a release step can never be true if the workflow itself never runs for a tag push.
Fixed by adding `tags: ['v*']` alongside the existing `branches:` list under `push:`.
Both filters are independent per Actions' own ref-type matching (branch pushes match
`branches`, tag pushes match `tags`); this is not new behavior in the workflow, just a
missing trigger.

## Attach the `.ipa` to a GitHub Release on tag pushes

Added a step, gated `if: startsWith(github.ref, 'refs/tags/')`, using
`softprops/action-gh-release@v2` to upload `build/VNPlayer.ipa` to the release matching
the pushed tag. It authenticates with the automatic per-run `GITHUB_TOKEN` that Actions
provisions for every workflow run — not a repository secret anyone configures, so this
works identically on a fork with zero setup. The job's `permissions:` block was set to
`contents: write` (scoped to this job only) because `softprops/action-gh-release`
needs it to create/update a release and attach an asset; every other step in the job
only reads the checkout and needs no elevated permission.

**Not exercised in CI yet.** Per the task's own constraint, no tag has been pushed and
no release published — that is the repository owner's decision, not this task's to
make. The change was verified by parsing the workflow YAML (`yaml.safe_load` — parses
clean) and by re-reading `softprops/action-gh-release@v2`'s documented interface, not
by a live tag-triggered run. Mark this **unverified by a real run**, not confirmed.

## Cache hit: observed, not assumed

Task 1 wired `actions/cache@v4` around `vendor/*.zip` under key `renpy-8.5.3-archives`.
Whether it actually hits was never checked before this task — it is now, from real run
logs across the whole Task 1-5 history (`gh run view <id> --log`):

- **First run ever with this key, 32740201093 (2026-08-24T14:40:56Z):** cache **miss**,
  then saved on completion:
  ```
  Cache not found for input keys: renpy-8.5.3-archives
  ...
  Cache saved with key: renpy-8.5.3-archives
  ```
- **Every subsequent run checked — 32740372920, 32740785207, 32741864714,
  32742226209 — hits the same key:**
  ```
  Cache hit for: renpy-8.5.3-archives
  Cache restored successfully
  Cache restored from key: renpy-8.5.3-archives
  ...
  Cache hit occurred on the primary key renpy-8.5.3-archives, not saving cache.
  ```
  (`Post Cache Ren'Py downloads` correctly skips re-saving on a hit, since the archive
  content is unchanged.) Confirmed across every one of the ~25 non-discovery-workflow
  runs on `milestone-b` through Task 5 that share this key — no run since the first has
  reported a miss.

**Timed from the same logs, "Fetch dependencies" step only** (download+verify+unpack vs.
cache-restore+verify+unpack — both zips, no network download in the cached case):

| Run | Cache | Step start → end | Duration |
|---|---|---|---|
| 32740201093 | miss (downloaded from renpy.org) | 14:40:59.345Z → 14:41:11.878Z | **~12.5s** |
| 32740372920 | hit (restored from cache) | 14:42:52.234Z → 14:42:59.680Z | **~7.4s** |

The gap is real but modest (~5s) because GitHub-hosted runners have very high bandwidth
to renpy.org — the two pinned zips (SDK + renios, ~290 MB combined per the cache's own
"Sent 288435135" byte count) download in a few seconds regardless. The cache mainly
saves a fetch to an external host on every run rather than saving large wall-clock time;
its main value is resilience against renpy.org being briefly unreachable, not speed.

Whole-job duration for the same two runs, from `gh api .../jobs`:
`started_at`/`completed_at` — 32740201093 (miss): 14:40:56Z → 14:41:24Z (28s, this run
predates the Xcode/archive/overlay steps added in later tasks, so it is not comparable
to a full modern run's total time, only to isolate the fetch-step delta above).

## `README.md`

Added: current status (Milestones A and B complete, pipeline proven on hardware), a
link to `https://github.com/NoCritics/renpy-mobile/releases/latest`, and a pointer to
`docs/INSTALL.md`. The existing non-affiliation line was left as the only one — not
duplicated.

## Files changed (Task 6)

- `.github/workflows/ios-build.yml` — added `tags: ['v*']` to the `push` trigger, a
  job-level `permissions: contents: write`, and the tag-gated "Attach to release" step.
- `README.md` — status, release link, `docs/INSTALL.md` pointer.
- `docs/INSTALL.md` (new) — the Sideloadly walkthrough for a non-developer reader.
- `docs/IOS-BUILD.md` — this section.

## Verified live: the workflow still runs green with the new trigger and permissions

Run [32773971562](https://github.com/NoCritics/renpy-mobile/actions/runs/32773971562)
(push to `milestone-b`, not a tag) — **GREEN**, all 18 steps. "Attach to release" shows
as skipped (`-`), not failed or run: exactly the expected behavior for a branch push
under `if: startsWith(github.ref, 'refs/tags/')`. The new job-level
`permissions: contents: write` did not break any other step. Cache hit confirmed again
on this same run: `Cache hit for: renpy-8.5.3-archives`. This run does **not** exercise
the release-attachment step itself — that still requires an actual tag push, which is
the repository owner's call — but it does confirm the workflow file is valid and the
gating condition behaves correctly.

## Not determined (Task 6)

- Whether `softprops/action-gh-release@v2` actually succeeds against a real tag push —
  no tag has been pushed. The repository owner publishing a release is what will
  exercise this for the first time.
- Whether the default `GITHUB_TOKEN` permissions on a fork (which may differ from this
  repository's settings) are sufficient without the explicit `permissions:` block this
  task added — the block was added specifically so this does not depend on a fork
  owner's default settings, but that reasoning has not been tested against an actual
  fork.
- Cache behavior across a GitHub Actions cache eviction (caches over ~10 GB total per
  repo, or unused for 7 days, are evicted) — the archives are ~290 MB combined and the
  milestone's CI activity has been dense enough that eviction was never observed, but
  a long-idle repository would see the first post-idle run miss and re-save, which is
  correct behavior, not a defect.

### The %{public}s patch does NOT make Ren'Py's log readable over idevicesyslog

Recorded as a negative result, because the reasoning that led to it was sound and someone
will otherwise try it again.

After patching `Log.m` to `NSLog(@"%{public}s", s)` and capturing through **both** relay
services from a single launch, the counts from our process were:

- **2 lines decoded**
- **50 lines `<decode: missing data>`**

The two that decoded are the giveaway. One is a kernel sandbox line; the other is SDL's
own:

```
VNPlayer[858] <Notice>: You need UIApplicationSupportsIndirectInputEvents in your Info.plist for mouse support
```

That is an `NSLog` with a **literal format string and no arguments**. Every line that
fails to decode is one carrying a `%s` argument.

So the failure was never iOS redaction — `<private>` was a red herring that happened to
change appearance when the specifier changed. The actual problem is that neither relay
delivers the **argument payload** for a third-party binary's `os_log` entries; it only
has what it needs for messages that carry no arguments. Changing `%s` to `%{public}s`
changes redaction, not deliverability.

**The patch is retained**, because it is not useless everywhere: on a Mac with Console.app
attached, `%{public}s` is exactly what makes the text visible. It simply does nothing for
the USB relay this project depends on. It carries a small privacy cost that is likewise
only realized on a Mac console. Revisit before any wider release.

### What will actually work, and why it is Milestone C's first job

Ren'Py's log and the saves bug have the **same root cause**: both want to write somewhere,
and the only path the shell offers them is inside the read-only app bundle. The device
proved both with sandbox denials in the same capture:

```
deny(1) file-write-create .../VNPlayer.app/base/game/saves
deny(1) file-write-create .../VNPlayer.app/base/vnplayer-write-probe.tmp
```

One change fixes both:

1. Point `path_to_logdir()` and `path_to_saves()` at the app's **Data** container, which
   the device confirmed exists at
   `/private/var/mobile/Containers/Data/Application/<uuid>/Documents`. Detect iOS with
   `renpy.ios`, never `sys.platform` — that reads `darwin`.
2. Add `UIFileSharingEnabled` (and `LSSupportsOpeningDocumentsInPlace`) to the generated
   `Info.plist`, using the same post-generation patch pattern as `enable_public_log.sh`.

Then `log.txt` and the save files are retrievable two ways, neither needing a console
tool: `afcclient` over USB (already present in the libimobiledevice suite), and the
**Files app on the phone**, which matters because the intended reader will not have a PC
attached.

That is a better outcome than the log relay in every respect: it survives across releases,
it does not depend on Apple's logging internals, and it is the same work the app needs
anyway so that saves function at all.

### Incidental finding

`UIApplicationSupportsIndirectInputEvents` is absent from the generated `Info.plist`, and
SDL says so on every launch. It affects mouse and trackpad input, which a touch-only
reader does not need — but it is a one-key addition if a Bluetooth trackpad or Mac
Catalyst ever matters.
