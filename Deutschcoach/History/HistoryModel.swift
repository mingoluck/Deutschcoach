import Foundation
import Observation
import os

private nonisolated let logger = Logger(subsystem: "com.ming.Deutschcoach", category: "history")

/// State of the history screen. Missing translations are fetched when a batch is expanded.
@Observable
final class HistoryModel {
    private(set) var batches: [HistoryBatch] = []
    private(set) var translating: Set<Int64> = []
    private(set) var errors: [Int64: String] = [:]
    private(set) var loadError: String?

    private let store: HistoryStore
    private let model: any LanguageModel

    init(database: AppDatabase, model: any LanguageModel) {
        store = HistoryStore(database: database)
        self.model = model
    }

    func reload(language: String = NativeLanguage.current) async {
        do {
            batches = try await store.load(language: language)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func translateIfNeeded(_ batchId: Int64, language: String = NativeLanguage.current) async {
        guard
            let batch = batches.first(where: { $0.id == batchId }),
            batch.missingTranslations,
            !translating.contains(batchId)
        else { return }
        translating.insert(batchId)
        errors[batchId] = nil
        defer { translating.remove(batchId) }
        do {
            try await store.translate(batch, into: language, model: model)
            await reload(language: language)
        } catch {
            logger.error("Translating batch #\(batchId) failed: \(error.localizedDescription, privacy: .public)")
            errors[batchId] = error.localizedDescription
        }
    }
}
