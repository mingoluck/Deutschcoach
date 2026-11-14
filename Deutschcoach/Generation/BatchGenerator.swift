import Foundation
import GRDB
import os

private nonisolated let logger = Logger(subsystem: "com.ming.Deutschcoach", category: "generation")

/// Generates one batch of sentences and stores it (DESIGN.md §3.1, §4.3, §4.4).
///
/// 1. Insert a `generating` batch.
/// 2. Ask the model for all positions, validate each sentence, and re-request only the
///    positions that failed — at most `maxRefillRounds` more times.
/// 3. Store the valid sentences with their targets and incidental vocabulary in one
///    transaction and mark the batch `ready`; fewer than requested is accepted.
/// On a model error, or with no valid sentence at all, the batch is deleted and the error thrown.
nonisolated struct BatchGenerator: Sendable {
    enum Event: Sendable, Equatable {
        case requesting(round: Int, positions: [Int])
        case accepted(position: Int)
        case rejected(ValidationFailure)
    }

    struct Report: Sendable, Equatable {
        var batchId: Int64
        var storedPositions: [Int]
        var failures: [ValidationFailure]
        var rounds: Int
        var usage: TokenUsage
    }

    enum GenerationError: Error, LocalizedError, Equatable {
        case noValidSentences([ValidationFailure])

        var errorDescription: String? {
            switch self {
            case .noValidSentences(let failures):
                "No valid sentence was generated. Last failures: "
                    + failures.map { "#\($0.position) \($0.reason)" }.joined(separator: "; ")
            }
        }
    }

    var database: AppDatabase
    var model: any LanguageModel
    var maxRefillRounds = 2
    var now: @Sendable () -> Date = { Date() }

    func generate(_ request: GenerationRequest, onEvent: @Sendable (Event) -> Void = { _ in }) async throws -> Report {
        let batchId = try await createBatch(request)
        do {
            return try await fill(batchId: batchId, request: request, onEvent: onEvent)
        } catch {
            // §3.1: a failed generation deletes its batch (sentences cascade).
            try? await database.writer.write { db in
                _ = try Batch.deleteOne(db, key: batchId)
            }
            throw error
        }
    }

    // MARK: - Steps

    private func createBatch(_ request: GenerationRequest) async throws -> Int64 {
        let createdAt = Int64(now().timeIntervalSince1970)
        let model = self.model.modelName
        return try await database.writer.write { db in
            var batch = Batch(status: .generating, nativeLang: request.nativeLang, model: model, createdAt: createdAt)
            try batch.insert(db)
            return batch.id!
        }
    }

    private func fill(batchId: Int64, request: GenerationRequest, onEvent: @Sendable (Event) -> Void) async throws -> Report {
        let vocabIds = request.sentences.flatMap(\.targets).filter { $0.kind == .vocab }.map(\.elementId)
        let lexicon = try await database.writer.read { db in try VocabLexicon.load(elementIds: vocabIds, from: db) }
        let validator = SentenceValidator(lexicon: lexicon)

        var pending = request.sentences
        var accepted: [Int: ValidatedSentence] = [:]
        var failures: [Int: ValidationFailure] = [:]
        var usage = TokenUsage()
        var rounds = 0

        while !pending.isEmpty, rounds <= maxRefillRounds {
            rounds += 1
            onEvent(.requesting(round: rounds, positions: pending.map(\.position)))
            var roundRequest = request
            roundRequest.sentences = pending
            let response = try await model.generateSentences(roundRequest)
            usage = usage + response.usage

            let returned = Dictionary(response.sentences.map { ($0.position, $0) }, uniquingKeysWith: { first, _ in first })
            let malformed = Dictionary(response.malformed.compactMap { m in m.position.map { ($0, m.reason) } }, uniquingKeysWith: { a, _ in a })
            for sentenceRequest in pending {
                let result: Result<ValidatedSentence, ValidationFailure>
                if let sentence = returned[sentenceRequest.position] {
                    result = validator.validate(sentence, for: sentenceRequest)
                } else {
                    let reason = malformed[sentenceRequest.position] ?? "not returned"
                    result = .failure(ValidationFailure(position: sentenceRequest.position, reason: reason))
                }
                switch result {
                case .success(let sentence):
                    accepted[sentenceRequest.position] = sentence
                    failures[sentenceRequest.position] = nil
                    onEvent(.accepted(position: sentenceRequest.position))
                case .failure(let failure):
                    failures[sentenceRequest.position] = failure
                    logger.info("Rejected #\(failure.position): \(failure.reason, privacy: .public)")
                    onEvent(.rejected(failure))
                }
            }
            pending.removeAll { accepted[$0.position] != nil }
        }

        let finalFailures = failures.values.sorted { $0.position < $1.position }
        guard !accepted.isEmpty else { throw GenerationError.noValidSentences(finalFailures) }

        let sentences = accepted.values.sorted { $0.request.position < $1.request.position }
        try await store(sentences, batchId: batchId, nativeLang: request.nativeLang)
        return Report(
            batchId: batchId,
            storedPositions: sentences.map(\.request.position),
            failures: finalFailures,
            rounds: rounds,
            usage: usage
        )
    }

    /// §4.4, in one transaction. Positions keep the requested numbers; missing ones leave gaps.
    private func store(_ sentences: [ValidatedSentence], batchId: Int64, nativeLang: String) async throws {
        let createdAt = Int64(now().timeIntervalSince1970)
        let modelName = model.modelName
        try await database.writer.write { db in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            func json(_ value: some Encodable) throws -> String {
                String(decoding: try encoder.encode(value), as: UTF8.self)
            }

            for validated in sentences {
                var sentence = Sentence(
                    batchId: batchId,
                    position: validated.request.position,
                    mode: validated.request.mode,
                    status: .pending,
                    de: validated.de,
                    translations: try json([nativeLang: validated.translation]),
                    annotation: try json(validated.annotation),
                    blanks: nil,  // cloze blanks are chosen in M5
                    model: modelName,
                    createdAt: createdAt,
                    flagged: false
                )
                try sentence.insert(db)
                let sentenceId = sentence.id!

                let targetIds = Set(validated.targets.map(\.elementId))
                for target in validated.targets {
                    try SentenceElement(sentenceId: sentenceId, elementId: target.elementId, role: .target, tokens: try json(target.tokens)).insert(db)
                }
                for (elementId, tokens) in try Self.incidentalVocabulary(in: validated.annotation, excluding: targetIds, db: db) {
                    try SentenceElement(sentenceId: sentenceId, elementId: elementId, role: .incidental, tokens: try json(tokens)).insert(db)
                }
            }
            try db.execute(sql: "UPDATE batch SET status = 'ready' WHERE id = ?", arguments: [batchId])
        }
    }

    /// Words that match a library entry by lemma + POS (§4.4), grouped by element.
    /// Unmatched words are not turned into candidate elements for now.
    static func incidentalVocabulary(in annotation: SentenceAnnotation, excluding targets: Set<Int64>, db: Database) throws -> [(Int64, [Int])] {
        var tokensByElement: [Int64: [Int]] = [:]
        for (index, token) in annotation.words.enumerated() where !token.isPunctuation && !token.lemma.isEmpty {
            let ids = try Int64.fetchAll(db, sql: """
                SELECT v.element_id FROM vocab_detail v JOIN element e ON e.id = v.element_id
                WHERE v.lemma = ? COLLATE NOCASE AND v.pos = ? AND e.status != 'retired'
                """, arguments: [token.lemma, token.pos])
            for id in ids where !targets.contains(id) {
                tokensByElement[id, default: []].append(index)
            }
        }
        return tokensByElement.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}
