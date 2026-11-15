import Foundation
import Observation
import os

private nonisolated let logger = Logger(subsystem: "com.ming.Deutschcoach", category: "database")

/// App-wide state: opens the database and owns the practice engine, the history, and the
/// settings and library actions. Nothing is imported automatically (DESIGN.md §2.5).
@Observable
final class AppModel {
    enum Phase {
        case starting
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .starting
    private(set) var databasePath: String?
    private(set) var summary = ContentSummary()
    private(set) var library = LibraryStats()
    private(set) var lastImport: SeedImporter.Report?

    private(set) var database: AppDatabase?
    /// The practice engine, owned here so that its work is not tied to a view's lifetime
    /// (a view's `.task` is cancelled when SwiftUI rebuilds or hides the view).
    private(set) var practice: PracticeEngine?
    private(set) var history: HistoryModel?
    private(set) var hasAPIKey = false
    private(set) var nativeLanguage = NativeLanguage.current
    private(set) var userLevel = UserLevel.current

    let speaker = Speaker()
    private let keychain = KeychainStore.apiKey
    private var languageModel: ClaudeLanguageModel {
        let keychain = self.keychain
        return ClaudeLanguageModel(client: ClaudeClient(apiKey: { try keychain.read() }))
    }

    /// Unit tests run inside the app; they must not touch the real database or the API.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func start() async {
        guard database == nil else { return }
        do {
            let database = try AppDatabase.openShared()
            self.database = database
            databasePath = database.path
            try await refreshLibrary()
            phase = .ready
            startPractice(database)
        } catch {
            logger.error("Startup failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
        }
    }

    private func startPractice(_ database: AppDatabase) {
        refreshKeyState()
        guard practice == nil, !Self.isRunningTests else { return }
        history = HistoryModel(database: database, model: languageModel)
        let engine = PracticeEngine(
            database: database, model: languageModel, speaker: speaker,
            nativeLang: nativeLanguage, userLevel: userLevel
        )
        practice = engine
        // Unstructured: not cancelled together with the caller's task.
        Task { await engine.start() }
    }

    // MARK: - Settings (DESIGN.md §6)

    func refreshKeyState() {
        hasAPIKey = ((try? keychain.read()) ?? nil)?.isEmpty == false
    }

    /// Stores the key in the Keychain and checks it at once (§1).
    func saveAPIKey(_ key: String) async throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        try keychain.save(key)
        refreshKeyState()
        await practice?.apiKeyChanged()
    }

    /// Deleting the key blocks practice at once (§1).
    func deleteAPIKey() async throws {
        try keychain.delete()
        refreshKeyState()
        await practice?.apiKeyChanged()
    }

    /// §3.1: discards the current batches and generates a new one in `language`.
    func setNativeLanguage(_ language: String) async {
        guard language != nativeLanguage else { return }
        NativeLanguage.current = language
        nativeLanguage = language
        await practice?.changeLanguage(to: language)
        await history?.reload(language: language)
    }

    /// §3.2: the next batch is generated at `level`; the active batch is finished as is.
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
        summary = try await database.contentSummary()
    }

    /// Reads the picked files and checks them; nothing is written.
    func previewImport(of urls: [URL]) async throws -> SeedImporter.Preview {
        guard let database else { throw CocoaError(.fileReadUnknown) }
        let loaded = await Task.detached { SeedImporter.load(urls: urls) }.value
        return try await SeedImporter.preview(loaded.sources, loadIssues: loaded.issues, database: database)
    }

    func importSeeds(_ preview: SeedImporter.Preview) async throws {
        guard let database, preview.canImport else { return }
        let report = try await SeedImporter.importSeeds(preview.sources, into: database)
        lastImport = report
        logger.info("""
            Imported \(report.files) seed file(s): \(report.elements) elements, \
            \(report.wordForms) forms, \(report.links) links
            """)
        try await refreshLibrary()
        await practice?.libraryChanged()
    }

    /// §2.6: backup, then delete events, mastery and batches. Content stays.
    func clearPracticeRecords() async throws {
        try await resetData { try await $0.clearPracticeRecords() }
    }

    /// §2.6: backup, then delete everything, content included.
    func resetDatabase() async throws {
        try await resetData { try await $0.resetAllData() }
    }

    private func resetData(_ delete: (AppDatabase) async throws -> Void) async throws {
        guard let database else { return }
        try database.backup()
        practice?.prepareForDataReset()
        do {
            try await delete(database)
        } catch {
            await practice?.dataWasReset()
            throw error
        }
        lastImport = nil
        try await refreshLibrary()
        await history?.reload(language: nativeLanguage)
        await practice?.dataWasReset()
    }
}
