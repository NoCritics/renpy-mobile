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

        // Assigning rootViewController does not load its view, and viewDidLoad runs
        // before the view has a window -- so the controller cannot hand this over
        // itself. Force the load, then wire it up here.
        root.loadViewIfNeeded()
        window.contentView = root.hostingView

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
    /// The single place that decides what the window does.
    ///
    /// Three inputs rather than one boolean, because the states are genuinely three:
    /// library up, game running with the overlay closed, and game running with the
    /// overlay open. Collapsing them into "is the library visible" is what produced an
    /// overlay that passed touches through while open — dismissing it by tapping outside
    /// would also have advanced the game's dialogue.
    func applyWindow(passthrough: Bool, showHandle: Bool, makeKey: Bool) {
        guard let window else { return }

        window.passthroughEnabled = passthrough
        (window.rootViewController as? VNPlayerRootViewController)?
            .setHandleVisible(showHandle)

        if makeKey {
            window.makeKey()
        } else {
            // Handing key back to SDL's window explicitly rather than merely resigning:
            // resignKey alone can leave the scene with no key window at all.
            sdlWindow?.makeKey()
        }
    }

    /// SDL's own window — the one below ours on the same scene.
    private var sdlWindow: UIWindow? {
        window?.windowScene?.windows.first { $0 !== window }
    }

    /// The view Ren'Py renders into.
    private var sdlContentView: UIView? {
        sdlWindow?.rootViewController?.view ?? sdlWindow
    }

    private var originalSDLTransform: CATransform3D?

    /// Scales and pans what the engine drew, without telling the engine.
    ///
    /// Applied to SDL's view, never to Ren'Py: games position their UI with hardcoded
    /// pixel geometry, so changing font size clips dialogue out of its own box and breaks
    /// custom screens. Scaling the rendered output cannot break a layout the game never
    /// learns about — at the cost of being a viewport zoom of a rasterised texture, so
    /// small text gets bigger AND softer.
    ///
    /// The original transform is saved on first use rather than assumed to be identity:
    /// SDL may already be transforming its view for orientation, and overwriting that
    /// with identity would be a rotation bug that only appears on some devices.
    func applyMagnification(scale: CGFloat, offset: CGSize) {
        guard let view = sdlContentView else { return }

        if originalSDLTransform == nil {
            originalSDLTransform = view.layer.transform
        }

        guard scale > 1.001 else {
            if let original = originalSDLTransform {
                view.layer.transform = original
            }
            return
        }

        let base = originalSDLTransform ?? CATransform3DIdentity
        var transform = CATransform3DScale(base, scale, scale, 1)
        transform = CATransform3DTranslate(transform, offset.width, offset.height, 0)
        view.layer.transform = transform
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

    /// While the library is up it is opaque and must absorb every touch. While a game is
    /// running, only real controls may take touches and everything else has to fall
    /// through to SDL.
    public var passthroughEnabled = false

    /// The `UIHostingController`'s view. Load-bearing: see below.
    public weak var contentView: UIView?

    override public func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        guard passthroughEnabled else { return hit }

        // Reject the two views that mean "empty space": the root view, and the SwiftUI
        // HOSTING view.
        //
        // The hosting view is the part the first version missed, and it made the whole
        // mechanism inert. It compared only against `rootViewController?.view` -- but
        // that view has the hosting view as a full-size subview, so `super.hitTest`
        // returns the HOSTING view, never the root. The comparison could not match, the
        // window returned a hit for every touch, and a Ren'Py game rendered perfectly
        // underneath while never receiving a single tap. A check that cannot fail again.
        //
        // Anything else that comes back is a real SwiftUI control, because the view tree
        // marks its non-interactive regions with .allowsHitTesting(false).
        if hit === rootViewController?.view { return nil }
        if hit === contentView { return nil }
        return hit
    }
}

/// Hosts the SwiftUI library, and nothing else for now. The M3 overlay becomes a second
/// child of this same controller.
public final class VNPlayerRootViewController: UIViewController {

    private let model: LibraryModel
    private(set) var hostingView: UIView?
    private weak var returnButton: UIButton?

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

        // The window needs this to tell "empty space" from "a control" -- see
        // PassthroughWindow.hitTest.
        (view.window as? PassthroughWindow)?.contentView = host.view
        hostingView = host.view

        buildReturnButton()

        model.presenter = self
    }

    /// The way back to the library, as a real UIKit button rather than a SwiftUI one.
    ///
    /// This is not a style preference, it is the only thing that works. `UIHostingController`'s
    /// view does its own internal hit-testing and returns **itself** for every point --
    /// a SwiftUI `Button` is not a separate `UIView`, it is a region the hosting view
    /// handles internally. So `PassthroughWindow.hitTest` cannot tell "over the button"
    /// from "over empty space" by view identity: both come back as the hosting view.
    /// Rejecting the hosting view to let touches through therefore rejected the button
    /// too, and it rendered perfectly while being completely inert.
    ///
    /// A UIKit button IS a distinct view, so `super.hitTest` returns the button over the
    /// button and the hosting view everywhere else, and identity separates them cleanly.
    ///
    /// The generalisation for M3, which will have several controls: give each interactive
    /// island its own small hosting controller, sized to the control, added as a sibling
    /// above the full-screen backdrop. Then the same identity rule works -- the
    /// full-screen hosting view is the backdrop and is rejected, while each island's
    /// hosting view is a distinct view that is not.
    private func buildReturnButton() {
        let button = UIButton(type: .system)
        button.setImage(
            UIImage(systemName: "chevron.compact.left",
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)),
            for: .normal)
        button.tintColor = UIColor.white.withAlphaComponent(0.75)
        button.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        button.layer.cornerRadius = 10
        button.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(returnToLibraryTapped), for: .touchUpInside)
        button.isHidden = true

        view.addSubview(button)
        NSLayoutConstraint.activate([
            // A tab docked to the right edge rather than a button floating in the
            // corner: narrower, so it covers less of the game, and unmistakably an
            // affordance rather than part of whatever is being played.
            button.widthAnchor.constraint(equalToConstant: 26),
            button.heightAnchor.constraint(equalToConstant: 64),
            button.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            button.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        returnButton = button
    }

    @objc private func returnToLibraryTapped() {
        // Opens the overlay now; quitting is one of the controls inside it. The handle
        // used to quit directly, which meant a single mistap threw the reader out of
        // their game with no confirmation.
        model.openOverlay()
    }

    /// Shown only while a game is running; the library has its own navigation.
    func setHandleVisible(_ visible: Bool) {
        returnButton?.isHidden = !visible
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
