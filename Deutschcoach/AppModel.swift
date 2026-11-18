import Foundation
import Observation
import os

private nonisolated let logger = Logger(subsystem: "com.ming.Deutschcoach", category: "database")

/// App-wide state: opens the database, imports the bundled seeds (DESIGN.md §2.5), and owns the
/// settings and library actions. The practice engine and the history return in M9.
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
    private(set) var hasAPIKey = false
    private(set) var nativeLanguage = NativeLanguage.current
    private(set) var userLevel = UserLevel.current

    let speaker = Speaker()
    private let keychain = KeychainStore.apiKey

    func start() async {
        guard database == nil else { return }
        do {
            let database = try AppDatabase.openShared()
            self.database = database
            databasePath = database.path
            try await importBundledSeeds()
            phase = .ready
        } catch {
            logger.error("Startup failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
        }
        refreshKeyState()
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

    func refreshKeyState() {
        hasAPIKey = ((try? keychain.read()) ?? nil)?.isEmpty == false
    }

    func saveAPIKey(_ key: String) async throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        try keychain.save(key)
        refreshKeyState()
    }

    func deleteAPIKey() async throws {
        try keychain.delete()
        refreshKeyState()
    }

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
    }

    // MARK: - Library (DESIGN.md §2.5, §2.6)

    func refreshLibrary() async throws {
        guard let database else { return }
        library = try await database.libraryStats()
    }

    /// §2.6: backup, then delete events, progress and sessions. Content stays.
    func clearPracticeRecords() async throws {
        guard let database else { return }
        try database.backup()
        try await database.clearPracticeRecords()
        try await refreshLibrary()
    }

    /// §2.6: backup, delete everything, then import the bundled seeds again.
    func resetDatabase() async throws {
        guard let database else { return }
        try database.backup()
        try await database.resetAllData()
        do {
            try await importBundledSeeds()
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
            throw error
        }
    }
}
