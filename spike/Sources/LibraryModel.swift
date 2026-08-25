import Foundation
import SwiftUI
import UIKit

/// What the library is doing right now.
enum LibraryPhase: Equatable {
    case idle
    case importing(progress: Double, title: String)
    /// A launch has been written and we are waiting for the engine to confirm it.
    case launching(gameId: String, since: Date)
    /// The game is up. The library hides itself in this state.
    case playing(gameId: String)
}

@MainActor
final class LibraryModel: ObservableObject {

    @Published var entries: [LibraryEntry] = []
    @Published var phase: LibraryPhase = .idle
    @Published var errorMessage: String?
    @Published var noticeMessage: String?
    @Published var showImporter = false
    /// Pruning saves 100-200 MB per game, and is the default. Exposed because a user who
    /// wants the whole distribution should be able to say so.
    @Published var pruneDesktopFiles = true

    /// On-device memory readings, shown in the library because the device log cannot
    /// carry them: only argument-free NSLog lines survive the USB relay, so a number
    /// can never be printed. The screen is the only channel a measurement fits through.
    @Published var memorySamples: [MemorySample] = []
    @Published var meanGrowthPerCycleMB: Double?

    @Published var overlay: OverlayState = .playing
    @Published var engine = ProtocolMessages.EngineState()
    /// A sentence from the engine explaining why a control did nothing.
    @Published var overlayMessage: String?
    @Published var magnification: CGFloat = 1
    @Published var magnifyOffset: CGSize = .zero

    var lastControlCommandId: String?
    var memoryWarningShown = false
    var commands: Spool? { commandSpool }

    private let memory = MemoryLog()
    private var libraryVisits = 0
    private var gameStarts = 0

    weak var presenter: UIViewController?
    weak var coordinatorRef: VNPlayerCoordinator?

    private var paths: VNPlayerPaths?
    private var store: LibraryStore?
    private var commandSpool: Spool?
    private var eventSpool: Spool?

    private var pendingCommandId: String?
    private var pollTimer: Timer?

    /// A launch that never confirms must not hang forever, and must not be called failed
    /// too early either: a large game compiling its scripts on first run genuinely takes
    /// a while, and treating slow as broken would make big games unusable.
    private let launchTimeout: TimeInterval = 60

    func attach(coordinator: VNPlayerCoordinator) {
        self.coordinatorRef = coordinator
    }

    // MARK: - Startup

    func start() {
        do {
            let paths = try VNPlayerPaths.standard()
            try paths.createDirectories()

            self.paths = paths
            self.store = LibraryStore(paths: paths)
            self.commandSpool = Spool(directory: paths.commands)
            self.eventSpool = Spool(directory: paths.events)

            // Anything left in the command spool predates this launch and is stale by
            // definition. Replaying it would start a game the user did not ask for --
            // quite possibly the one that killed the app last time.
            commandSpool?.clear()
            eventSpool?.clear()

            checkCrashSentinel()
            store?.emptyTrash()
            reload()
        } catch {
            errorMessage = "Could not set up storage: \(error.localizedDescription)"
        }

        recordLibrarySample()

        startPolling()
        applyWindowState()
    }

    /// A sentinel written before a launch and cleared on `gameReady`. Finding one at
    /// startup means that launch took the process down with it -- iOS terminates the app
    /// outright when Ren'Py fails hard enough during init, leaving nothing in memory to
    /// tell us afterwards. Without this a game that crashes on boot is unrecoverable
    /// short of deleting the app.
    private func checkCrashSentinel() {
        guard let paths, let store else { return }

        guard let gameId = try? String(contentsOf: paths.launchSentinel, encoding: .utf8),
              !gameId.isEmpty else { return }

        try? FileManager.default.removeItem(at: paths.launchSentinel)

        var current = store.load()
        if let index = current.firstIndex(where: { $0.id == gameId }) {
            current[index].crashCount += 1
            try? store.save(current)
            try? store.writeManifest(current[index])
            noticeMessage = "\(current[index].title) closed unexpectedly last time it "
                + "started. It has not been launched again."
        }
        entries = current
    }

    func reload() {
        entries = store?.load() ?? []
    }

    // MARK: - Import

    func beginImport() {
        showImporter = true
    }

