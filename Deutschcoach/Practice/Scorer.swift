import Foundation

/// Scoring of answers (DESIGN.md §3.4). Pure functions; the judge call and writing happen in the
/// practice engine.
nonisolated enum Scorer {
    // MARK: - Shadowing

    struct ShadowResult: Sendable, Equatable {
        var alignment: Alignment?
        var events: [EventDraft]
    }

    /// One `pronunciation` event per vocabulary or pattern element in the sentence (targets and
    /// incidental): `pass` when all its tokens were heard, `fail` otherwise. Grammar points get
    /// no event. Without speech, or when skipped, every element is `not_attempted`.
    static func scoreShadow(_ item: PracticeItem, heard: String?, skipped: Bool = false) -> ShadowResult {
        let elements = item.elements.filter { $0.kind != .grammar }
        guard !skipped, let heard, hasSpeech(heard) else {
            let reason: NotAttemptedReason = skipped ? .skipped : .noSpeech
            return ShadowResult(alignment: nil, events: elements.map {
                EventDraft(elementId: $0.id, dimension: .pronunciation, outcome: .notAttempted, reason: reason)
            })
        }
        let alignment = align(item, heard: heard)
        let events = elements.map { element in
            EventDraft(
                elementId: element.id,
                dimension: .pronunciation,
                outcome: allMatched(element.tokens, in: alignment) ? .pass : .fail
            )
        }
        return ShadowResult(alignment: alignment, events: events)
    }

    // MARK: - Cloze and recall

    enum LocalResult: Sendable, Equatable {
        /// All target elements correct: every target passes.
        case pass([EventDraft])
        /// No valid speech or skipped: every target is `not_attempted`.
        case notAttempted([EventDraft])
        /// Everything else goes to the LLM judge.
        case needsJudge
    }

    /// §3.4 steps ① and ②.
    static func scoreLocally(_ item: PracticeItem, heard: String?, skipped: Bool = false) -> LocalResult {
        let targets = item.targets
        guard !skipped, let heard, hasSpeech(heard) else {
            let reason: NotAttemptedReason = skipped ? .skipped : .noSpeech
            return .notAttempted(targets.map { EventDraft(elementId: $0.id, dimension: .recall, outcome: .notAttempted, reason: reason) })
        }
        let alignment = align(item, heard: heard)
        let heardWords = WordAligner.words(in: heard)
        let allCorrect = targets.allSatisfy { target in
            target.kind == .vocab
                ? vocabularyHeard(target, in: heardWords)
                : allMatched(target.tokens, in: alignment)
        }
        guard allCorrect else { return .needsJudge }
        return .pass(targets.map { EventDraft(elementId: $0.id, dimension: .recall, outcome: .pass) })
    }

    /// §3.4 judge table.
    static func events(from verdict: JudgeVerdict, targets: [PracticeItem.ItemElement]) -> [EventDraft] {
        targets.map { target in
            if verdict.confidence == .low {
                return EventDraft(elementId: target.id, dimension: .recall, outcome: .notAttempted, reason: .unclear)
            }
            if !verdict.valid {
                return EventDraft(elementId: target.id, dimension: .recall, outcome: .fail)
            }
            return verdict.targetsUsed.contains(target.id)
                ? EventDraft(elementId: target.id, dimension: .recall, outcome: .pass)
                : EventDraft(elementId: target.id, dimension: .recall, outcome: .notAttempted, reason: .paraphrase)
        }
    }

    static func judgeRequest(for item: PracticeItem, heard: String, nativeLang: String) -> JudgeRequest {
        JudgeRequest(
            mode: item.mode,
            translation: item.translation(for: nativeLang),
            reference: item.sentence.de,
            targets: item.targets.map { JudgeRequest.Target(elementId: $0.id, title: $0.title) },
            answer: heard
        )
    }

    // MARK: - Helpers

    /// Whether the transcription contains at least one word.
    static func hasSpeech(_ heard: String) -> Bool {
        !WordAligner.words(in: heard).isEmpty
    }

    static func align(_ item: PracticeItem, heard: String) -> Alignment {
        WordAligner.align(target: item.annotation.words.map(\.form), heard: heard)
    }

    /// Lenient vocabulary check: any known form of the lemma was said. A separable verb also
    /// needs its prefix, either as a word of its own or as part of the form (`aufstehen`).
    static func vocabularyHeard(_ element: PracticeItem.ItemElement, in heardWords: [String]) -> Bool {
        let matches = heardWords.filter { element.forms.contains($0) }
        guard let prefix = element.separablePrefix, !prefix.isEmpty else { return !matches.isEmpty }
        return matches.contains { $0.hasPrefix(prefix) }
            || (!matches.isEmpty && heardWords.contains(prefix))
    }

    /// Whether every (non-punctuation) token was matched. Tokens without letters are not part of
    /// the alignment and count as matched.
    static func allMatched(_ tokens: [Int], in alignment: Alignment) -> Bool {
        let status = Dictionary(alignment.words.map { ($0.index, $0.status) }, uniquingKeysWith: { a, _ in a })
        return tokens.allSatisfy { index in status[index].map { $0 == .match } ?? true }
    }
}
