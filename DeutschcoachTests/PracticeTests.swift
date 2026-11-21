import Foundation
import GRDB
import Testing
@testable import Deutschcoach

/// A settable clock for stores under test.
final class TestClock: @unchecked Sendable {
    var seconds: Double
    init(_ seconds: Double = 0) { self.seconds = seconds }
    var date: Date { Date(timeIntervalSince1970: seconds) }
}

/// Deterministic random source for tests.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Mastery rules (DESIGN.md §3.5)

struct MasteryRulesTests {
    @Test func newSentenceStartsAtTwoPassUpFailDown() {
        #expect(MasteryRules.level(after: []) == 2)
        #expect(MasteryRules.level(after: [.pass]) == 3)
        #expect(MasteryRules.level(after: [.pass, .pass, .fail]) == 3)
        #expect(MasteryRules.level(after: [.pass, .notAttempted, .pass]) == 4)
    }

    @Test func levelsStayWithinOneToSeven() {
        #expect(MasteryRules.level(after: [.fail, .fail, .fail]) == 1)
        #expect(MasteryRules.level(after: Array(repeating: .pass, count: 9)) == 7)
    }

    @Test func modeByLevel() {
        #expect([1, 2].map(MasteryRules.mode(level:)) == [.shadow, .shadow])
        #expect([3, 4].map(MasteryRules.mode(level:)) == [.cloze, .cloze])
        #expect([5, 6, 7].map(MasteryRules.mode(level:)) == [.recall, .recall, .recall])
        // One passed shadowing takes a new sentence to cloze; a failed cloze goes back (§3.5).
        #expect(MasteryRules.mode(level: MasteryRules.level(after: [.pass])) == .cloze)
        #expect(MasteryRules.mode(level: MasteryRules.level(after: [.pass, .fail])) == .shadow)
        #expect(MasteryRules.mode(level: MasteryRules.level(after: [.pass, .pass, .pass, .fail])) == .cloze)
    }
}

// MARK: - Scoring (DESIGN.md §3.4)

struct AnswerMatcherTests {
    private func score(_ de: String, spoken: String? = nil, _ heard: String?, skipped: Bool = false) -> AnswerMatcher.Result {
        AnswerMatcher.score(de: de, spoken: spoken, heard: heard, skipped: skipped)
    }

    @Test func caseAndPunctuationDoNotMatter() {
        #expect(score("Das Auto ist rot.", "das auto ist rot").outcome == .pass)
        #expect(score("Rauchen Sie? – Manchmal.", "Rauchen Sie manchmal").outcome == .pass)
        #expect(score("Er ist groß.", "Er ist gross").outcome == .pass)
    }

    @Test func anyDifferenceFails() {
        let wrong = score("Das Auto ist rot.", "Das Auto ist rat")
        #expect(wrong.outcome == .fail)
        #expect(wrong.mismatched == [3])

        let extra = score("Das Auto ist rot.", "Das Auto ist sehr rot")
        #expect(extra.outcome == .fail)
        #expect(extra.alignment?.extra == ["sehr"])
        #expect(extra.mismatched.isEmpty)

        let missing = score("Das Auto ist rot.", "Das Auto rot")
        #expect(missing.outcome == .fail)
        #expect(missing.mismatched == [2])
    }

    @Test func digitsMatchWordsAndDigits() {
        let de = "Wir fahren um 12 Uhr ab."
        let spoken = "Wir fahren um zwölf Uhr ab."
        #expect(score(de, spoken: spoken, "Wir fahren um zwölf Uhr ab").outcome == .pass)
        #expect(score(de, spoken: spoken, "Wir fahren um 12 Uhr ab").outcome == .pass)
        #expect(score(de, spoken: spoken, "Wir fahren um 12:00 Uhr ab").outcome == .pass)
        #expect(score(de, spoken: spoken, "Wir fahren um elf Uhr ab").outcome == .fail)
    }

