# Spike findings — Swift in a generated project, C mailbox, SwiftUI over SDL

THROWAWAY probe. Output is an answer, not code to keep.

## Answered: Swift CAN be a member of the target

Approach that worked: keep Ren'Py's `ios_create`/`ios_populate` (they produce `base/`
correctly and reimplementing them would be madness), then **delete the generated
`.xcodeproj` and regenerate it with XcodeGen** from a declarative `spike/project.yml`.

- `brew install xcodegen` on `macos-15`: works, no version pinning needed so far.
- The generated project builds, links all 29 static libraries, embeds
  MetalANGLE.xcframework, and archives unsigned. `.ipa` produced: 29 MB.
- Swift compiled: `SwiftCompile normal arm64 Compiling SpikeOverlay.swift`, targeting
  `arm64-apple-ios13.0`, with our bridging header imported.
- The shell layer still reaches the bundle: all 7 `vnshell` modules present.
- Only one build error across the whole exercise, and it was ordinary Swift API
  availability (`.caption2` needs iOS 14, target is 13). No pbxproj surgery, no UUID
  arithmetic, no linker archaeology.

**This retires the question that blocked M2.** The eventual design can assume Swift is
buildable in CI.

## NOT answered by the build: whether ctypes can reach the C bridge

An earlier version of this file recorded, as an empirical finding, that the built binary
contained the Swift `@_cdecl` symbol and none of the four C bridge symbols — and
concluded that `-dead_strip` had removed them.

**That conclusion was wrong, and the instrument that produced it was invalid.** It was a
string-grep over the Mach-O. Validating it against symbols that MUST be present:

```
FOUND   Py_Initialize
MISSING PyRun_SimpleString    <- must exist
MISSING SDL_CreateWindow      <- must exist
MISSING launcher_main         <- main.c calls it directly
FOUND   main
```

The binary is stripped, so a grep cannot distinguish "never exported" from "stripped like
everything else". The negative result said nothing.

`-Wl,-export_dynamic` was added to `OTHER_LDFLAGS` on the strength of the bad finding. It
is retained — it is harmless and plausibly necessary — but **it has not been shown to be
either necessary or sufficient.** Do not record it as a fix until the device says so.

The real test is on hardware: the diagnostic screen calls
`ctypes.CDLL(None).vnbridge_ping()` and prints either the returned constant or the actual
exception. That is ground truth; everything above it is proxy.

## Still open until a device runs it

1. Can Python reach the C symbols via `ctypes.CDLL(None)`?
2. Does a second `UIWindow` at `.normal + 1` coexist with SDL's, or does one blank the
   other?
3. Does touch pass through the transparent overlay to the game?
4. Does a command posted from Swift arrive in Python's periodic callback?
