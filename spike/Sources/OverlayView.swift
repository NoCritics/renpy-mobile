import SwiftUI

/// The in-game overlay: what the window shows while a game is running.
///
/// **This is plain SwiftUI, with no per-control hosting views, and that is safe here for
/// one specific reason:** while the overlay is open the window ABSORBS every touch, so
/// nothing needs to escape past the hosting view. The hit-testing constraint that broke
/// M2's button only bites when some touches must reach the game and others must not — and
/// in the one state where that is true (`.closed`), the only interactive thing is a real
/// UIKit tab owned by the view controller.
///
/// If a future state ever needs to be both open and passthrough, this stops being safe.
struct OverlayView: View {

    @ObservedObject var model: LibraryModel

    var body: some View {
        switch model.overlay {
        case .closed:
            // The handle is UIKit and lives above this. Nothing here may take a touch.
            Color.clear
                .allowsHitTesting(false)
                .ignoresSafeArea()

        case .open:
            controls

        case .magnified:
            magnifier
        }
    }

    // MARK: - Controls

    private var controls: some View {
        ZStack(alignment: .trailing) {
            // Absorbs, and dismisses. It must absorb: a dismiss tap that also reached the
            // game would advance the dialogue the reader was in the middle of.
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { model.closeOverlay() }

            VStack(alignment: .leading, spacing: 0) {
                if model.showOverlayHint {
                    hint
                }

                if let message = model.overlayMessage {
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 10)
                        .frame(maxWidth: 240, alignment: .leading)
                }

                control("Roll back", "arrow.uturn.backward",
                        enabled: model.engine.canRollback) { model.rollback() }

                control("Quick save", "square.and.arrow.down",
                        enabled: model.engine.canSave) { model.quickSave() }

                control("Quick load", "square.and.arrow.up") { model.quickLoad() }

                control(model.engine.isSkipping ? "Stop skipping" : "Skip",
                        model.engine.isSkipping ? "forward.fill" : "forward") {
                    model.toggleSkip()
                }

                control("Magnify", "plus.magnifyingglass") { model.enterMagnifier() }

                Divider().background(Color.white.opacity(0.2)).padding(.vertical, 8)

                control("Back to library", "books.vertical") { model.returnToLibrary() }

                control("Close", "xmark") { model.closeOverlay() }
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(white: 0.11))
            )
            .padding(.trailing, 14)
        }
    }

    /// Shown once per install, on the first game. An edge tab nobody mentions is an edge
    /// tab nobody finds, and the reader this is built for will not go looking.
    private var hint: some View {
        Text("Tap the tab on the right edge any time to reopen this.")
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(0.6))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 240, alignment: .leading)
            .padding(.bottom, 12)
    }

    private func control(
        _ title: String,
        _ symbol: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 15))
                Spacer(minLength: 0)
            }
            .foregroundColor(enabled ? .white : .white.opacity(0.3))
            .frame(width: 190, alignment: .leading)
            .padding(.vertical, 9)
        }
        .disabled(!enabled)
        // Greyed out rather than hidden: a control that vanishes teaches nothing, and a
        // control that is present but refuses teaches the reader it is unreliable. The
        // engine tells us which are live (§5.4 of the M3 spec).
    }

    // MARK: - Magnifier

    private var magnifier: some View {
        ZStack(alignment: .bottom) {
            // Absorbs everything. Pan MUST NOT reach SDL: Ren'Py reads a horizontal drag
            // as rollback, so panning a magnified view would scroll the reader backwards
            // through dialogue they had not finished.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            model.setMagnification(
                                model.magnification,
                                offset: CGSize(
                                    width: value.translation.width / model.magnification,
                                    height: value.translation.height / model.magnification))
                        }
                )

            VStack(spacing: 14) {
                Text("Magnifier")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))

                Text("Text gets larger, but also softer — this magnifies the picture "
                     + "rather than resizing the writing.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320)

                HStack(spacing: 18) {
                    Button {
                        model.setMagnification(model.magnification - 0.25,
                                               offset: model.magnifyOffset)
                    } label: {
                        Image(systemName: "minus.magnifyingglass").font(.system(size: 20))
                    }

                    Text(String(format: "%.2fx", model.magnification))
                        .font(.system(size: 15).monospacedDigit())
                        .frame(width: 62)

                    Button {
                        model.setMagnification(model.magnification + 0.25,
                                               offset: model.magnifyOffset)
                    } label: {
                        Image(systemName: "plus.magnifyingglass").font(.system(size: 20))
                    }

                    Button("Done") { model.exitMagnifier() }
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundColor(.white)
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.11)))
            .padding(.bottom, 24)
        }
    }
}