    @Test func currencyAndUnitSymbolsAreWords() {
        let de = "Das kostet 20 Euro."
        let spoken = "Das kostet zwanzig Euro."
        #expect(score(de, spoken: spoken, "Das kostet 20 €.").outcome == .pass)
        #expect(score(de, spoken: spoken, "Das kostet 20€").outcome == .pass)
        #expect(score(de, spoken: spoken, "Das kostet zwanzig Euro").outcome == .pass)
        #expect(score(de, spoken: spoken, "Das kostet 20 $").outcome == .fail)
        #expect(score("Es sind 30 Prozent.", spoken: "Es sind dreißig Prozent.", "Es sind 30 %").outcome == .pass)
        #expect(score("Heute sind es 25 Grad.", spoken: "Heute sind es fünfundzwanzig Grad.", "Heute sind es 25°").outcome == .pass)
    }

    @Test func pricesWithCents() {
        let de = "Das macht zusammen 2 Euro 80."
        let spoken = "Das macht zusammen zwei Euro achtzig."
        #expect(score(de, spoken: spoken, "Das macht zusammen 2,80 €").outcome == .pass)
        #expect(score(de, spoken: spoken, "Das macht zusammen 2,80 Euro").outcome == .pass)
        #expect(score(de, spoken: spoken, "Das macht zusammen zwei Euro achtzig").outcome == .pass)
        #expect(score(de, spoken: spoken, "Das macht zusammen 2,90 €").outcome == .fail)
        #expect(score("Das kostet 5 Euro.", spoken: "Das kostet fünf Euro.", "Das kostet 5,00 €").outcome == .pass)
    }

    @Test func unitsAndTheDigitOne() {
        let de = "Ich schwimme jeden Tag einen Kilometer."
        #expect(score(de, "Ich schwimme jeden Tag 1 km").outcome == .pass)
        #expect(score(de, "Ich schwimme jeden Tag einen Kilometer").outcome == .pass)
        // Only the digit is lenient: a wrong article said as a word still fails.
        #expect(score(de, "Ich schwimme jeden Tag eine Kilometer").outcome == .fail)
        #expect(score("Ich brauche ein Kilo Kartoffeln.", "Ich brauche 1 kg Kartoffeln").outcome == .pass)
        #expect(score("Ich möchte zweihundert Gramm Käse.", "Ich möchte 200 g Käse").outcome == .pass)
        #expect(score("Ich trinke jeden Tag zwei Liter Wasser.", "Ich trinke jeden Tag 2 l Wasser").outcome == .pass)
        #expect(score("Der Tisch ist zwei Meter lang.", "Der Tisch ist 2 m lang").outcome == .pass)
        #expect(score("Ich brauche ein Kilogramm Mehl.", "Ich brauche ein Kilo Mehl").outcome == .pass)
        #expect(score("Das kostet elf Euro.", "Das kostet 11 Euro").outcome == .pass)
    }

    @Test func clockTimesAndDecimals() {
        let time = "Das Spiel beginnt um 15.30 Uhr."
        let timeSpoken = "Das Spiel beginnt um fünfzehn Uhr dreißig."
        #expect(score(time, spoken: timeSpoken, "Das Spiel beginnt um 15:30 Uhr").outcome == .pass)
        #expect(score(time, spoken: timeSpoken, "das Spiel beginnt um fünfzehn Uhr dreißig").outcome == .pass)

        let height = "Er ist 1,80 Meter groß."
        let heightSpoken = "Er ist eins achtzig groß."
        #expect(score(height, spoken: heightSpoken, "Er ist 1,80 Meter groß").outcome == .pass)
        #expect(score(height, spoken: heightSpoken, "Er ist eins achtzig groß").outcome == .pass)
    }

    @Test func skippedAndNoSpeechAreNotAttempted() {
        #expect(score("Das Auto ist rot.", nil, skipped: true) == .init(outcome: .notAttempted, reason: .skipped))
        #expect(score("Das Auto ist rot.", nil) == .init(outcome: .notAttempted, reason: .noSpeech))
        #expect(score("Das Auto ist rot.", " . ") == .init(outcome: .notAttempted, reason: .noSpeech))
    }

