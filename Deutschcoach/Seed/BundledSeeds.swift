import Foundation
import GRDB
import os

private nonisolated let logger = Logger(subsystem: "com.ming.Deutschcoach", category: "seed")

/// The seeds shipped with the app (DESIGN.md §2.5), kept in `Deutschcoach/SeedData/` and copied
/// to the app's resources. At launch, each one that is newer than its `seed_import` row (or has
/// none) is imported; the user never sees an import step.
nonisolated enum BundledSeeds {
    /// File names without `.json`, which are also the seed ids. A missing file is skipped.
    static let ids = ["goethe_a1", "goethe_a2", "goethe_b1"]

    struct Failure: Sendable, Equatable, Identifiable {
        var seedId: String
        var message: String

        var id: String { seedId }
    }

    struct Outcome: Sendable, Equatable {
        var imported: [SeedImporter.Report] = []
        var failures: [Failure] = []
    }

    /// The bundled seed files that exist, in `ids` order.
    static func urls(in bundle: Bundle = .main) -> [URL] {
        ids.compactMap { bundle.url(forResource: $0, withExtension: "json") }
    }

    /// Imports each seed file whose version is newer than the imported one. A file that cannot
    /// be read or fails validation is skipped and reported; the others are still imported.
    static func importIfNeeded(_ urls: [URL] = urls(), into database: AppDatabase) async -> Outcome {
        var outcome = Outcome()
        for url in urls {
            let name = url.deletingPathExtension().lastPathComponent
            do {
                let data = try Data(contentsOf: url)
                let header = try JSONDecoder().decode(SeedHeaderOnly.self, from: data).seed
                let imported = try await database.writer.read { db in
                    try Int.fetchOne(db, sql: "SELECT version FROM seed_import WHERE seed_id = ?", arguments: [header.id])
                }
                if let imported, imported >= header.version { continue }
                let file = try SeedImporter.decode(data)
                outcome.imported.append(try await SeedImporter.importSeed(file, origin: .bundled, into: database))
            } catch {
                logger.error("Bundled seed \(name, privacy: .public) not imported: \(error.localizedDescription, privacy: .public)")
                outcome.failures.append(Failure(seedId: name, message: error.localizedDescription))
            }
        }
        return outcome
    }
}