    func handlePicked(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            importArchive(at: url)
        }
    }

    private func importArchive(at pickedURL: URL) {
        guard let paths, let store else { return }

        let fileName = pickedURL.lastPathComponent
        phase = .importing(progress: 0, title: fileName)

        let prune = pruneDesktopFiles
        let staging = paths.imports.appendingPathComponent(UUID().uuidString, isDirectory: true)

        Task.detached(priority: .userInitiated) { [weak self] in
            // A URL from the document picker is security-scoped when it comes from
            // iCloud Drive or another provider. Without this the reads silently return
            // nothing rather than failing loudly.
            let scoped = pickedURL.startAccessingSecurityScopedResource()
            defer { if scoped { pickedURL.stopAccessingSecurityScopedResource() } }

            let importer = ArchiveImporter(pruneDesktopFiles: prune)

            do {
                try FileManager.default.createDirectory(
                    at: staging, withIntermediateDirectories: true)

                let plan = try importer.plan(archiveURL: pickedURL, archiveFileName: fileName)

                try ImportSupport.assertSpaceAvailable(for: plan, at: paths.documents)

                let taken = await MainActor.run { store.takenIds() }
                let id = GameIdentityDeriver.uniqueId(plan.identity.id, taken: taken)

                _ = try importer.extract(
                    archiveURL: pickedURL,
                    plan: plan,
                    to: staging,
                    progress: { value in
                        Task { @MainActor [weak self] in
                            self?.phase = .importing(progress: value, title: plan.identity.title)
                        }
                    }
                )

                try store.install(stagedAt: staging, as: id)

                let size = ImportSupport.directorySize(paths.gameDirectory(id))
                let entry = LibraryEntry(
                    id: id,
                    title: plan.identity.title,
                    coverPath: nil,
                    sizeBytes: size,
                    addedAt: Date(),
                    detectedEngine: plan.engine,
                    importedComplete: !prune
                )
                _ = try store.upsert(entry)

                await MainActor.run { [weak self] in
                    self?.phase = .idle
                    self?.reload()
                    if plan.prunedBytes > 0 {
                        self?.noticeMessage = "Imported \(plan.identity.title), skipping "
                            + "\(ImportError.gib(plan.prunedBytes)) of desktop files it "
                            + "does not need on a phone."
                    } else {
                        self?.noticeMessage = "Imported \(plan.identity.title)."
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: staging)
                let message = (error as? ImportError)?.userMessage ?? error.localizedDescription
                await MainActor.run { [weak self] in
                    self?.phase = .idle
                    self?.errorMessage = message
                }
            }
        }
    }

    // MARK: - Launch

    func launch(_ entry: LibraryEntry) {
        guard let paths, let commands = commandSpool, case .idle = phase else { return }

        let commandId = UUID().uuidString
        pendingCommandId = commandId

        // Written BEFORE the command. If the game takes the process down during init,
        // this file is the only evidence left that it was us who asked for it.
        try? Data(entry.id.utf8).write(to: paths.launchSentinel, options: .atomic)

        do {
            // Built by ProtocolMessages, in the tested target, rather than inline
            // here. Inline is how the shapes drifted: this app target has no tests, so
            // nothing asserted what crossed the boundary.
            try commands.write(ProtocolMessages.launch(
                commandId: commandId,
                gameId: entry.id,
                basedir: paths.gameDirectory(entry.id).path
            ))
            phase = .launching(gameId: entry.id, since: Date())
        } catch {
            try? FileManager.default.removeItem(at: paths.launchSentinel)
            pendingCommandId = nil
            errorMessage = "Could not start \(entry.title)."
        }
    }

    func returnToLibrary() {
        guard let commands = commandSpool else { return }
        try? commands.write(ProtocolMessages.quitToLibrary(commandId: UUID().uuidString))
        phase = .idle
        applyWindowState()
    }

    // MARK: - Events

    private func startPolling() {
        pollTimer?.invalidate()
        // Twice a second. The engine writes an event at most a few times per session, so
        // anything faster is spent spinning on an empty directory.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.drainEvents() }
        }
    }

    private func drainEvents() {
        guard let events = eventSpool else { return }

        for message in events.drain() {
            guard let parsed = ProtocolMessages.parseEvent(message.payload) else { continue }
            let name = parsed.name
            let commandId = parsed.commandId

            // Events from an abandoned launch arrive late and would otherwise dismiss
            // the library out from under a different one.
            switch name {
            case "gameReady":
                guard commandId == pendingCommandId else { continue }
                if case .launching(let gameId, _) = phase {
                    try? paths.map { try? FileManager.default.removeItem(at: $0.launchSentinel) }
                    phase = .playing(gameId: gameId)
                    applyWindowState()
                    gameStarts += 1
                    memory.record("game \(gameStarts)")
                    memorySamples = memory.samples
                    if let last = memory.samples.last { checkMemoryPressure(last) }

                    // Every game starts with the overlay closed. On the very first game
                    // of an install it opens itself once, because an edge handle nobody
                    // mentions is a handle nobody finds.
                    overlay = .playing
                    applyWindowState()

                    // The strip is visible from the first frame, so it needs no summoning
                    // and no tutorial. One sentence on the first game of an install is
                    // still worth it, because a column of small icons over someone else's
                    // artwork is not self-evidently ours.
                    if !UserDefaults.standard.bool(forKey: "vnplayer.overlayHintShown") {
                        UserDefaults.standard.set(true, forKey: "vnplayer.overlayHintShown")
                        coordinatorRef?.showControlMessage(
                            "These controls are VNPlayer's, not the game's. "
                            + "They fade out while you read.")
                    }
                }

            case "launchFailed":
                guard commandId == pendingCommandId else { continue }
                let reason = message.payload["reason"] as? String ?? "unknown reason"
                clearSentinel()
                phase = .idle
                pendingCommandId = nil
                errorMessage = "That game could not be started: \(reason)."

            case "shellReady":
                clearSentinel()
                // Recorded unconditionally, not only when returning from a game. This is
                // the post-restart state, which is the one the leak question is about:
                // whatever the engine failed to release survives into it.
                recordLibrarySample()
                if case .playing = phase {
                    phase = .idle
                    applyWindowState()
                }

            default:
                // Control results and engine state. Returns false only for an event this
                // build genuinely does not know, which is worth not swallowing.
                if !handleControlEvent(name: name, commandId: commandId,
                                       payload: message.payload) {
                    continue
                }
            }
        }

        checkLaunchTimeout()
    }

    /// Sampling on entering the library, which is the state to compare like-for-like.
    ///
    /// Comparing a game sample against a library sample would measure the game's assets
    /// rather than what the switch failed to release, and the whole question is whether
    /// returning to the library returns to where it started.
    private func recordLibrarySample() {
        libraryVisits += 1
        memory.record("library \(libraryVisits)")
        memorySamples = memory.samples
        meanGrowthPerCycleMB = memory.meanGrowthPerCycle(labelPrefix: "library")
        if let last = memory.samples.last { checkMemoryPressure(last) }
    }

    private func clearSentinel() {
        guard let paths else { return }
        try? FileManager.default.removeItem(at: paths.launchSentinel)
    }

    private func checkLaunchTimeout() {
        guard case .launching(let gameId, let since) = phase else { return }
        guard Date().timeIntervalSince(since) > launchTimeout else { return }

        phase = .idle
        pendingCommandId = nil
        clearSentinel()

        let title = entries.first { $0.id == gameId }?.title ?? "That game"
        errorMessage = "\(title) is taking longer than expected to start. "
            + "It may still be loading — try again, or pick a different game."
    }

    // MARK: - Deletion

    func delete(_ entry: LibraryEntry, includingSaves: Bool) {
        guard let store else { return }
        do {
            entries = try store.delete(entry.id, alsoDeleteSaves: includingSaves)
            noticeMessage = includingSaves
                ? "Deleted \(entry.title) and its saves."
                : "Deleted \(entry.title). Its saves were kept."
        } catch {
            errorMessage = "Could not delete \(entry.title)."
        }
    }
}

