import UIKit

/// The always-visible control strip, docked to the right edge while a game runs.
///
/// **UIKit, not SwiftUI, and that is forced rather than chosen.** The strip is on screen
/// permanently, so touches must pass through everywhere around it, permanently. That is
/// precisely the case `UIHostingController` cannot serve: its view answers every hit test
/// itself, so a passthrough window cannot tell "on an icon" from "on the game" by view
/// identity. Each button therefore has to be a real `UIView` — which is what a `UIButton`
/// is, and what a SwiftUI `Button` is not.
///
/// The M2 corner button proved this works; the M2 SwiftUI button proved the alternative
/// does not, by rendering perfectly while being completely inert.
///
/// It dims rather than hides. A control that disappears has to be summoned, and a summon
/// gesture on a passthrough window is its own problem (M3 spec §4.1); a control that fades
/// to a quarter opacity stops competing with the art without ever becoming a puzzle.
final class OverlayControlStrip: UIView {

    struct Item {
        let id: String
        let symbol: String
        let accessibility: String
        /// Draw a hairline above this icon. Nine icons in one unbroken column read as a
        /// list to scan through; grouped, they read as a thing to use. The four groups are
        /// reading (roll back, skip), the game's own pages (save, load, settings), leaving
        /// this screen (magnify, library), and the one-tap slot (quick save, quick load).
        let startsGroup: Bool
        let action: () -> Void

        init(id: String,
             symbol: String,
             accessibility: String,
             startsGroup: Bool = false,
             action: @escaping () -> Void) {
            self.id = id
            self.symbol = symbol
            self.accessibility = accessibility
            self.startsGroup = startsGroup
            self.action = action
        }
    }

    private let stack = UIStackView()
    private var buttons: [String: UIButton] = [:]
    private var actions: [String: () -> Void] = [:]
    private var dimTimer: Timer?
    private weak var toast: UILabel?

    /// How long the strip stays at full opacity after being used.
    private let dimAfter: TimeInterval = 4
    private let dimmedAlpha: CGFloat = 0.28

    init(items: [Item]) {
        super.init(frame: .zero)
        build(items: items)
        scheduleDim()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Building

    private func build(items: [Item]) {
        translatesAutoresizingMaskIntoConstraints = false

        let backdrop = UIView()
        backdrop.backgroundColor = UIColor.black.withAlphaComponent(0.42)
        backdrop.layer.cornerRadius = 18
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        stack.axis = .vertical
        stack.spacing = 2
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for item in items {
            if item.startsGroup, !stack.arrangedSubviews.isEmpty {
                stack.addArrangedSubview(makeDivider())
            }

            let button = UIButton(type: .system)
            let image = UIImage(systemName: item.symbol,
                                withConfiguration: UIImage.SymbolConfiguration(
                                    pointSize: 16, weight: .medium))

            if let image {
                button.setImage(image, for: .normal)
            } else {
                // A symbol name that does not exist on this iOS version returns nil, and
                // setImage(nil:) leaves a button that is fully tappable and completely
                // invisible -- the reader sees a gap where a control is. This project has
                // shipped four separate versions of "renders as nothing, reports nothing";
                // it does not need a fifth. Show the label instead and say so in the log.
                button.setTitle(String(item.accessibility.prefix(2)), for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 11, weight: .semibold)
                NSLog("[vnspike] no SF Symbol named \(item.symbol) for \(item.id)")
            }

            button.tintColor = .white
            button.accessibilityLabel = item.accessibility
            button.translatesAutoresizingMaskIntoConstraints = false
            button.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)
            button.accessibilityIdentifier = item.id

            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 40),
                button.heightAnchor.constraint(equalToConstant: 38),
            ])

            buttons[item.id] = button
            actions[item.id] = item.action
            stack.addArrangedSubview(button)
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),

            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        sendSubviewToBack(backdrop)
    }

    /// A hairline between groups. Not a UIStackView separator -- there is no such thing --
    /// so it is a plain view with a height constraint, made non-interactive because a
    /// passthrough window must never hand a touch to decoration.
    private func makeDivider() -> UIView {
        let holder = UIView()
        holder.isUserInteractionEnabled = false
        holder.translatesAutoresizingMaskIntoConstraints = false

        let line = UIView()
        line.backgroundColor = UIColor.white.withAlphaComponent(0.22)
        line.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(line)

        NSLayoutConstraint.activate([
            holder.heightAnchor.constraint(equalToConstant: 6),
            holder.widthAnchor.constraint(equalToConstant: 40),
            line.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            line.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            line.widthAnchor.constraint(equalToConstant: 22),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])

        return holder
    }

    @objc private func tapped(_ sender: UIButton) {
        wake()
        guard let id = sender.accessibilityIdentifier else { return }
        actions[id]?()
    }

    // MARK: - State

    /// Enable or disable one control.
    ///
    /// Disabled means the engine has said it will not accept it — see the `engineState`
    /// event. Dimmed rather than removed: a control that vanishes teaches nothing, and one
    /// that is present but silently refuses teaches the reader it is unreliable.
    func setEnabled(_ enabled: Bool, for id: String) {
        guard let button = buttons[id] else { return }
        button.isEnabled = enabled
        button.alpha = enabled ? 1 : 0.35
    }

    func setSymbol(_ symbol: String, for id: String) {
        buttons[id]?.setImage(
            UIImage(systemName: symbol,
                    withConfiguration: UIImage.SymbolConfiguration(
                        pointSize: 16, weight: .medium)),
            for: .normal)
    }

    // MARK: - Dimming

    /// Back to full opacity, and the countdown restarts.
    func wake() {
        dimTimer?.invalidate()
        UIView.animate(withDuration: 0.15) { self.alpha = 1 }
        scheduleDim()
    }

    private func scheduleDim() {
        dimTimer?.invalidate()
        dimTimer = Timer.scheduledTimer(withTimeInterval: dimAfter, repeats: false) { [weak self] _ in
            guard let self else { return }
            UIView.animate(withDuration: 0.6) { self.alpha = self.dimmedAlpha }
        }
    }

    // MARK: - Messages

    /// A sentence from the engine, shown beside the strip and then faded.
    ///
    /// The engine's refusals are written as sentences on purpose ("there is nothing to
    /// roll back to"), so this prints them verbatim rather than translating them into an
    /// error. A control that does nothing and says nothing is the failure this avoids.
    func showMessage(_ text: String, in parent: UIView) {
        toast?.removeFromSuperview()

        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: 13)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        label.textAlignment = .center
        label.layer.cornerRadius = 10
        label.layer.masksToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false

        // Padding, without a container: a UILabel has no inset, and a bare rounded
        // rectangle with text touching its edges looks like a mistake.
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        parent.addSubview(label)

        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: topAnchor, constant: -10),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
            label.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
        ])

        toast = label
        wake()

        label.alpha = 0
        UIView.animate(withDuration: 0.2) { label.alpha = 1 }

        // Long enough to read a sentence, short enough not to sit over the art.
        Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak label] _ in
            UIView.animate(withDuration: 0.4, animations: { label?.alpha = 0 }) { _ in
                label?.removeFromSuperview()
            }
        }
    }

    func clearMessage() {
        toast?.removeFromSuperview()
        toast = nil
    }

    deinit {
        dimTimer?.invalidate()
    }
}