    @Test func failureShowsTheCloserReading() {
        let result = score("Wir fahren um 12 Uhr ab.", spoken: "Wir fahren um zwölf Uhr ab.", "Wir fahren um zwölf Uhr los")
        #expect(result.outcome == .fail)
        #expect(result.alignment?.words.map(\.text) == ["Wir", "fahren", "um", "zwölf", "Uhr", "ab."])
        #expect(result.mismatched == [5])
    }
}

// MARK: - Session building (DESIGN.md §3.2)

struct SessionBuilderTests {
    private typealias Candidate = SessionBuilder.Candidate

    private func candidate(_ id: Int64, entries: [Int64]? = nil,
                           level: Int? = nil, seenDaysAgo: Double? = nil) -> Candidate {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        return Candidate(
            sentenceId: id,
            entries: entries ?? [id],
            progress: level,
            lastSeenAt: seenDaysAgo.map { Int64(now.timeIntervalSince1970 - $0 * 86_400) }
        )
    }

    private let now = Date(timeIntervalSince1970: 1_000_000_000)

    @Test func atMostFiveNewWhenThereIsEnoughReview() {
        let pool = (1...8).map { candidate($0) } + (11...16).map { candidate($0, level: 2, seenDaysAgo: 1) }
        for seed in 0..<20 {
            var rng = SplitMix64(seed: UInt64(seed))
            let picks = SessionBuilder.pick(from: pool, now: now, using: &rng)
            #expect(picks.count == 10)
            #expect(picks.filter { $0.sentenceId <= 8 }.count <= 5)
            #expect(Set(picks.map(\.sentenceId)).count == picks.count)
        }
    }

    @Test func windowWidensWhenReviewRunsOut() {
        let pool = (1...12).map { candidate($0) }
        var rng = SplitMix64(seed: 1)
        #expect(SessionBuilder.pick(from: pool, now: now, using: &rng).count == 10)
    }

    @Test func onePerEntryUnlessThereIsNoOtherChoice() {
        // Sentences 1–3 share entry 100; ten others have their own entries.
        let shared = (1...3).map { candidate($0, entries: [100]) }
        let others = (11...20).map { candidate($0, level: 2, seenDaysAgo: 2) }
        for seed in 0..<20 {
            var rng = SplitMix64(seed: UInt64(seed))
            let picks = SessionBuilder.pick(from: shared + others, now: now, using: &rng)
            #expect(picks.filter { $0.sentenceId <= 3 }.count <= 1)
        }
        // With nothing else, several sentences of one entry are allowed.
        var rng = SplitMix64(seed: 3)
        #expect(SessionBuilder.pick(from: shared, now: now, using: &rng).count == 3)
    }

    @Test func fewCandidatesGiveAShortSessionWithoutRepeats() {
        let pool = (1...4).map { candidate($0) }
        var rng = SplitMix64(seed: 7)
        let picks = SessionBuilder.pick(from: pool, now: now, using: &rng)
        #expect(picks.map(\.sentenceId).sorted() == [1, 2, 3, 4])
    }

    @Test func modeFollowsTheSentenceLevel() {
        let pool = [
            candidate(1, level: 2, seenDaysAgo: 1),
            candidate(2, entries: [20, 21], level: 3, seenDaysAgo: 1),
            candidate(3, level: 5, seenDaysAgo: 1),
            candidate(4),
        ]
        var rng = SplitMix64(seed: 5)
        let picks = Dictionary(uniqueKeysWithValues: SessionBuilder.pick(from: pool, now: now, using: &rng).map { ($0.sentenceId, $0.mode) })
        #expect(picks == [1: .shadow, 2: .cloze, 3: .recall, 4: .shadow])
    }

