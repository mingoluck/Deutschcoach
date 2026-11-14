import Foundation
import Observation
import os

private nonisolated let logger = Logger(subsystem: "com.ming.Deutschcoach", category: "database")

/// App-wide state: opens the database, imports the bundled seed, and owns the practice engine,
/// the history and the settings actions.
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
    private(set) var lastImport: SeedImporter.Report?

    private(set) var database: AppDatabase?
    /// The practice engine, owned here so that its work is not tied to a view's lifetime
    /// (a view's `.task` is cancelled when SwiftUI rebuilds or hides the view).
    private(set) var practice: PracticeEngine?
    private(set) var history: HistoryModel?
    private(set) var hasAPIKey = false
    private(set) var nativeLanguage = NativeLanguage.current

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
            try await importSeed()
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
        let engine = PracticeEngine(database: database, model: languageModel, speaker: speaker, nativeLang: nativeLanguage)
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

    func reimportSeed() async {
        do {
            try await importSeed()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func importSeed() async throws {
        guard let database else { return }
        let seed = try SeedImporter.loadBundledSeed()
        let report = try await SeedImporter.importSeed(seed, into: database)
        lastImport = report
        summary = try await database.contentSummary()
        logger.info("""
            Seed imported into \(database.path, privacy: .public): \
            \(report.elements) elements, \(report.wordForms) forms, \(report.links) links; \
            database now has \(self.summary.totalElements) elements, \
            \(self.summary.wordForms) forms, \(self.summary.links) links
            """)
    }
}
