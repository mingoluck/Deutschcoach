import Foundation
import Observation
import os

private nonisolated let logger = Logger(subsystem: "com.ming.Deutschcoach", category: "database")

/// App-wide state. In M1 it opens the database and imports the bundled seed on launch.
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
        guard practice == nil, !Self.isRunningTests else { return }
        let keychain = KeychainStore.apiKey
        let engine = PracticeEngine(
            database: database,
            model: ClaudeLanguageModel(client: ClaudeClient(apiKey: { try keychain.read() }))
        )
        practice = engine
        // Unstructured: not cancelled together with the caller's task.
        Task { await engine.start() }
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
