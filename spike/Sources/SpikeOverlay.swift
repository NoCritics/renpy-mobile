// THROWAWAY SPIKE CODE — not the eventual design.
//
// Tests whether a SwiftUI window can coexist with SDL's own UIWindow in one process.
// SDL owns the app delegate and its window; the consultation's advice was not to try to
// embed SwiftUI inside SDL's view controller, but to put a second, transparent UIWindow
// on the same UIWindowScene at a higher windowLevel.
//
// Installation is driven from PYTHON via ctypes rather than from a C constructor, which
// kills two birds: it proves the ctypes path works, and it guarantees the overlay is
// created after SDL's window exists rather than racing it.

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
        VStack {
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    Text("Swift overlay")
                        .font(.caption).bold()
                        .foregroundColor(.white)

                    Button("send to Python") {
                        // No native bridge: append a JSON line to a file in Documents,
                        // which Python's existing FileTransport (Milestone A, already
                        // tested) drains. Needs no symbols, headers, or linkage.
                        if spikeWriteCommand(["command": "hello", "n": posted + 1]) {
                            posted += 1
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.blue.opacity(0.85))
                    .foregroundColor(.white)
                    .cornerRadius(8)

                    Text("posted: \(posted)")
                        .font(.caption)
                        .foregroundColor(.white)
                }
                .padding(12)
                .background(Color.black.opacity(0.55))
                .cornerRadius(12)
                .padding(.trailing, 24)
                .padding(.top, 24)
            }
            Spacer()
        }
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
