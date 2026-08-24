# iOS build notes

Recorded from real GitHub Actions runs on `macos-15`, triggered by
`.github/workflows/ios-build.yml` (job `discover`) on branch `milestone-b`. This is a
discovery-only workflow: it fetches the pinned Ren'Py 8.5.3 SDK and `renios` package and
inventories what `renios` actually contains, so Tasks 2-4 of the Milestone B plan can be
written against real facts instead of assumptions. Nobody on this project had opened
`renpy-8.5.3-renios.zip` before this task.

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

From `Inventory renios` (run 32740201093 and 32740372920, identical):

```
$ ls -la vendor/renios
buildlib/
hash.txt
prototype/
```

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
- `hash.txt` exists at the top level (64 bytes) — not opened; presumed a build hash/version
  stamp, **not determined**.
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
