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

---

# START HERE after compaction

Branch `spike/swift-bridge`, pushed. Last build: run 32789146023 (commit `b2f0a98`). `main` is untouched at
the Milestone B merge; nothing here has been merged.

## Round 2 is built and pushed — what it discriminates

Commit `b2f0a98` did both of the steps this section used to describe. The button is now
dead centre, large, fully opaque, on a colour the shell project never uses, ignoring safe
areas. The install result is now one argument-free literal per outcome, plus a new `-3`
for a window that installs with an empty frame.

**The predictions, stated before the device run so they cannot be rationalised after it.**
Read the log for the `[vnspike] overlay ...` line and the screen for the red panel:

| Log line | Red panel | What it means | Next move |
|---|---|---|---|
| `overlay installed` | **visible** | SwiftUI and SDL coexist. The spike's central question is answered YES. | Tap it; confirm `from Swift: N received` climbs. That closes the loop end to end. |
| `overlay installed` | **not visible** | The window installs with a real frame but never reaches the screen. Coexistence is the problem, not placement. | Raise `windowLevel` to `.alert + 1`; if that fails, host the SwiftUI view inside SDL's own view controller instead of a second window. |
| `overlay FAILED zero-size window` | not visible | Installed against a scene with no bounds — a timing problem, not a layering one. | Install on the scene's first layout pass rather than on activation. |
| `overlay FAILED no window scene` | not visible | `didBecomeActive` fires before SDL's scene exists. | Retry on the next runloop turn, or observe scene connection instead. |
| `overlay FAILED not main thread` | not visible | The notification block is not on the main queue, contradicting `[NSOperationQueue mainQueue]`. | Would be genuinely surprising; investigate before assuming anything else. |
| no `[vnspike] overlay` line at all | — | The notification never fired, or `+load` did not register. | Check `bootstrap registered` still decodes; if it does, the observer is the suspect. |

The point of the table is that **every outcome now names its own next move.** The previous
round had two outcomes that looked identical from outside the device, which is why it
produced no information.

`windowLevel` was deliberately left at `.normal + 1` this round. Changing placement and
layering together would make a visible button unattributable — and if it stays invisible,
the table above already says layering is the next lever to pull.

## iOS 13.0 is the API floor

`spike/project.yml` sets `deploymentTarget: iOS "13.0"`, read out of renios' own prototype
rather than chosen. Anything newer fails the build, not the device: `.ignoresSafeArea()`
(iOS 14+) cost a full CI round-trip before `.edgesIgnoringSafeArea(.all)` replaced it.
There is no local Swift toolchain on the authoring machine, so CI is the only compiler --
prefer the older spelling when SwiftUI offers both.

Raising the floor is a product decision (it drops devices), not a spike one.

## Device logging constraint (hard-won, applies to all of Milestone C)

Over `idevicesyslog`, **only argument-free `NSLog` format strings are readable.** Anything
with `%d`/`%s`/`%@` renders as `<decode: missing data>` because neither relay delivers the
argument payload for a third-party binary. Evidence: `[vnspike] bootstrap registered`
decoded perfectly; `install_overlay rc=%d` did not; SDL's own argument-free
`UIApplicationSupportsIndirectInputEvents` message decoded every time.

Instrument accordingly: distinct literal strings per case, never formatted values.

## What is settled

| Question | Answer |
|---|---|
| Can Swift be built into the generated project? | **YES** — XcodeGen owns the `.xcodeproj`; Ren'Py still produces `base/` |
| Does it link the renios prebuilts, embed MetalANGLE, archive unsigned? | **YES** |
| Does the shell layer survive? | **YES** — all 7 `vnshell` modules |
| Can Python reach C via `ctypes.CDLL(None)`? | **NO** — control-verified: even `Py_Initialize` is unresolvable |
| Can we build a C extension module instead? | **NO** — no `Python.h` and no `pyconfig.h` for the prebuilt `libpython3.12.a` |
| Can Python drive a file mailbox? | **YES** — `mailbox control: OK (wrote 1, read 1)` on device, via Milestone A's own `FileTransport` |
| Does the ObjC `+load` bootstrap run? | **YES** — `[vnspike] bootstrap registered` |
| Does the SwiftUI overlay appear over SDL? | **UNKNOWN** — button not visible, but so is some Ren'Py text; see step 1 |
| Does a Swift-written command reach Python? | **UNTESTED** — blocked on the button being tappable |

## The methodological thread

Every wrong turn tonight was an instrument that could not fail, or could not detect what it
claimed to — on top of the five review rounds in Milestone B that each closed a check with
the same defect (a warn-not-fail bundle-ID gate, an existence-not-version Python guard, a
5-of-7 module gate, an undemonstrated negative case, a vacuous emptiness test):

1. String-grep over a stripped Mach-O "proved" C symbols were stripped. Control test
   (`SDL_CreateWindow`, `launcher_main` also "missing") showed it measured nothing.
2. First device probe suggested "C fails, Swift `@_cdecl` works". Adding `Py_Initialize`
   as a must-succeed control showed the seam fails wholesale.
3. `build_spike.sh` copied `*.h *.c *.swift` and silently skipped `*.m`, so the overlay
   bootstrap was never compiled — presenting as "SwiftUI does not work over SDL". The
   guard missed it because it named two files individually instead of iterating the
   directory.

**Standing rule for Milestone C: every probe carries a control that must succeed, and
every guard iterates its subjects rather than naming them.**

## Do not re-derive

- `-Wl,-export_dynamic` was added and then removed. It was never relevant.
- Both consulted models (Codex, Gemini) recommended the `ctypes` bridge. It does not work
  on this platform. That is not a flaw in their reasoning — it is why the spike ran.
- `xcodeprojer.py` pbxproj injection was rejected by both models and never attempted.
