import Foundation
import Observation
import os

private nonisolated let logger = Logger(subsystem: "com.ming.Deutschcoach", category: "database")

/// App-wide state: opens the database, imports the bundled seeds (DESIGN.md §2.5), and owns the
/// practice engine, the history, and the settings and library actions.
@Observable
final class AppModel {
    enum Phase: Equatable {
        case starting
        /// Bundled seeds are being imported (first launch, after an update or a reset).
        case importing
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .starting
    private(set) var databasePath: String?
    private(set) var library = LibraryStats()
    /// Bundled seeds that could not be imported at the last attempt (§2.5).
    private(set) var seedFailures: [BundledSeeds.Failure] = []

    private(set) var database: AppDatabase?
    /// Owned here so that its work is not tied to a view's lifetime.
    private(set) var practice: PracticeEngine?
    private(set) var history: HistoryModel?
    private(set) var nativeLanguage = NativeLanguage.current
    /// The checked libraries (seed ids), kept valid against `library.seeds` (DESIGN.md §3.2).
    private(set) var practiceSeeds: [String] = PracticeSelection.stored ?? []

    let speaker = Speaker()

    /// Unit tests run inside the app; they must not touch the real practice state.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func start() async {
        // The app is the test host: tests use their own in-memory databases and must not
        // migrate or import into the real one.
        guard database == nil, !Self.isRunningTests else { return }
        do {
            let database = try AppDatabase.openShared()
            self.database = database
            databasePath = database.path
            try await importBundledSeeds()
            phase = .ready
            startPractice(database)
        } catch {
            logger.error("Startup failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
        }
    }

    private func startPractice(_ database: AppDatabase) {
        guard practice == nil, !Self.isRunningTests else { return }
        let history = HistoryModel(database: database, speaker: speaker)
        self.history = history
        let engine = PracticeEngine(database: database, speaker: speaker, seedIds: practiceSeeds)
        engine.onSessionFinished = { Task { await history.reload() } }
        history.onReplayStart = { [weak engine] in engine?.interrupt() }
        practice = engine
        // Unstructured: not cancelled together with the caller's task.
        Task { await engine.start() }
    }

    /// §2.5: imports each bundled seed that is newer than the imported one, off the main actor.
    private func importBundledSeeds() async throws {
        guard let database else { return }
        phase = .importing
        let urls = BundledSeeds.urls()
        let outcome = await Task.detached { await BundledSeeds.importIfNeeded(urls, into: database) }.value
        seedFailures = outcome.failures
        try await refreshLibrary()
    }

    // MARK: - Settings (DESIGN.md §6)

    /// §3.1: only the displayed translation changes.
    func setNativeLanguage(_ language: String) async {
        guard language != nativeLanguage else { return }
        NativeLanguage.current = language
        nativeLanguage = language
    }

    /// Settings › Library: checks or unchecks a library; the last checked one stays checked.
    /// §3.1: the active session ends and a new one starts from the new selection.
    func setPracticed(_ seedId: String, _ isOn: Bool) async {
        var selected = Set(practiceSeeds)
        if isOn { selected.insert(seedId) } else { selected.remove(seedId) }
        guard !selected.isEmpty else { return }
        let ordered = PracticeSelection.sorted(library.seeds).map(\.seedId).filter(selected.contains)
        await applySelection(ordered)
    }

    /// Keeps the selection valid after the libraries changed (launch, import, reset).
    private func resolveSelection() async {
        let resolved = PracticeSelection.resolve(stored: practiceSeeds.isEmpty ? PracticeSelection.stored : practiceSeeds,
                                                 legacyLevel: PracticeSelection.legacyLevel, seeds: library.seeds)
        // Nothing imported (e.g. midway through a reset): keep the selection as it is.
        guard !resolved.isEmpty else { return }
        PracticeSelection.legacyLevel = nil
        await applySelection(resolved)
    }

    private func applySelection(_ seedIds: [String]) async {
        guard seedIds != practiceSeeds || PracticeSelection.stored != seedIds else { return }
        practiceSeeds = seedIds
        PracticeSelection.stored = seedIds
        await practice?.changeSelection(to: seedIds)
    }

    // MARK: - Library (DESIGN.md §2.5, §2.6)

    func refreshLibrary() async throws {
        guard let database else { return }
        library = try await database.libraryStats()
        await resolveSelection()
    }

    /// §2.6: backup, then delete events, progress and sessions. Content stays.
    func clearPracticeRecords() async throws {
        try await resetData { database in try await database.clearPracticeRecords() }
    }

    /// §2.6: backup, delete everything, then import the bundled seeds again.
    func resetDatabase() async throws {
        try await resetData { database in
            try await database.resetAllData()
            try await self.importBundledSeeds()
        }
    }

    private func resetData(_ delete: (AppDatabase) async throws -> Void) async throws {
        guard let database else { return }
        try database.backup()
        practice?.prepareForDataReset()
        defer { phase = .ready }
        do {
            try await delete(database)
        } catch {
            try? await refreshLibrary()
            await practice?.dataWasReset()
            throw error
        }
        try await refreshLibrary()
        await history?.reload()
        await practice?.dataWasReset()
    }
}