/// Filesystem helpers used from the import task.
///
/// Deliberately OUTSIDE LibraryModel. They were static methods on it, and LibraryModel
/// is @MainActor -- which makes its statics main-actor-isolated too, so calling them
/// from the detached import task was an actor hop the compiler rightly refused. Moving
/// them out is better than awaiting them: neither touches UI state, and hopping to the
/// main actor to measure a directory would put filesystem work back on the thread the
/// import exists to keep clear.
enum ImportSupport {
    /// Refuses before writing rather than filling the disk and failing halfway. The
    /// headroom is not superstition: iOS behaves badly at genuinely zero free space, and
    /// the staging copy is moved rather than copied, so peak usage is one game's worth.
    static func assertSpaceAvailable(for plan: ImportPlan, at url: URL) throws {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return }

        let headroom: Int64 = 256 * 1_048_576
        let needed = plan.totalUncompressed + headroom

        if available < needed {
            throw ImportError.insufficientSpace(needed: needed, available: available)
        }
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }
}

// MARK: - Overlay

/// What the overlay is doing while a game runs.
///
/// These three states are exactly the three hit-testing states of the window, and that
/// is not a coincidence — keeping them the same thing is what stops "sometimes passes
/// through" from becoming ambiguous again:
///
///   closed    → window passes touches through; only the handle is a real view
///   open      → window ABSORBS everything; ordinary SwiftUI works normally
///   magnified → window ABSORBS everything; pan and zoom are handled in Swift
///
/// The absorbing states are why the control strip can be plain SwiftUI. The hosting view
/// answering every touch is only a problem when we need some touches to escape, and while
/// the overlay is open none of them should. A tap outside the strip dismisses it, and
/// must NOT also advance the game's dialogue.
/// Two states, not three.
///
/// The control strip is on screen the whole time a game runs -- there is no opening or
/// closing it, so there is no "open". What remains is whether the magnifier has taken
/// over, because that is the one state where the window must absorb every touch instead
/// of passing them to the game.
enum OverlayState: Equatable {
    /// Playing. Window passes touches through; the UIKit strip is the only live view.
    case playing
    /// Magnifier. Window ABSORBS everything, so a pan cannot reach SDL -- Ren'Py reads a
    /// horizontal drag as rollback and would scroll the reader backwards through
    /// dialogue they had not finished.
    case magnified
}