    @Test func weakAndStaleSentencesWeighMore() {
        var rng = SplitMix64(seed: 1)
        func average(_ candidate: Candidate) -> Double {
            (0..<200).map { _ in SessionBuilder.weight(of: candidate, now: now, using: &rng) }.reduce(0, +) / 200
        }
        let weakStale = average(candidate(1, level: 1, seenDaysAgo: 14))
        let masteredFresh = average(candidate(2, level: 7, seenDaysAgo: 0))
        let newOne = average(candidate(3))
        let secondStepStale = average(candidate(4, level: 2, seenDaysAgo: 14))
        #expect(weakStale > masteredFresh * 10)
        #expect(abs(newOne - secondStepStale) / secondStepStale < 0.1)
    }

    @Test func baseWeightIsHighOnTheFirstStepOfEachModeAndLowWhenMastered() {
        #expect((1...7).map(SessionBuilder.baseWeight(level:)) == [9, 4, 9, 4, 9, 4, 1])
    }
}

// MARK: - Store (DESIGN.md §2.3, §3.4)

private func seededDatabase() async throws -> AppDatabase {
    let database = try AppDatabase.inMemory()
    try await SeedImporter.importSeed(try Fixture.seed(), origin: .bundled, into: database)
    return database
}

private func sentenceId(_ key: String, in database: AppDatabase) async throws -> Int64 {
    try await database.writer.read { db throws in
        try #require(try Int64.fetchOne(db, sql: "SELECT id FROM sentence WHERE key = ?", arguments: [key]))
    }
}

