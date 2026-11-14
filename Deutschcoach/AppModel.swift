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

    func start() async {
        guard database == nil else { return }
        do {
            let database = try AppDatabase.openShared()
            self.database = database
            databasePath = database.path
            try await importSeed()
            phase = .ready
        } catch {
            logger.error("Startup failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
        }
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
