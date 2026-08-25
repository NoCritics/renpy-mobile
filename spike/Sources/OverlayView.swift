import SwiftUI

/// The SwiftUI half of what the window shows while a game is running — which is now only
/// the magnifier.
///
/// **The controls are NOT here.** They are `OverlayControlStrip`, in UIKit, because they
/// are on screen permanently and touches must pass through around them permanently.
/// `UIHostingController`'s view answers every hit test itself, so a SwiftUI control cannot
/// be distinguished from empty space by a passthrough window — it renders and is inert.
///
/// SwiftUI is safe for the magnifier for the opposite reason: while magnified the window
/// ABSORBS every touch, so nothing needs to escape. The moment a state needs to be both
/// interactive and passthrough, it belongs in the UIKit strip instead.
struct OverlayView: View {

    @ObservedObject var model: LibraryModel

    var body: some View {
        switch model.overlay {
        case .playing:
            // Nothing here may take a touch. The control strip is UIKit and lives above
            // this view; everything else must reach the game.
            Color.clear
                .allowsHitTesting(false)
                .ignoresSafeArea()

        case .magnified:
            magnifier
        }
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