extension LibraryModel {

    var isPlaying: Bool {
        if case .playing = phase { return true }
        return false
    }

    // MARK: Opening and closing

    func enterMagnifier() {
        guard isPlaying else { return }
        overlay = .magnified
        applyWindowState()
    }

    func exitMagnifier() {
        magnification = 1
        magnifyOffset = .zero
        coordinatorRef?.applyMagnification(scale: 1, offset: .zero)
        overlay = .playing
        applyWindowState()
    }

    func setMagnification(_ scale: CGFloat, offset: CGSize) {
        // Clamped rather than free: an unbounded zoom can push the whole rendered frame
        // off screen, and there is no way back from a black screen with no controls.
        magnification = min(max(scale, 1), 4)
        magnifyOffset = offset
        coordinatorRef?.applyMagnification(scale: magnification, offset: offset)
    }

    /// The one place that decides what the window does. Every state change routes through
    /// here rather than setting passthrough at the call site, because a state that sets
    /// it inconsistently is precisely the bug M2 shipped.
    func applyWindowState() {
        let libraryVisible = !isPlaying

        coordinatorRef?.applyWindow(
            passthrough: isPlaying && overlay == .playing,
            showControls: isPlaying && overlay == .playing,
            makeKey: libraryVisible
        )

        if isPlaying {
            coordinatorRef?.updateControls(
                canRollback: engine.canRollback,
                canSave: engine.canSave,
                isSkipping: engine.isSkipping)
        }
    }

    // MARK: Controls

    func quickSave() { sendControl(ProtocolMessages.CommandName.quickSave) }
    func quickLoad() { sendControl(ProtocolMessages.CommandName.quickLoad) }
    func rollback() { sendControl(ProtocolMessages.CommandName.rollback) }
    func toggleSkip() { sendControl(ProtocolMessages.CommandName.toggleSkip) }

    private func sendControl(_ name: String) {
        guard let commands else { return }

        let commandId = UUID().uuidString
        lastControlCommandId = commandId

        do {
            try commands.write(ProtocolMessages.control(name, commandId: commandId))
        } catch {
            overlayMessage = "That could not be sent to the game."
        }
    }

    /// Handles the events the controls produce. Returns true if it consumed the event.
    func handleControlEvent(name: String, commandId: String?, payload: [String: Any]) -> Bool {
        switch name {
        case ProtocolMessages.EventName.engineState:
            if let state = ProtocolMessages.EngineState(payload: payload) {
                engine = state
                coordinatorRef?.updateControls(
                    canRollback: state.canRollback,
                    canSave: state.canSave,
                    isSkipping: state.isSkipping)
            }
            return true

        case ProtocolMessages.EventName.commandDone:
            guard commandId == lastControlCommandId else { return true }
            overlayMessage = nil
            if let skipping = payload["isSkipping"] as? Bool {
                engine.isSkipping = skipping
            }
            return true

        case ProtocolMessages.EventName.commandFailed:
            guard commandId == lastControlCommandId else { return true }
            // Rendered as a sentence, because Python sends one. "there is nothing to roll
            // back to" is an answer to the reader's question, not an error report.
            let reason = payload[ProtocolMessages.Key.reason] as? String
                ?? "That did not work."
            overlayMessage = reason
            coordinatorRef?.showControlMessage(reason)
            return true

        default:
            return false
        }
    }

    // MARK: Memory

    /// Warn on remaining headroom, not on total used.
    ///
    /// 500 MB, set against the device measurement rather than guessed: a running game sat
    /// at ~2.45 GB free across four switch cycles, growing about 8 MB per switch. 500 MB
    /// is therefore roughly 240 switches away from anything observed — far enough that a
    /// false alarm is unlikely, early enough to leave room to act.
    static let memoryWarningThresholdBytes: Int64 = 500 * 1_048_576

    func checkMemoryPressure(_ sample: MemorySample) {
        guard sample.availableBytes > 0 else { return }

        if sample.availableBytes < Self.memoryWarningThresholdBytes {
            guard !memoryWarningShown else { return }
            memoryWarningShown = true
            noticeMessage = "VNPlayer is running low on memory. Closing and reopening the "
                + "app will free it up — your saves are safe."
        } else if sample.availableBytes > Self.memoryWarningThresholdBytes * 2 {
            // Rearm well above the threshold, so a reading hovering near it cannot
            // produce the warning again and again.
            memoryWarningShown = false
        }
    }
}
