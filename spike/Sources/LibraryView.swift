import SwiftUI
import UniformTypeIdentifiers

/// The library. Opaque, and it covers the engine completely while it is up.
struct LibraryView: View {

    @ObservedObject var model: LibraryModel

    var body: some View {
        ZStack {
            if isHidden {
                // Playing. The window stays installed but draws nothing, so every touch
                // falls through PassthroughWindow.hitTest to the game underneath.
                Color.clear
            } else {
                content
            }
        }
        .animation(.default, value: isHidden)
        .fileImporter(
            isPresented: $model.showImporter,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            model.handlePicked(result)
        }
        .alert("Import failed", isPresented: errorBinding) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var isHidden: Bool {
        if case .playing = model.phase { return true }
        return false
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 0) {
            header

            if let notice = model.noticeMessage {
                noticeBar(notice)
            }

            switch model.phase {
            case .importing(let progress, let title):
                importing(progress: progress, title: title)
            case .launching(let gameId, _):
                launching(gameId: gameId)
            default:
                if model.entries.isEmpty { emptyState } else { grid }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.07).ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            Text("VNPlayer")
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(.white)

            Spacer()

            if case .idle = model.phase {
                Button {
                    model.beginImport()
                } label: {
                    Label("Add game", systemImage: "plus")
                        .font(.system(size: 17, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    private func noticeBar(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill").foregroundColor(.blue)
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                model.noticeMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .foregroundColor(.white.opacity(0.6))
        }
        .padding(14)
        .background(Color.white.opacity(0.08))
        .cornerRadius(10)
        .padding(.horizontal, 28)
        .padding(.bottom, 10)
    }

    /// The first run is always this screen, and a bare empty grid teaches nothing. It
    /// says where games come from, because the answer -- the Files app -- is not
    /// something a reader would guess.
    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "books.vertical")
                .font(.system(size: 54))
                .foregroundColor(.white.opacity(0.35))
            Text("No games yet")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white)
            Text("Tap Add game and choose a .zip you have already downloaded.\n"
                 + "You can also copy games straight into VNPlayer's folder in the Files app.")
                .font(.system(size: 15))
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.6))
                .padding(.horizontal, 40)
            Spacer()
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 210), spacing: 18)],
                spacing: 18
            ) {
                ForEach(model.entries) { entry in
                    GameTile(entry: entry) { model.launch(entry) }
                        .contextMenu {
                            Button(role: .destructive) {
                                model.delete(entry, includingSaves: false)
                            } label: {
                                Label("Delete game, keep saves", systemImage: "trash")
                            }
                            Button(role: .destructive) {
                                model.delete(entry, includingSaves: true)
                            } label: {
                                Label("Delete game and saves", systemImage: "trash.fill")
                            }
                        }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
    }

    private func importing(progress: Double, title: String) -> some View {
        VStack(spacing: 18) {
            Spacer()
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(maxWidth: 420)
            Text("Importing \(title)")
                .font(.system(size: 17))
                .foregroundColor(.white)
            Text("\(Int(progress * 100))%")
                .font(.system(size: 14).monospacedDigit())
                .foregroundColor(.white.opacity(0.6))
            Spacer()
        }
        .padding(.horizontal, 40)
    }

    private func launching(gameId: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
            Text("Starting \(model.entries.first { $0.id == gameId }?.title ?? "game")…")
                .font(.system(size: 17))
                .foregroundColor(.white)
            Text("A large game can take a while the first time.")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.5))
            Spacer()
        }
    }
}

private struct GameTile: View {
    let entry: LibraryEntry
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    // No cover art yet, so the tile generates something stable from the
                    // title. A grid of identical grey rectangles is harder to navigate
                    // than a grid of distinguishable ones, and this costs nothing.
                    RoundedRectangle(cornerRadius: 10)
                        .fill(placeholderColor)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    Text(initials)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundColor(.white.opacity(0.85))
                }

                Text(entry.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .buttonStyle(.plain)
    }

    private var initials: String {
        let words = entry.title.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    /// Deterministic from the title, so a game keeps its colour across restarts.
    private var placeholderColor: Color {
        var hash: UInt64 = 5381
        for byte in entry.title.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return Color(hue: Double(hash % 360) / 360.0, saturation: 0.45, brightness: 0.5)
    }

    private var subtitle: String {
        var parts: [String] = []
        if entry.sizeBytes > 0 {
            parts.append(ImportError.gib(entry.sizeBytes))
        }
        if entry.detectedEngine == .unknown {
            parts.append("engine unknown")
        }
        return parts.joined(separator: " · ")
    }
}