struct PracticeStoreTests {
    @Test func sessionItemsLoadWithClozeBlanks() async throws {
        let database = try await seededDatabase()
        let store = PracticeStore(database: database)
        let sentence = try await sentenceId("a1.dbg_abfahren.1", in: database)
        let id = try #require(try await store.createSession(seedIds: [Fixture.seedId], picks: [
            .init(sentenceId: sentence, mode: .cloze),
        ]))
        let item = try #require(try await store.nextItem(inSession: id))
        // §3.2: every linked entry is blanked: abfahren (fahren … ab) and Uhr.
        #expect(item.mode == .cloze && item.blanks == [1, 4, 5])
        #expect(item.sentence.key == "a1.dbg_abfahren.1")
        #expect(item.translation(for: "en") == "We leave at twelve o'clock.")
        #expect(item.regional.isEmpty)
        #expect(try await store.progress(ofSession: id) == (0, 1))
        #expect(try await store.createSession(seedIds: [Fixture.seedId], picks: []) == nil)
        #expect(try await database.writer.read { db in try Session.fetchAll(db).map(\.seedIds) } == [[Fixture.seedId]])
    }

    @Test func regionalSentencesCarryTheirEntries() async throws {
        let database = try await seededDatabase()
        let store = PracticeStore(database: database)
        let sentence = try await sentenceId("a1.dbg_parkieren.1", in: database)
        let id = try #require(try await store.createSession(seedIds: [Fixture.seedId], picks: [.init(sentenceId: sentence, mode: .recall)]))
        let item = try #require(try await store.nextItem(inSession: id))
        #expect(item.regional == [RegionalEntry(region: .ch, headword: "parkieren (CH) → D, A: parken")])
        #expect(item.blanks.isEmpty)
    }

    @Test func endingTheActiveSessionKeepsAnsweredItemsOnly() async throws {
        let database = try await seededDatabase()
        let store = PracticeStore(database: database)
        let ids = try await [sentenceId("a1.dbg_rot.1", in: database), sentenceId("a1.dbg_kaffee.1", in: database)]
        let picks: [SessionBuilder.Pick] = ids.map { .init(sentenceId: $0, mode: .shadow) }

        let answered = try #require(try await store.createSession(seedIds: [Fixture.seedId], picks: picks))
        try await store.record(.init(outcome: .pass, mismatched: []), for: try #require(try await store.nextItem(inSession: answered)))
        try await store.endActiveSession()
        try await database.writer.read { db throws in
            let session = try #require(try Session.fetchOne(db, key: answered))
            #expect(session.status == .done && session.finishedAt != nil)
            #expect(try SessionItem.filter(Column("session_id") == answered).fetchCount(db) == 1)
        }

        let untouched = try #require(try await store.createSession(seedIds: [Fixture.seedId], picks: picks))
        try await store.endActiveSession()
        #expect(try await database.writer.read { db in try Session.fetchOne(db, key: untouched) } == nil)
        #expect(try await store.activeSession() == nil)
    }

    @Test func libraryProgressCountsSentencesByStage() async throws {
        let database = try await seededDatabase()
        let keys = ["a1.dbg_rot.1", "a1.dbg_kaffee.1", "a1.dbg_bahnhof.1", "a1.dbg_luft.1", "a1.dbg_luege.1"]
        var ids: [Int64] = []
        for key in keys { ids.append(try await sentenceId(key, in: database)) }
        try await database.writer.write { [ids] db in
            for (id, level) in zip(ids, [1, 2, 3, 6, 7]) {
                try Progress(sentenceId: id, level: level, lastSeenAt: 0).insert(db)
            }
        }
        let progress = try #require(try await PracticeStore(database: database).libraryProgress(seedId: Fixture.seedId))
        #expect(progress.title == "Debug A1")
        #expect(progress.level == .a1)
        #expect(progress.new == 7 && progress.mastered == 1)
        #expect(progress.byLevel == [0, 1, 1, 1, 0, 0, 1, 1])
        #expect(progress.total == 12 && progress.practiced == 5)
        // The five rings (§6): practiced, level ≥ 2, ≥ 4, ≥ 6, 7.
        let rings: [Int] = [progress.practiced, progress.reached(2), progress.reached(4), progress.reached(6), progress.reached(7)]
        #expect(rings == [5, 4, 2, 2, 1])
        #expect(try await PracticeStore(database: database).libraryProgress(seedId: "missing") == nil)
    }

    @Test func recordWritesEventProgressAndStatusTogether() async throws {
        let database = try await seededDatabase()
        let clock = TestClock(1_000)
        let store = PracticeStore(database: database, now: { clock.date })
        let ids = try await [sentenceId("a1.dbg_rot.1", in: database), sentenceId("a1.dbg_kaffee.1", in: database)]
        let session = try #require(try await store.createSession(seedIds: [Fixture.seedId], picks: ids.map { .init(sentenceId: $0, mode: .shadow) }))

        let first = try #require(try await store.nextItem(inSession: session))
        let done = try await store.record(.init(outcome: .pass, heard: "Das Auto ist rot", engine: "test", mismatched: []), for: first)
        #expect(!done)
        clock.seconds = 2_000
        let second = try #require(try await store.nextItem(inSession: session))
        #expect(second.position == 2)
        let finished = try await store.record(.init(outcome: .notAttempted, reason: .skipped, mismatched: []), for: second)
        #expect(finished)

        try await database.writer.read { db throws in
            let progress = try Progress.order(Column("sentence_id")).fetchAll(db)
            #expect(progress == [Progress(sentenceId: ids[0], level: 3, lastSeenAt: 1_000),
                                 Progress(sentenceId: ids[1], level: 2, lastSeenAt: 2_000)])
            let statuses = try SessionItem.order(Column("position")).fetchAll(db).map(\.status)
            #expect(statuses == [.done, .skipped])
            let sessionRow = try #require(try Session.fetchOne(db, key: session))
            #expect(sessionRow.status == .done && sessionRow.finishedAt == 2_000)
            let events = try PracticeEvent.order(Column("id")).fetchAll(db)
            #expect(events.map(\.outcome) == [.pass, .notAttempted])
            #expect(events.allSatisfy { $0.sessionId == session && $0.mode == .shadow })
            let detail = try JSONDecoder().decode(PracticeEventDetail.self, from: Data(try #require(events[1].detail).utf8))
            #expect(detail.reason == .skipped)
        }
    }

    @Test func progressCanBeRecomputedFromEvents() async throws {
        let database = try await seededDatabase()
        let store = PracticeStore(database: database)
        let id = try await sentenceId("a1.dbg_rot.1", in: database)
        let session = try #require(try await store.createSession(seedIds: [Fixture.seedId], picks: [.init(sentenceId: id, mode: .cloze)]))
        let item = try #require(try await store.nextItem(inSession: session))
        try await store.record(.init(outcome: .pass, mismatched: []), for: item)
        let before = try await database.writer.read { db in try Progress.fetchAll(db) }
        try await store.recomputeAllProgress()
        #expect(try await database.writer.read { db in try Progress.fetchAll(db) } == before)
        #expect(before.map(\.level) == [3])
    }

    @Test func pruningKeepsTheTenMostRecentSessionsAndAllEvents() async throws {
        let database = try await seededDatabase()
        let clock = TestClock()
        let store = PracticeStore(database: database, now: { clock.date })
        let id = try await sentenceId("a1.dbg_rot.1", in: database)
        for round in 1...12 {
            clock.seconds = Double(round)
            let session = try #require(try await store.createSession(seedIds: [Fixture.seedId], picks: [.init(sentenceId: id, mode: .shadow)]))
            let item = try #require(try await store.nextItem(inSession: session))
            try await store.record(.init(outcome: .pass, mismatched: []), for: item)
        }
        try await database.writer.read { db throws in
            #expect(try Session.fetchCount(db) == 10)
            #expect(try Session.order(Column("finished_at")).fetchAll(db).first?.finishedAt == 3)
            #expect(try PracticeEvent.fetchCount(db) == 12)
            #expect(try Progress.fetchOne(db, key: id)?.level == 7)
        }
    }
}

