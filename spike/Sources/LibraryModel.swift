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

    private let memory = MemoryLog()
    private var libraryVisits = 0
    private var gameStarts = 0

    weak var presenter: UIViewController?
    private weak var coordinator: VNPlayerCoordinator?

    private var paths: VNPlayerPaths?
    private var store: LibraryStore?
    private var commands: Spool?
    private var events: Spool?

    private var pendingCommandId: String?
    private var pollTimer: Timer?

    /// A launch that never confirms must not hang forever, and must not be called failed
    /// too early either: a large game compiling its scripts on first run genuinely takes
    /// a while, and treating slow as broken would make big games unusable.
    private let launchTimeout: TimeInterval = 60

    func attach(coordinator: VNPlayerCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - Startup

    func start() {
        do {
            let paths = try VNPlayerPaths.standard()
            try paths.createDirectories()

            self.paths = paths
            self.store = LibraryStore(paths: paths)
            self.commands = Spool(directory: paths.commands)
            self.events = Spool(directory: paths.events)

            // Anything left in the command spool predates this launch and is stale by
            // definition. Replaying it would start a game the user did not ask for --
            // quite possibly the one that killed the app last time.
            commands?.clear()
            events?.clear()

            checkCrashSentinel()
            store?.emptyTrash()
            reload()
        } catch {
            errorMessage = "Could not set up storage: \(error.localizedDescription)"
        }

        recordLibrarySample()

        startPolling()
        coordinator?.setLibraryVisible(true)
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
        guard let paths, let commands, case .idle = phase else { return }

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
        guard let commands else { return }
        try? commands.write(ProtocolMessages.quitToLibrary(commandId: UUID().uuidString))
        phase = .idle
        coordinator?.setLibraryVisible(true)
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
        guard let events else { return }

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
                    coordinator?.setLibraryVisible(false)
                    gameStarts += 1
                    memory.record("game \(gameStarts)")
                    memorySamples = memory.samples
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
                    coordinator?.setLibraryVisible(true)
                }

            default:
                continue
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
