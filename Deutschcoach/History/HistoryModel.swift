import Foundation
import Observation

/// State of the history screen (DESIGN.md §6).
@Observable
final class HistoryModel {
    private(set) var sessions: [HistorySession] = []
    private(set) var loadError: String?
    private let store: HistoryStore

    init(database: AppDatabase) {
        store = HistoryStore(database: database)
    }

    func reload() async {
        do {
            sessions = try await store.load()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}