// MARK: - Engine (DESIGN.md §3)

final class SilentRecognizer: SpeechRecognizer {
    var engineName: String { "test" }
    func availability() async -> RecognizerAvailability { .ready }
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {}
    func transcribe(_ audio: AsyncStream<AudioChunk>, onVolatile: @escaping @Sendable (String) -> Void) async throws -> Transcript {
        Transcript(text: "", words: [], engine: "test")
    }
}

final class SilentSpeaker: SentenceSpeaker {
    var spoken: [String] = []
    func speak(_ text: String) async { spoken.append(text) }
    func stop() {}
}

@MainActor
struct PracticeEngineTests {
    private func makeEngine(_ database: AppDatabase, seedIds: [String] = [Fixture.seedId], seed: UInt64 = 1) -> PracticeEngine {
        PracticeEngine(database: database, recognizer: SilentRecognizer(), speaker: SilentSpeaker(),
                       seedIds: seedIds, random: SplitMix64(seed: seed))
    }

    /// Answers the current item; `correct` speaks the sentence, otherwise a wrong word.
    private func answer(_ engine: PracticeEngine, correct: Bool = true, skip: Bool = false) async throws {
        let item = try #require(engine.item)
        if skip {
            await engine.skip()
        } else {
            let text = correct ? item.sentence.matchText : item.sentence.matchText + " falsch"
            await engine.submit(heard: text, skipped: false)
        }
        #expect(engine.step == .result)
    }

