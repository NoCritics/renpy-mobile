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

// MARK: - Passthrough

// Touches outside an actual control must reach the game underneath. A plain UIWindow
// swallows everything; without this the engine receives no input at all.
//
// This lives on the WINDOW, not on a replacement for the hosting controller's view.
// The previous version subclassed UIHostingController and overrode loadView to install a
// plain UIView -- which silently defeated the whole point of UIHostingController. Its
// view is not an ordinary UIView: it is the hosting view that renders the SwiftUI tree.
// Substituting a plain one leaves a correctly-installed, correctly-sized, entirely EMPTY
// window. That is exactly what the device showed: "[vnspike] overlay installed" in the
// log, and nothing on screen.
final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        // A hit that lands on the root view itself is empty space, not a control.
        return hit === rootViewController?.view ? nil : hit
    }
}

// MARK: - Root

// Hosts two things deliberately: the SwiftUI view UNDER TEST, and a pure-UIKit CONTROL
// that involves no SwiftUI at all.
//
// The standing rule from this project's other probes: every probe carries a control that
// must succeed. Without one, "nothing is on screen" cannot distinguish "this window does
// not composite over SDL" from "this window composites fine and the SwiftUI inside it
// rendered nothing" -- and those two have completely different next moves. The green box
// is UIKit-only, so it answers the first question independently of the second.
//
// Reading the result needs no log at all, just the screen:
//   green AND red  -> window composites, SwiftUI hosts. Question answered YES.
//   green ONLY     -> window composites; SwiftUI hosting is the problem.
//   NEITHER        -> the window is not reaching the screen; layering is the problem.
final class SpikeRootViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        // --- the thing under test: SwiftUI, hosted the ordinary way ---
        let host = UIHostingController(rootView: SpikeOverlayView())
        host.view.backgroundColor = .clear
        host.view.isOpaque = false
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)

        // --- the control: no SwiftUI anywhere in this ---
        // Added last so it is on top: if the hosting view ever paints opaque, the control
        // must still be visible, or it is not a control.
        let control = UIView()
        control.backgroundColor = .green
        control.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(control)

        let label = UILabel()
        label.text = "UIKIT"
        label.textColor = .black
        label.font = .boldSystemFont(ofSize: 20)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        control.addSubview(label)

        NSLayoutConstraint.activate([
            // Left of centre, so it cannot be confused with the SwiftUI panel and cannot
            // be hidden behind it.
            control.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            control.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            control.widthAnchor.constraint(equalToConstant: 140),
            control.heightAnchor.constraint(equalToConstant: 140),

            label.centerXAnchor.constraint(equalTo: control.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: control.centerYAnchor),
        ])
    }
}

// MARK: - The SwiftUI view under test

struct SpikeOverlayView: View {
    @State private var posted = 0

    var body: some View {
        // Dead centre, opaque, loud, and deliberately ignoring safe areas.
        //
        // The first version pinned this to the top-right behind a 24pt inset, and the
        // Ren'Py diagnostic text is clipped at the top and edges on this device, so
        // "cropped off screen" was a live hypothesis. Centre removes it: this position
        // survives an unexpected inset, a rotation and a scale mismatch at once.
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
        // edgesIgnoringSafeArea, not ignoresSafeArea: the deployment target is iOS 13.0,
        // taken from renios' own prototype, and ignoresSafeArea is iOS 14+. Everything
        // in this file must stay within the iOS 13 SwiftUI surface unless and until
        // raising that floor becomes a deliberate product decision -- it would drop
        // devices, which is not the spike's call to make.
        .edgesIgnoringSafeArea(.all)
    }
}

// MARK: - Installation

// Held strongly: a UIWindow with no strong reference is released and silently vanishes.
private var spikeOverlayWindow: UIWindow?

@_cdecl("vnspike_install_overlay")
public func vnspike_install_overlay() -> Int32 {
    // Must run on the main thread — UIKit requires it.
    guard Thread.isMainThread else { return -1 }

    if spikeOverlayWindow != nil { return 2 }  // already installed

    // Anchor to the active scene rather than assuming a global keyWindow, which is
    // deprecated and wrong under multi-scene.
    let scene = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive }
        ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

    guard let windowScene = scene else { return -2 }

    let window = PassthroughWindow(windowScene: windowScene)
    window.windowLevel = .normal + 1
    window.backgroundColor = .clear
    window.isOpaque = false
    window.rootViewController = SpikeRootViewController()

    // A window that installs successfully but has no area is indistinguishable, from
    // the outside, from one that never installed: both show nothing. Give that case
    // its own return code so the log can tell them apart.
    if window.frame.isEmpty { return -3 }

    // Deliberately NOT makeKeyAndVisible: taking key status away from SDL's window is a
    // plausible way to break its input handling. If the control box turns out not to
    // render either, this is the first thing to revisit.
    window.isHidden = false

    spikeOverlayWindow = window
    return 1
}

// MARK: - Swift -> Python

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
