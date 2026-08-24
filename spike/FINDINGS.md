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

## ANSWERED on device: `ctypes.CDLL(None)` is NOT a viable bridge seam on iOS

Two device runs settled it. The second carried a control, which is the only reason the
conclusion is trustworthy.

Run 1 (`vnbridge_ping` only):

```
bridge ping: FAILED (AttributeError: dlsym(RTLD_DEFAULT, vnbridge_ping): symbol not found)
```

Tempting reading: "our C symbols were stripped; use Swift `@_cdecl`, whose symbol we saw
survive." Run 2 tested that reading against a control that must succeed:

```
control Py_Initialize:      AttributeError    <- must exist; Python is running
swift @_cdecl vnspike_ping: AttributeError
plain C vnbridge_ping:      AttributeError
```

**`ctypes.CDLL(None)` cannot resolve ANY symbol in this binary**, including libpython's
own. The seam does not work here at all — the C-versus-Swift distinction was never the
variable, and `-Wl,-export_dynamic` was never relevant.

Both models recommended this approach in the architecture consultation, and it does not
survive contact with the device. Recording that plainly: it is a good idea that is wrong
for this platform, not a mistake in their reasoning.

### The next candidate, untested

Register the bridge as a **builtin Python extension module** via
`PyImport_AppendInittab("vnbridge", PyInit_vnbridge)` **before** `Py_Initialize` runs.
This is the textbook way to expose native code to an embedded interpreter and does not
depend on dynamic symbol lookup at all.

It looks feasible here specifically because **`main.c` is ours to modify** — it lives in
the generated project (our artifact), and currently reads:

```c
int main(int argc, char **argv) {
    return SDL_UIKitRunApp(argc, argv, launcher_main);
}
```

`launcher_main` (inside prebuilt `librenpython.a`) is what calls `Py_Initialize`, so
appending to the inittab before handing control over should be enough. Untested.

## Still open, all blocked behind the bridge

1. Does a second `UIWindow` at `.normal + 1` coexist with SDL's, or does one blank the
   other?
2. Does touch pass through the transparent overlay to the game?
3. Does a command posted from Swift arrive in Python's periodic callback?

The overlay is installed from Python, so none of these have been exercised. They are
untested, not failed.

## The methodological lesson, which cost two device cycles

The first negative result came from a string-grep over a stripped Mach-O; validating that
instrument against known-present symbols showed it measured nothing. The second came from
a device probe **with a control**, and the control is what revealed that the real answer
was broader than the hypothesis under test.

Every probe in this project should carry a control that must succeed. Two conclusions in
a row would have been wrong without one.