    @Test func twoFullSessionsInAllThreeModes() async throws {
        let database = try await seededDatabase()
        // One sentence ready for cloze, one for translation (§3.2).
        let clozeId = try await sentenceId("a1.dbg_kaffee.1", in: database)
        let recallId = try await sentenceId("a1.dbg_bahnhof.1", in: database)
        try await database.writer.write { db in
            try Progress(sentenceId: clozeId, level: 3, lastSeenAt: 0).insert(db)
            try Progress(sentenceId: recallId, level: 5, lastSeenAt: 0).insert(db)
        }

        let engine = makeEngine(database)
        var finished = 0
        engine.onSessionFinished = { finished += 1 }
        await engine.start(prepareSpeech: false)
        #expect(engine.status == .practicing)
        #expect(engine.progress.total == 10)  // 12 sentences, the regional one included
        #expect(engine.library?.seedId == Fixture.seedId && engine.library?.total == 12)

        var modes: Set<SentenceMode> = []
        var clozeBlanks: [Int] = []
        for position in 1...10 {
            let item = try #require(engine.item)
            #expect(item.position == position)
            modes.insert(item.mode)
            if item.mode == .cloze { clozeBlanks = item.blanks }
            try await answer(engine, correct: position != 2, skip: position == 3)
            await engine.next()
        }
        #expect(modes == [.shadow, .cloze, .recall])
        #expect(clozeBlanks == [3])  // the Kaffee token
        #expect(finished == 1)

        // Second session starts right after the first.
        #expect(engine.item?.position == 1)
        for _ in 1...10 {
            try await answer(engine)
            await engine.next()
        }
        #expect(finished == 2)

        try await database.writer.read { db throws in
            #expect(try Session.filter(Column("status") == "done").fetchCount(db) == 2)
            #expect(try Session.filter(Column("status") == "active").fetchCount(db) == 1)
            #expect(try PracticeEvent.fetchCount(db) == 20)
            #expect(try PracticeEvent.filter(Column("outcome") == "fail").fetchCount(db) == 1)
        }

        let history = try await HistoryStore(database: database).load()
        #expect(history.count == 2)
        let first = try #require(history.last)
        #expect(first.items.count == 10 && first.passed == 8)
        let failed = try #require(first.items.first { $0.outcome?.result.outcome == .fail })
        #expect(failed.outcome?.result.alignment?.extra == ["falsch"])
        #expect(first.items.contains { $0.outcome?.result.reason == .skipped })
    }

    @Test func resumesTheActiveSessionOnLaunch() async throws {
        let database = try await seededDatabase()
        let first = makeEngine(database)
        await first.start(prepareSpeech: false)
        try await answer(first)
        await first.next()
        let resumedItem = try #require(first.item)

        let second = makeEngine(database, seed: 99)
        await second.start(prepareSpeech: false)
        #expect(second.item == resumedItem)
        #expect(second.progress.answered == 1)
    }

    @Test func emptySelectionShowsNoContentUntilContentArrives() async throws {
        let database = try AppDatabase.inMemory()
        let engine = makeEngine(database)
        await engine.start(prepareSpeech: false)
        #expect(engine.status == .noContent)

        try await SeedImporter.importSeed(try Fixture.seed(), origin: .user, into: database)
        await engine.changeSelection(to: ["missing"])
        #expect(engine.status == .noContent)
        await engine.changeSelection(to: [Fixture.seedId])
        #expect(engine.status == .practicing)
    }

    @Test func libraryChangeStartsPractice() async throws {
        let database = try AppDatabase.inMemory()
        let engine = makeEngine(database)
        await engine.start(prepareSpeech: false)
        try await SeedImporter.importSeed(try Fixture.seed(), origin: .user, into: database)
        await engine.libraryChanged()
        #expect(engine.status == .practicing)
    }

    @Test func selectionChangeEndsTheActiveSessionAndStartsFromTheNewLibraries() async throws {
        let database = try await seededDatabase()
        try await SeedImporter.importSeed(try Fixture.otherSeed(), origin: .user, into: database)
        let engine = makeEngine(database)
        var finished = 0
        engine.onSessionFinished = { finished += 1 }
        await engine.start(prepareSpeech: false)
        try await answer(engine)
        await engine.next()

        await engine.changeSelection(to: [Fixture.otherSeedId])
        #expect(engine.status == .practicing && finished == 1)
        #expect(engine.item?.position == 1 && engine.item?.sentence.seedId == Fixture.otherSeedId)
        #expect(engine.library?.seedId == Fixture.otherSeedId)
        let history = try await HistoryStore(database: database).load()
        #expect(history.count == 1 && history[0].items.count == 1)
        #expect(history[0].libraries == ["Debug A1"])
    }

