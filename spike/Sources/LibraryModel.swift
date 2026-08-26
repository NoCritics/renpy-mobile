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

    enum PickerPurpose { case game, saves }

    /// What the open file picker is for. Deliberately NOT @Published and never bound to
    /// the view: SwiftUI clears an isPresented binding as it dismisses, and if the
    /// purpose rode on that binding the completion handler could read it after it had
    /// already been reset.
    private var pickerPurpose: PickerPurpose = .game

    @Published var showPicker = false
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

    struct ExportConfirmation: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let items: [SaveExportItem]
        let kind: SaveManifest.Kind
    }

    @Published var pendingExport: ExportConfirmation?
    @Published var shareURL: URL?

    struct ImportConfirmation: Identifiable {
        let id = UUID()
        let message: String
        let warning: String?
        let source: URL
        let set: SaveImportPlanSet
        let destinations: [URL]
    }

    @Published var pendingSaveImport: ImportConfirmation?

    struct GameChoice: Identifiable {
        let id = UUID()
        /// Held so the import can be re-planned once she picks.
        let source: URL
        let candidates: [LibraryEntry]
    }

    @Published var pendingGameChoice: GameChoice?

    /// Set by a row-scoped "Import saves", so a foreign file (which cannot name its own
    /// game) is imported into the row the reader tapped rather than guessed at or handed
    /// to the chooser. Read once, synchronously, inside the `resolve` closure that
    /// `SaveImporter.plan` calls from `handlePickedSave` -- see that method's `defer` for
    /// why this is always nil again by the time anything else could read it.
    private var importHint: LibraryEntry?

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
            cleanStaleExports()
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

    /// Removes any stray plain file left directly in `paths.imports` from a previous run.
    ///
    /// Exports no longer land here -- they are kept, deliberately, in
    /// `Saves/<gameId>/backup/` where the reader can find them. What remains is the
    /// backstop for game-import staging, which uses UUID-named SUBDIRECTORIES and cleans
    /// up after itself on both success and failure (see `importArchive`). So a plain file
    /// sitting directly in this directory is debris from an older build or an interrupted
    /// write, in a folder the Files app cannot even see (Application Support is hidden),
    /// which nothing else would ever reclaim.
    ///
    /// It stays deliberately conservative: only plain files, never directories, and never
    /// anything it cannot positively identify as a file -- the directory beside these is
    /// staging that can hold a multi-gigabyte extraction.
    private func cleanStaleExports() {
        guard let paths else { return }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: paths.imports, includingPropertiesForKeys: [.isDirectoryKey]) else { return }

        for url in contents {
            // Fail CLOSED. If the file system will not tell us what this is, leave it
            // alone: `removeItem` deletes a directory recursively, and the directory next
            // to these exports is game-import staging, which can hold a multi-gigabyte
            // extraction. An unknown entry is worth leaking; it is not worth deleting.
            guard let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory else { continue }

            if !isDirectory {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Import

    func beginImport() {
        pickerPurpose = .game
        presentPicker()
    }

    /// Raise the file picker, healing a stranded flag rather than dying on it.
    ///
    /// This used to be `guard !showPicker else { return }`. That guard was meant to stop
    /// a double-tap re-presenting the sheet, and it did -- but it also meant that if
    /// `showPicker` was ever left `true` with no sheet on screen, every later tap hit the
    /// guard and returned, and the only way back was killing the app. Reported from the
    /// device as exactly that: "requires app restart".
    ///
    /// SwiftUI resets the binding when it dismisses, but an interrupted dismissal does
    /// not always get there, and a flag whose only writer is the framework is a flag we
    /// cannot promise anything about. So: if it is already set, clear it and re-raise on
    /// the next runloop pass, which gives SwiftUI the false->true transition it needs to
    /// present. A stale flag now costs one frame instead of a restart.
    private func presentPicker() {
        // Argument-free: on iOS only NSLog lines with no formatted value survive the USB
        // relay intact, measured in Milestone B. `print` does NOT reach the device log at
        // all for a sideloaded app -- it writes to stdout, which the device log never
        // sees. These lines are what distinguish "the picker never opened" from "it
        // opened and the provider listed nothing", which are different bugs with
        // different owners.
        guard showPicker else {
            NSLog("[vnspike] importer: opening")
            showPicker = true
            return
        }

        NSLog("[vnspike] importer: flag was stale, re-raising")
        showPicker = false
        DispatchQueue.main.async { [weak self] in
            self?.showPicker = true
        }
    }

    /// The single `.fileImporter`'s completion handler routes here, and dispatches on
    /// `pickerPurpose` to whichever picker actually opened it. See `pickerPurpose`'s
    /// comment for why that routing cannot ride on the presentation binding itself.
    func handlePickedFile(_ result: Result<[URL], Error>) {
        // Belt and braces with `presentPicker`'s stale-flag recovery. The completion
        // fires on every outcome including cancellation, so this is the one place the
        // flag is guaranteed to be cleared by us rather than only by the framework.
        showPicker = false

        switch pickerPurpose {
        case .game: handlePicked(result)
        case .saves: handlePickedSave(result)
        }
    }

    func handlePicked(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            NSLog("[vnspike] importer: failed")
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else {
                // The picker returned success with nothing in it. Not a state that should
                // occur, and silence here would look exactly like a dead button.
                NSLog("[vnspike] importer: returned no file")
                return
            }
            NSLog("[vnspike] importer: picked a file")
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

                    // Spec §3.1: the engine is the only source for config.save_directory,
                    // and it only ever says so at gameReady. Joined onto the library entry
                    // here so the export manifest (and WHERE-TO-PUT-THESE.txt) can name the
                    // reader's real desktop folder instead of falling back to the null
                    // branch for every game, forever.
                    if let directory = ProtocolMessages.gameReadySaveDirectory(message.payload),
                       let store,
                       let index = entries.firstIndex(where: { $0.id == gameId }),
                       entries[index].saveDirectory != directory {
                        var updated = entries[index]
                        updated.saveDirectory = directory
                        if let saved = try? store.upsert(updated) {
                            entries = saved
                        }
                    }

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

    // MARK: Save export

    /// Build the confirmation for an export. `entry` nil means every game.
    ///
    /// The numbers come from `summarise`, which writes nothing -- a confirmation that
    /// had to produce the file first would not be a confirmation.
    func confirmExport(_ entry: LibraryEntry?) {
        guard let paths else { return }

        let chosen = entry.map { [$0] } ?? entries
        let items = chosen.map {
            SaveExportItem(gameId: $0.id, title: $0.title,
                           saveDirectory: $0.saveDirectory,
                           directory: paths.saveDirectory($0.id))
        }

        let summary = SaveExporter.summarise(items)

        guard summary.fileCount > 0 else {
            errorMessage = entry == nil
                ? "There are no saves to back up yet."
                : "\(entry!.title) has no saves yet."
            return
        }

        let size = ByteCountFormatter.string(fromByteCount: summary.totalBytes,
                                             countStyle: .file)
        let saves = summary.fileCount == 1 ? "1 save" : "\(summary.fileCount) saves"

        pendingExport = ExportConfirmation(
            title: entry == nil ? "Back up all saves" : "Export saves",
            message: entry == nil
                ? "Back up saves for all \(chosen.count) games? \(saves), \(size)."
                : "Export saves for \(entry!.title)? \(saves), \(size). "
                  + "You'll choose where to put the file next.",
            items: items,
            kind: entry == nil ? .backup : .game)
    }

    func performExport() {
        guard let confirmation = pendingExport, let paths else { return }
        pendingExport = nil

        // This used to also delete a previous, not-yet-picked-up `shareURL` here, on the
        // same reasoning I7 already reversed for `dismissShare()`: a share sheet the
        // reader has not dismissed yet (or handed to AirDrop/Save-to-Files, which can
        // keep reading asynchronously after it visibly closes) may still be consuming
        // that file. Exporting game B while game A's share sheet for a previous export is
        // still up -- or still being read by an activity -- must not delete A's file out
        // from under it. `cleanStaleExports()` already sweeps `paths.imports` at every
        // launch, so it owns this file's lifetime too; the cost is that a session which
        // exports several times in a row can leave more than one file sitting there until
        // the next launch, which is the safe direction to be wrong in.

        // Date AND time. These files used to live in a hidden staging folder and be
        // swept at launch, so a same-day collision only ever cost a file nobody could
        // reach. They are kept now, which makes two backups on one day a case of the
        // second destroying the first -- exactly the thing a backup exists to prevent.
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HHmm"
        let dated = stamp.string(from: Date())

        let name = confirmation.kind == .backup
            ? "VNPlayer saves \(dated).zip"
            : "\(confirmation.items[0].title) saves \(dated).zip"

        // Beside the saves they came from, where she can find them without being told:
        // On My iPhone -> VNPlayer -> Saves -> <game> -> backup. A whole-library backup
        // belongs to no single game, so it sits one level up.
        let directory = confirmation.kind == .backup
            ? paths.backups
            : paths.backupDirectory(confirmation.items[0].gameId)

        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        let out = directory.appendingPathComponent(name)

        do {
            _ = try SaveExporter.export(confirmation.items, kind: confirmation.kind,
                                        appVersion: Self.appVersion, to: out,
                                        now: Date())
            shareURL = out
        } catch let error as SaveTransferError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "That export did not work."
        }
    }

    /// Called when the share sheet closes, whichever way: the reader picked a
    /// destination, or cancelled.
    ///
    /// I7: this used to also delete `shareURL` here, on the assumption that
    /// `UIActivityViewController` only dismisses once the chosen activity has finished
    /// consuming the file. That assumption does not reliably hold for AirDrop or
    /// Save-to-Files, which can keep reading the URL asynchronously after the sheet
    /// visibly closes -- deleting here could truncate the very backup this feature
    /// exists to produce. `cleanStaleExports()` already sweeps `paths.imports` at every
    /// launch and is safe to rely on for this instead: it costs one extra file sitting
    /// in a hidden directory between now and the next launch, which is the safe
    /// direction to be wrong in, versus a truncated backup. So `paths.imports` -- and
    /// therefore the file's lifetime -- is owned by that sweep, not by this dismissal.
    func dismissShare() {
        shareURL = nil
    }

    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    /// Export the game that is running now.
    ///
    /// `LibraryPhase.playing` already carries the id (`LibraryModel.swift:12`), so there
    /// is no second source of truth to keep in step with it.
    func confirmExportCurrentGame() {
        guard case .playing(let id) = phase,
              let entry = entries.first(where: { $0.id == id })
        else { return }
        confirmExport(entry)
    }

    // MARK: Save import

    func beginSaveImport(into hint: LibraryEntry? = nil) {
        importHint = hint
        pickerPurpose = .saves
        NSLog("[vnspike] save import: opening")
        presentPicker()
    }

    func handlePickedSave(_ result: Result<[URL], Error>) {
        // This attempt's hint is spent the moment `resolve` below reads it, on every
        // branch this function can take -- matched, unmatched (chooser/error), or a
        // thrown error. Clearing it unconditionally on exit is what keeps a cancelled or
        // failed import from leaving a stale hint for the next, unrelated import.
        defer { importHint = nil }

        // I4: the game-import equivalent (`handlePicked`, above) sets `errorMessage` on
        // a picker failure; this one silently returned, so a picker error here was a
        // button that did nothing, forever.
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
            return
        case .success(let urls):
            guard let first = urls.first else { return }
            handlePickedSave(url: first)
        }
    }

    private func handlePickedSave(url: URL) {
        guard let paths else { return }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var destinations: [URL] = []

        do {
            let set = try SaveImporter.plan(source: url, resolve: { plan in
                // A row-scoped import means "into this game", and a foreign file cannot
                // name its own game, so the row IS the answer. Consulted before the
                // id/title matches because those are structurally nil for a foreign plan
                // and would fall through to a chooser the reader already answered by
                // tapping a specific row.
                let match = (plan.gameId == nil ? self.importHint : nil)
                    ?? self.entries.first { $0.id == plan.gameId }
                    ?? self.entries.first { $0.title == plan.title }
                    ?? (plan.gameId == nil && self.entries.count == 1
                        ? self.entries[0] : nil)
                guard let match else { return nil }
                let directory = paths.saveDirectory(match.id)
                destinations.append(directory)
                return directory
            }, caps: .default)

            guard !set.plans.isEmpty else {
                // §4.2 case 3. A bare .save carries no id and no title, and a manifest
                // can name a game installed here under a different id -- ids come from
                // the archive's distribution root, so the same game from a differently
                // named .zip legitimately differs. Refusing outright would strand the
                // case this feature exists for.
                if entries.isEmpty {
                    errorMessage = "Add a game first, then import its saves."
                } else if set.missingGames.isEmpty {
                    pendingGameChoice = GameChoice(source: url, candidates: entries)
                } else {
                    errorMessage = "These saves are for "
                        + "\(set.missingGames.joined(separator: ", ")), "
                        + "which isn't installed."
                }
                return
            }

            pendingSaveImport = ImportConfirmation(
                message: Self.describe(set),
                // Spec §6: one warning, inside this sheet, never a checkmark.
                warning: set.isForeign
                    ? "This file didn't come from VNPlayer. Ren'Py saves can contain "
                      + "code, so only open it if you trust where it came from."
                    : nil,
                source: url,
                set: set,
                destinations: destinations)
        } catch let error as SaveTransferError {
            errorMessage = error.userMessage
        } catch let error as ImportError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "That file could not be read."
        }
    }

    /// Render the plan. This IS the confirmation -- see spec §4.5.
    static func describe(_ set: SaveImportPlanSet) -> String {
        var lines: [String] = []

        for plan in set.plans {
            let into = plan.title.map { " into \($0)" } ?? ""
            let fresh = plan.addedCount - plan.newSlotCount

            // Told before the fact, in the same words the result will use afterwards
            // (`SaveImporter.sentence`) -- `.copy`'s clause and `.keptExisting`'s both
            // describe what WILL happen, not what already has.
            let persistentClause: String?
            switch plan.persistentAction {
            case .copy:
                persistentClause = "Your gallery and settings for this game will come along too."
            case .keptExisting:
                persistentClause = "You already have gallery and settings here for this "
                    + "game, so those will be left as they are."
            case .none:
                persistentClause = nil
            }

            var line: String
            if plan.addedCount > 0 {
                // I10: "Import 1 saves" -- every count in this sentence needs its own
                // singular, not just the leading one.
                let saves = plan.addedCount == 1 ? "1 save" : "\(plan.addedCount) saves"
                line = "Import \(saves)\(into)?"
                if fresh > 0 {
                    line += fresh == 1
                        ? " 1 goes into an empty slot."
                        : " \(fresh) go into empty slots."
                }
                if plan.newSlotCount > 0 {
                    line += plan.newSlotCount == 1
                        ? " 1 into a new slot."
                        : " \(plan.newSlotCount) into new slots."
                }
                if !plan.alreadyPresent.isEmpty {
                    line += plan.alreadyPresent.count == 1
                        ? " 1 already here and will be skipped."
                        : " \(plan.alreadyPresent.count) already here and will be skipped."
                }
            } else if persistentClause != nil {
                // No save slots at all in this plan -- everything it carries for this
                // game is `persistent`. "Import 0 saves" would read as though there is
                // nothing here, when there is: the gallery and settings file.
                line = "Import\(into)?"
                if !plan.alreadyPresent.isEmpty {
                    line += plan.alreadyPresent.count == 1
                        ? " 1 save already here and will be skipped."
                        : " \(plan.alreadyPresent.count) saves already here and will be skipped."
                }
            } else {
                line = "Import\(into)?"
            }

            if let persistentClause {
                line += " " + persistentClause
            }

            lines.append(line)
        }

        if !set.missingGames.isEmpty {
            lines.append("Not installed, so skipped: "
                         + set.missingGames.joined(separator: ", ") + ".")
        }

        lines.append("Nothing will be replaced.")
        return lines.joined(separator: " ")
    }

    /// She picked a game for a save file that could not name one. Plan again, forcing
    /// every save into that game's directory, then show the ordinary §4.5 sheet -- the
    /// confirmation is not skipped just because a question preceded it.
    func chooseGame(_ entry: LibraryEntry) {
        guard let choice = pendingGameChoice, let paths else { return }
        pendingGameChoice = nil
        // Defensive, not load-bearing: this path never reads importHint (it answers
        // §4.2 case 3 directly, from the chooser, not from a row), but nothing should
        // carry a stale hint forward into whatever import happens next.
        importHint = nil

        let url = choice.source
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let directory = paths.saveDirectory(entry.id)

        do {
            let set = try SaveImporter.plan(source: url, resolve: { _ in directory },
                                            caps: .default)
            guard !set.plans.isEmpty else {
                errorMessage = "There was nothing to import."
                return
            }

            // I3: this used to hand-build its own sentence, which drifted from
            // `describe(_:)` and silently dropped two of its clauses (the empty-slot
            // count, the already-present count) -- importing a bare .save already on the
            // phone read "Import 0 saves into Big Bad Dogs? Nothing will be replaced."
            // A save that reached the chooser could not name its own game (§4.2 case 3),
            // so `describe` has no title to put in its "into <title>" clause; prepend
            // the game she just picked instead of leaving the sheet silent about it.
            let described = Self.describe(set)
            let message = set.plans.contains(where: { $0.title != nil })
                ? described
                : "Into \(entry.title). " + described

            // I3, minor: `set.plans` can be more than one entry even for a save file she
            // picked a single game for -- a hand-made zip with two `games/<x>/` folders
            // and no manifest plans two groups, both forced into the same directory here.
            // A one-element array tripped `performSaveImport`'s lockstep guard.
            let confirmation = ImportConfirmation(
                message: message,
                warning: set.isForeign
                    ? "This file didn't come from VNPlayer. Ren'Py saves can contain "
                      + "code, so only open it if you trust where it came from."
                    : nil,
                source: url,
                set: set,
                destinations: Array(repeating: directory, count: set.plans.count))

            // Same lockstep invariant as performSaveImport's guard below -- checked here
            // too because this is the other place an ImportConfirmation gets built by
            // hand, from a freshly-made plan rather than the one handlePickedSave built.
            guard confirmation.destinations.count == confirmation.set.plans.count else {
                errorMessage = "Something went wrong preparing that import. Nothing was changed."
                return
            }

            pendingSaveImport = confirmation
        } catch let error as SaveTransferError {
            errorMessage = error.userMessage
        } catch let error as ImportError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "That file could not be read."
        }
    }

    func performSaveImport() {
        guard let confirmation = pendingSaveImport else { return }
        pendingSaveImport = nil
        // Defensive, not load-bearing: importHint is already nil by now on every path
        // that reaches here (handlePickedSave clears it via `defer` before this
        // confirmation ever exists; chooseGame clears it before building its own). A
        // completed import must not leave it stale regardless, so this holds even if
        // one of those clears is ever removed by a future edit.
        importHint = nil

        // These two arrays are paired by index, and the pairing is maintained by
        // SaveImporter.plan calling `resolve` exactly once per appended plan. Nothing the
        // compiler checks enforces that. If it ever stops holding, the failure is one
        // game's saves written into another game's directory -- both paths valid, no
        // error. Refusing loudly is the only acceptable way to be wrong here.
        guard confirmation.destinations.count == confirmation.set.plans.count else {
            errorMessage = "Something went wrong preparing that import. Nothing was changed."
            return
        }

        let scoped = confirmation.source.startAccessingSecurityScopedResource()
        defer { if scoped { confirmation.source.stopAccessingSecurityScopedResource() } }

        var sentences: [String] = []

        do {
            for (index, plan) in confirmation.set.plans.enumerated() {
                let result = try SaveImporter.apply(
                    plan, source: confirmation.source,
                    into: confirmation.destinations[index])
                sentences.append(result.sentence)
            }
            noticeMessage = sentences.joined(separator: " ")
        } catch let error as SaveTransferError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "That import did not finish."
        }
    }

    /// Import from the strip. Returns to the library first, then picks.
    ///
    /// Not caution: Ren'Py caches the slot list and holds the save directory open, so
    /// writing files underneath a live engine leaves the game looking at saves that are
    /// not there.
    func importSavesFromStrip() {
        coordinatorRef?.showControlMessage("Returning to the library to import saves.")
        returnToLibrary()
        beginSaveImport()
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
                isSkipping: engine.isSkipping,
                inMenu: engine.inMenu)
        }
    }

    // MARK: Controls

    func quickSave() { sendControl(ProtocolMessages.CommandName.quickSave) }
    func quickLoad() { sendControl(ProtocolMessages.CommandName.quickLoad) }
    func rollback() { sendControl(ProtocolMessages.CommandName.rollback) }
    func toggleSkip() { sendControl(ProtocolMessages.CommandName.toggleSkip) }

    /// Open the game's own Save, Load or Preferences page.
    func showMenu(_ screen: ProtocolMessages.MenuScreen) {
        send { ProtocolMessages.showMenu(commandId: $0, screen: screen) }
    }

    private func sendControl(_ name: String) {
        send { ProtocolMessages.control(name, commandId: $0) }
    }

    /// One write path for every control. The builder is handed the commandId rather than
    /// the payload being assembled here, because the one time a command payload was built
    /// at the call site it drifted from what Python reads and the button silently did
    /// nothing for sixty seconds.
    private func send(_ build: (String) -> [String: Any]) {
        guard let commands else { return }

        let commandId = UUID().uuidString
        lastControlCommandId = commandId

        do {
            try commands.write(build(commandId))
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
                    isSkipping: state.isSkipping,
                    inMenu: state.inMenu)
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
