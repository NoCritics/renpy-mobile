import SwiftUI
import UniformTypeIdentifiers

/// The library. Opaque, and it covers the engine completely while it is up.
struct LibraryView: View {

    @ObservedObject var model: LibraryModel

    var body: some View {
        ZStack {
            if isHidden {
                whilePlaying
            } else {
                content
            }
        }
        .animation(.default, value: isHidden)
        .fileImporter(
            isPresented: $model.showImporter,
            allowedContentTypes: Self.importableTypes,
            allowsMultipleSelection: false
        ) { result in
            model.handlePicked(result)
        }
        .alert("Import failed", isPresented: errorBinding) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert(item: $model.pendingExport) { confirmation in
            Alert(title: Text(confirmation.title),
                  message: Text(confirmation.message),
                  primaryButton: .default(Text("Export")) { model.performExport() },
                  secondaryButton: .cancel())
        }
        .sheet(isPresented: Binding(
            get: { model.shareURL != nil },
            set: { if !$0 { model.dismissShare() } })
        ) {
            if let url = model.shareURL { ShareSheet(url: url) }
        }
    }

    /// While a game runs, the overlay owns the window. See OverlayView.
    private var whilePlaying: some View {
        OverlayView(model: model)
    }

    private var isHidden: Bool {
        if case .playing = model.phase { return true }
        return false
    }

    /// What the picker will let the reader select.
    ///
    /// Wider than `.zip` alone, and deliberately. A document provider types a file
    /// lazily; until it resolves one, the file is listed but greyed out and cannot be
    /// tapped -- which is indistinguishable, to the person holding the phone, from the
    /// file not being there. `public.zip-archive` is also not the only UTI a `.zip` can
    /// carry: older exporters still declare `com.pkware.zip-archive`, and a provider that
    /// knows nothing about a file falls back to `public.data`.
    ///
    /// Widening it costs nothing, because the picker is not what decides whether an
    /// archive is usable. `ArchiveImporter` reads the file's actual central directory and
    /// answers "That doesn't look like a .zip file." for anything that is not one. A
    /// filter that hides the file the reader is looking for is the worse failure: it
    /// offers no message at all.
    static let importableTypes: [UTType] = {
        var types: [UTType] = [.zip, .archive]
        if let byExtension = UTType(filenameExtension: "zip") {
            types.append(byExtension)
        }
        if let pkware = UTType("com.pkware.zip-archive") {
            types.append(pkware)
        }
        // Distinct identifiers only; the picker treats a repeated type as a conflict.
        var seen = Set<String>()
        return types.filter { seen.insert($0.identifier).inserted }
    }()

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

            if !model.memorySamples.isEmpty {
                memoryPanel
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
                    model.confirmExport(nil)          // nil means every game
                } label: {
                    Label("Back up saves", systemImage: "arrow.up.doc.on.clipboard")
                        .font(.system(size: 17, weight: .semibold))
                }
                .buttonStyle(.bordered)

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

    /// On-device memory readings.
    ///
    /// Here rather than in the log because the log physically cannot carry it: only
    /// argument-free NSLog lines survive the USB relay, so no number can ever be
    /// printed. This panel is the measurement channel.
    ///
    /// `phys_footprint` specifically, because that is the number Jetsam kills on --
    /// resident size is a different figure and an app can look comfortable by it and
    /// still be killed. "free" is `os_proc_available_memory`, the distance to being
    /// killed rather than the distance from zero.
    private var memoryPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Memory")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))

                Spacer()

                if let mean = model.meanGrowthPerCycleMB {
                    Text(String(format: "%+.1f MB per library visit", mean))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundColor(mean > 5 ? .orange : .green)
                } else {
                    // Said out loud rather than shown as a zero. One sample cannot
                    // describe growth, and a "0.0" here would read as "no leak".
                    Text("open a game and come back to measure growth")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }
            }

            ForEach(model.memorySamples.suffix(8)) { sample in
                HStack(spacing: 10) {
                    Text(sample.label)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(.white.opacity(0.5))
                        .frame(width: 74, alignment: .leading)
                    Text(String(format: "%.0f MB", sample.footprintMB))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(.white.opacity(0.75))
                        .frame(width: 70, alignment: .trailing)
                    Text(sample.availableBytes > 0
                         ? String(format: "%.0f MB free", sample.availableMB)
                         : "free unknown")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(.white.opacity(0.4))
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 14)
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
                            Button {
                                model.confirmExport(entry)
                            } label: {
                                Label("Export saves", systemImage: "square.and.arrow.up")
                            }
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
