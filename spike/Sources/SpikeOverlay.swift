// THROWAWAY SPIKE CODE — not the eventual design.
//
// Tests whether a SwiftUI window can coexist with SDL's own UIWindow in one process.
// SDL owns the app delegate and its window; the consultation's advice was not to try to
// embed SwiftUI inside SDL's view controller, but to put a second, transparent UIWindow
// on the same UIWindowScene at a higher windowLevel.
//
// Installation is driven natively, from VNSpikeBootstrap.m's +load, which registers for
// UIApplicationDidBecomeActiveNotification and installs on the first activation.
//
// It used to be driven from Python via ctypes. The device disproved that: ctypes.CDLL(None)
// resolves NO symbol in this binary -- verified with a control, since even Py_Initialize,
// which must be present, came back unresolvable. Waiting for the activation notification
// preserves the one property the Python route had for free: the overlay is created after
// SDL's window exists rather than racing it.

import UIKit
import SwiftUI

// Touches outside an actual control must reach the game underneath. A plain UIWindow
// swallows everything; without this the engine receives no input at all.
final class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

final class PassthroughHostingController<Content: View>: UIHostingController<Content> {
    override func loadView() {
        view = PassthroughView()
        view.backgroundColor = .clear
    }
}

struct SpikeOverlayView: View {
    @State private var posted = 0

    var body: some View {
        // Dead centre, opaque, loud, and deliberately ignoring safe areas.
        //
        // The previous version pinned this to the top-right behind a 24pt inset and the
        // owner could not see it at all. That is NOT by itself evidence the overlay
        // failed to install: the Ren'Py diagnostic text is also clipped at the top and
        // edges on this device, so whatever crops the engine's output would crop a
        // corner-anchored button too. Centre is the one position that survives an
        // unexpected inset, a rotation, and a scale mismatch at the same time.
        ZStack {
            VStack(spacing: 16) {
                Text("SWIFT OVERLAY")
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundColor(.white)

                Button("SEND TO PYTHON") {
                    // No native bridge: append a JSON line to a file in Documents,
                    // which Python's existing FileTransport (Milestone A, already
                    // tested) drains. Needs no symbols, headers, or linkage.
                    if spikeWriteCommand(["command": "hello", "n": posted + 1]) {
                        posted += 1
                    }
                }
                .font(.system(size: 24, weight: .bold))
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(12)

                Text("posted: \(posted)")
                    .font(.system(size: 22))
                    .foregroundColor(.white)
            }
            .padding(32)
            // Fully opaque, and a colour nothing in the shell project uses. If any part
            // of this reaches the screen it is unmistakable, and it cannot be confused
            // with a Ren'Py frame the way a translucent black panel could be.
            .background(Color.red)
            .cornerRadius(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}


// Held strongly: a UIWindow with no strong reference is released and silently vanishes.
private var spikeOverlayWindow: UIWindow?

@_cdecl("vnspike_install_overlay")
public func vnspike_install_overlay() -> Int32 {
    // Must run on the main thread — UIKit requires it, and Python calls this from
    // Ren'Py's own loop, which is the main thread.
    guard Thread.isMainThread else { return -1 }

    if spikeOverlayWindow != nil { return 2 }  // already installed

    // Anchor to the active scene rather than assuming a global keyWindow, which is
    // deprecated and wrong under multi-scene.
    let scene = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive }
        ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

    guard let windowScene = scene else { return -2 }

    let window = UIWindow(windowScene: windowScene)
    window.windowLevel = .normal + 1
    window.backgroundColor = .clear
    window.isOpaque = false

    let host = PassthroughHostingController(rootView: SpikeOverlayView())
    host.view.backgroundColor = .clear
    window.rootViewController = host

    // A window that installs successfully but has no area is indistinguishable, from
    // the outside, from one that never installed: both show nothing. Give that case
    // its own return code so the log can tell them apart.
    if window.frame.isEmpty { return -3 }

    // Deliberately NOT makeKeyAndVisible: taking key status away from SDL's window is a
    // plausible way to break its input handling.
    window.isHidden = false

    spikeOverlayWindow = window
    return 1
}



// Writes one newline-delimited JSON command into the app's Documents directory, where
// Python's FileTransport is polling. Returns false rather than throwing, because a
// failure here should degrade the overlay, not crash the app.
func spikeWriteCommand(_ payload: [String: Any]) -> Bool {
    guard let docs = FileManager.default.urls(for: .documentDirectory,
                                              in: .userDomainMask).first else {
        return false
    }
    let url = docs.appendingPathComponent("vnplayer-commands.jsonl")

    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          let line = String(data: data, encoding: .utf8) else {
        return false
    }
    // A newline byte, appended rather than written as an escape.
    var blob = Data(line.utf8)
    blob.append(0x0A)

    // Append if it exists, create if not. Python consumes the file on read, so it
    // routinely will not exist.
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(blob)
        return true
    }
    return (try? blob.write(to: url)) != nil
}
