import Foundation

/// Per-token drawing instructions for an annotated sentence (DESIGN.md §5.7), following the
/// visual reference page:
///
/// - A constituent's layer is the number of other constituents that strictly contain it
///   (a strictly larger token set that includes all its tokens), capped at 1. Clauses are
///   backgrounds and do not take part.
/// - Each layer is a row of line slots under the words. A constituent is drawn per contiguous
///   run of tokens; only the first run carries the name.
/// - Later spans overwrite earlier ones in the same slot.
nonisolated struct AnnotationLayout: Sendable, Equatable {
    struct BarSlice: Sendable, Equatable {
        /// The raw code, used as the name when the code is unknown.
        var fn: String
        /// `nil` for codes outside the label set (drawn solid, neutral gray).
        var constituent: Constituent?
        /// First / last token of a contiguous run: the line is inset there, leaving a gap.
        var isRunStart: Bool
        var isRunEnd: Bool
        /// Only the start of the span's first run shows the name.
        var showsName: Bool

        var lineStyle: LineStyle { constituent?.lineStyle ?? .solid }
        var color: LabelColor { constituent?.color ?? .neutral }
    }

    struct ClauseSlice: Sendable, Equatable {
        var kind: ClauseKind
        var isStart: Bool
        var isEnd: Bool
    }

    static let maxLevel = 1

    /// Number of line rows under the words (same for every token of the sentence).
    var levelCount: Int
    /// `bars[level][token]`
    var bars: [[BarSlice?]]
    /// `clauses[token]`
    var clauses: [ClauseSlice?]

    init(_ annotation: SentenceAnnotation) {
        let count = annotation.words.count
        let valid = { (index: Int) in index >= 0 && index < count }

        // Every non-clause span is drawn as a line; unknown codes too (in neutral gray).
        let lines = annotation.spans
            .filter { ClauseKind(rawValue: $0.fn) == nil }
            .map { span in (span: span, set: Set(span.tokens.filter(valid))) }
            .filter { !$0.set.isEmpty }

        let levels = lines.indices.map { i in
            let contained = lines.indices.filter { j in
                j != i && lines[j].set.count > lines[i].set.count && lines[i].set.isSubset(of: lines[j].set)
            }.count
            return min(contained, Self.maxLevel)
        }

        levelCount = lines.isEmpty ? 0 : (levels.max() ?? 0) + 1
        var bars = Array(repeating: [BarSlice?](repeating: nil, count: count), count: levelCount)
        for (i, line) in lines.enumerated() {
            for (runIndex, run) in Self.runs(of: line.set).enumerated() {
                for (position, token) in run.enumerated() {
                    bars[levels[i]][token] = BarSlice(
                        fn: line.span.fn,
                        constituent: Constituent(rawValue: line.span.fn),
                        isRunStart: position == 0,
                        isRunEnd: position == run.count - 1,
                        showsName: runIndex == 0 && position == 0
                    )
                }
            }
        }
        self.bars = bars

        var clauses = [ClauseSlice?](repeating: nil, count: count)
        for span in annotation.spans {
            guard let kind = ClauseKind(rawValue: span.fn) else { continue }
            let tokens = Set(span.tokens.filter(valid)).sorted()
            for (position, token) in tokens.enumerated() {
                clauses[token] = ClauseSlice(kind: kind, isStart: position == 0, isEnd: position == tokens.count - 1)
            }
        }
        self.clauses = clauses
    }

    /// Contiguous runs of token indices, in order: {1, 2, 5} → [[1, 2], [5]].
    static func runs(of tokens: Set<Int>) -> [[Int]] {
        var runs: [[Int]] = []
        for token in tokens.sorted() {
            if let last = runs.last?.last, last == token - 1 {
                runs[runs.count - 1].append(token)
            } else {
                runs.append([token])
            }
        }
        return runs
    }
}
