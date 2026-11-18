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
    private(set) var userLevel = UserLevel.current

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
        let history = HistoryModel(database: database)
        self.history = history
        let engine = PracticeEngine(database: database, speaker: speaker, userLevel: userLevel)
        engine.onSessionFinished = { Task { await history.reload() } }
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

    /// §3.1: the next session uses the new level.
    func setUserLevel(_ level: CEFRLevel) async {
        guard level != userLevel else { return }
        UserLevel.current = level
        userLevel = level
        await practice?.changeLevel(to: level)
    }

    // MARK: - Library (DESIGN.md §2.5, §2.6)

    func refreshLibrary() async throws {
        guard let database else { return }
        library = try await database.libraryStats()
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

    #if DEBUG
    /// Debug builds: imports the small debug seed so practice can be tried without real content.
    func loadDebugSeed() async throws {
        guard let database else { return }
        let file = try SeedImporter.decode(DebugSeed.data)
        try await SeedImporter.importSeed(file, origin: .user, into: database)
        try await refreshLibrary()
        await practice?.libraryChanged()
    }
    #endif
}