    @Test func severalLibrariesArePracticedTogether() async throws {
        let database = try await seededDatabase()
        try await SeedImporter.importSeed(try Fixture.otherSeed(), origin: .user, into: database)
        let candidates = try await PracticeStore(database: database).candidates(seedIds: [Fixture.seedId, Fixture.otherSeedId])
        #expect(candidates.count == 24)
        let engine = makeEngine(database, seedIds: [Fixture.seedId, Fixture.otherSeedId])
        await engine.start(prepareSpeech: false)
        let session = try await database.writer.read { db in try Session.fetchOne(db, sql: "SELECT * FROM session WHERE status = 'active'") }
        #expect(session?.seedIds == [Fixture.seedId, Fixture.otherSeedId])
    }

    @Test func dataResetRestartsPractice() async throws {
        let database = try await seededDatabase()
        let engine = makeEngine(database)
        await engine.start(prepareSpeech: false)
        try await answer(engine)
        engine.prepareForDataReset()
        try await database.clearPracticeRecords()
        await engine.dataWasReset()
        #expect(engine.status == .practicing)
        #expect(engine.progress.answered == 0)
    }
}

// MARK: - Checked libraries (DESIGN.md §3.2)

struct PracticeSelectionTests {
    private func seed(_ id: String, _ level: CEFRLevel, _ origin: SeedOrigin = .bundled) -> SeedImport {
        SeedImport(seedId: id, title: id, level: level, version: 1, origin: origin, entryCount: 0, sentenceCount: 0, importedAt: 0)
    }

    private var seeds: [SeedImport] {
        [seed("goethe_b1", .b1), seed("goethe_a2", .a2), seed("debug_a1", .a1, .user), seed("goethe_a1", .a1)]
    }

    @Test func keepsTheStoredIdsThatStillExistInDisplayOrder() {
        #expect(PracticeSelection.resolve(stored: ["goethe_b1", "gone", "goethe_a1"], legacyLevel: "A2", seeds: seeds)
                == ["goethe_a1", "goethe_b1"])
    }

    @Test func checksTheBundledLibrariesOfTheFormerLevel() {
        #expect(PracticeSelection.resolve(stored: nil, legacyLevel: "A2", seeds: seeds) == ["goethe_a2"])
        #expect(PracticeSelection.resolve(stored: ["gone"], legacyLevel: "A1", seeds: seeds) == ["goethe_a1"])
    }

    @Test func fallsBackToTheBundledLibraryOfTheLowestLevel() {
        #expect(PracticeSelection.resolve(stored: nil, legacyLevel: nil, seeds: seeds) == ["goethe_a1"])
        #expect(PracticeSelection.resolve(stored: nil, legacyLevel: "B2", seeds: seeds) == ["goethe_a1"])
        #expect(PracticeSelection.resolve(stored: nil, legacyLevel: nil, seeds: [seed("debug_a1", .a1, .user)]) == ["debug_a1"])
        #expect(PracticeSelection.resolve(stored: ["goethe_a1"], legacyLevel: nil, seeds: []).isEmpty)
    }
}

// MARK: - Library progress rings (DESIGN.md §6)

struct LibraryRingsTests {
    @Test func percentNeverHidesAStartedOrUnfinishedShare() {
        #expect(LibraryRings.percent(count: 0, share: 0) == "0%")
        #expect(LibraryRings.percent(count: 1, share: 1.0 / 4898) == "<1%")
        #expect(LibraryRings.percent(count: 1, share: 0.25) == "25%")
        #expect(LibraryRings.percent(count: 4897, share: 4897.0 / 4898) == "99%")
        #expect(LibraryRings.percent(count: 12, share: 1) == "100%")
    }

    @Test func emptyLibraryHasNoShare() {
        let empty = LibraryProgress(seedId: "x", title: "x", level: .a1)
        #expect(empty.total == 0)
        #expect(empty.share(0) == 0.0)
    }
}
