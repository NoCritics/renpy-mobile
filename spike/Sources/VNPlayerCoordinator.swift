import UIKit
import SwiftUI

/// Owns the one window we put above SDL, and the state machine that moves between the
/// library and a running game.
///
/// **One window, not two.** The parent spec called for a library window at `.normal + 2`
/// above an overlay window at `.normal + 1`. Both consultation reviewers argued against
/// it and the deciding reason is modal presentation: `UIDocumentPickerViewController` has
/// to come up from the window that owns the interaction, and a window that never takes
/// key status from SDL is where sheets come up blank or refuse to dismiss. One window
/// that takes key while the library is showing and gives it back afterwards is fewer
/// moving parts and removes the multi-window orientation problem outright.
///
/// **SDL's CADisplayLink is never paused.** The parent spec said to pause it while the
/// library is up, so it stops presenting into a stale MetalANGLE context. Doing that
/// would deadlock the launch: SDL drives Ren'Py's frame execution from that callback, and
/// the command spool is drained from `config.periodic_callbacks`, which runs per frame.
/// Pause it and the command we just wrote is never read -- the app hangs with the library
/// up and no error at all. The engine idles cheaply behind an opaque library instead.
@MainActor
public final class VNPlayerCoordinator {

    public static let shared = VNPlayerCoordinator()

    private var window: PassthroughWindow?
    private let model = LibraryModel()

    private init() {}

    // MARK: - Installation

    /// Called from the ObjC bootstrap on first activation, after SDL's window exists.
    /// Returns a code the bootstrap turns into an argument-free log line.
    @discardableResult
    public func install() -> Int32 {
        guard Thread.isMainThread else { return -1 }
        if window != nil { return 2 }

        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

        guard let windowScene = scene else { return -2 }

        let window = PassthroughWindow(windowScene: windowScene)
        window.windowLevel = .normal + 1
        window.backgroundColor = .clear
        window.isOpaque = false

        let root = VNPlayerRootViewController(model: model)
        window.rootViewController = root

        if window.frame.isEmpty { return -3 }

        window.isHidden = false
        self.window = window

        model.attach(coordinator: self)
        model.start()

        return 1
    }

    // MARK: - Key status

    /// The library needs key status so the document picker and alerts behave; the game
    /// needs SDL to have it back, because SDL reads input from the key window.
    func setLibraryVisible(_ visible: Bool) {
        guard let window else { return }

        if visible {
            window.makeKey()
        } else {
            // Handing key back to SDL's window explicitly rather than merely resigning:
            // resignKey alone can leave the scene with no key window at all.
            window.windowScene?.windows.first { $0 !== window }?.makeKey()
        }
    }
}

/// Touches outside an actual control must reach the game underneath.
///
/// This lives on the WINDOW rather than on a replacement for the hosting controller's
/// view. An earlier version subclassed `UIHostingController` and overrode `loadView` to
/// install a plain `UIView`, which silently defeated the point of `UIHostingController`:
/// its view is the hosting view that renders the SwiftUI tree, so substituting a plain
/// one left a correctly-installed, correctly-sized, entirely empty window. On device that
/// presented as "the overlay does not work" while the log said it had installed fine.
public final class PassthroughWindow: UIWindow {
    override public func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        return hit === rootViewController?.view ? nil : hit
    }
}

/// Hosts the SwiftUI library, and nothing else for now. The M3 overlay becomes a second
/// child of this same controller.
public final class VNPlayerRootViewController: UIViewController {

    private let model: LibraryModel

    init(model: LibraryModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        let host = UIHostingController(rootView: LibraryView(model: model))
        host.view.backgroundColor = .clear
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

        model.presenter = self
    }

    /// Must agree with SDL's mask or iOS raises UIApplicationInvalidInterfaceOrientation
    /// on rotation. The app is landscape-only for now, so both are landscape.
    public override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .landscape
    }
}


// MARK: - The C entry point the ObjC bootstrap calls

/// Installs the window. Called from VNPlayerBootstrap.m's +load observer, which fires on
/// the first UIApplicationDidBecomeActiveNotification -- i.e. after SDL's window exists,
/// rather than racing it.
@_cdecl("vnplayer_install_window")
public func vnplayer_install_window() -> Int32 {
    guard Thread.isMainThread else { return -1 }
    return MainActor.assumeIsolated { VNPlayerCoordinator.shared.install() }
}
