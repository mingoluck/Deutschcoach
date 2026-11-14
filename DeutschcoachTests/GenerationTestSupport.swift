import Foundation
import GRDB
import Synchronization
@testable import Deutschcoach

/// An in-memory database with the bundled A1 seed imported.
func makeSeededDatabase() async throws -> AppDatabase {
    let database = try AppDatabase.inMemory()
    try await SeedImporter.importSeed(try SeedImporter.loadBundledSeed(), into: database)
    return database
}

func elementId(_ key: String, in database: AppDatabase) async throws -> Int64 {
    try await database.writer.read { db in
        try Int64.fetchOne(db, sql: "SELECT id FROM element WHERE key = ?", arguments: [key])!
    }
}

/// Seed ids used by the template sentence "Ich gebe den Kindern einen Apfel."
struct TemplateIds {
    var geben: Int64
    var kind: Int64
    var dativ: Int64

    init(_ database: AppDatabase) async throws {
        geben = try await elementId("vocab.geben.verb", in: database)
        kind = try await elementId("vocab.kind.noun", in: database)
        dativ = try await elementId("gram.dat.indirect_obj", in: database)
    }

    var targets: [GenerationTarget] {
        [
            GenerationTarget(elementId: geben, kind: .vocab, title: "geben"),
            GenerationTarget(elementId: kind, kind: .vocab, title: "das Kind"),
            GenerationTarget(elementId: dativ, kind: .grammar, title: "Dativ: indirektes Objekt"),
        ]
    }

    func request(positions: ClosedRange<Int> = 1...10) -> GenerationRequest {
        GenerationRequest(
            nativeLang: "zh",
            userLevel: .a1,
            sentences: positions.map { SentenceRequest(position: $0, mode: .shadow, targets: targets) }
        )
    }

    func sentence(position: Int) -> GeneratedSentence {
        GeneratedSentence(
            position: position,
            de: "Ich gebe den Kindern einen Apfel.",
            translation: "我给孩子们一个苹果。",
            words: [
                ["Ich", "ich", "PRON", "Nom"],
                ["gebe", "geben", "VERB", "Fin"],
                ["den", "der", "DET", "Dat"],
                ["Kindern", "Kind", "NOUN", "Dat", "Neut|Plur"],
                ["einen", "ein", "DET", "Acc"],
                ["Apfel", "Apfel", "NOUN", "Acc", "Masc"],
                [".", "", "PUNCT", ""],
            ],
            spans: [
                AnnotationSpan(fn: "Subj", tokens: [0]),
                AnnotationSpan(fn: "Pred", tokens: [1]),
                AnnotationSpan(fn: "ObjDat", tokens: [2, 3]),
                AnnotationSpan(fn: "ObjAcc", tokens: [4, 5]),
            ],
            targets: [
                TargetTokens(elementId: geben, tokens: [1]),
                TargetTokens(elementId: kind, tokens: [3]),
                TargetTokens(elementId: dativ, tokens: [2, 3]),
            ]
        )
    }
}

/// A scripted `LanguageModel`: `respond` gets each request and the 1-based call number.
final class FakeLanguageModel: LanguageModel, @unchecked Sendable {
    let modelName = "fake-model"
    private let respond: @Sendable (GenerationRequest, Int) throws -> GenerationResponse
    private let verdict: @Sendable (JudgeRequest) throws -> JudgeVerdict
    private let calls = Mutex<[GenerationRequest]>([])
    private let judgeCalls = Mutex<[JudgeRequest]>([])

    init(
        judge: @escaping @Sendable (JudgeRequest) throws -> JudgeVerdict = { _ in JudgeVerdict(valid: true, confidence: .high, targetsUsed: []) },
        _ respond: @escaping @Sendable (GenerationRequest, Int) throws -> GenerationResponse
    ) {
        self.respond = respond
        self.verdict = judge
    }

    var requests: [GenerationRequest] { calls.withLock { $0 } }
    var judgeRequests: [JudgeRequest] { judgeCalls.withLock { $0 } }

    /// Thrown by `verifyAccess` when set.
    let accessError = Mutex<LLMError?>(nil)
    func verifyAccess() async throws {
        if let error = accessError.withLock({ $0 }) { throw error }
    }

    private let translations = Mutex<[TranslationRequest]>([])
    var translationRequests: [TranslationRequest] { translations.withLock { $0 } }

    /// Translates each sentence as "<lang>: <German>".
    func translate(_ request: TranslationRequest) async throws -> [Int64: String] {
        translations.withLock { $0.append(request) }
        return Dictionary(uniqueKeysWithValues: request.sentences.map { ($0.id, "\(request.nativeLang): \($0.de)") })
    }

    func judge(_ request: JudgeRequest) async throws -> JudgeVerdict {
        judgeCalls.withLock { $0.append(request) }
        return try verdict(request)
    }

    func generateSentences(_ request: GenerationRequest) async throws -> GenerationResponse {
        let number = calls.withLock { calls in
            calls.append(request)
            return calls.count
        }
        return try respond(request, number)
    }
}
