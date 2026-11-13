import SwiftUI

/// Which visual layers are drawn (the reference page's layer switches).
struct AnnotationLayers: Equatable {
    var caseColors = true
    var partOfSpeech = true
    var constituents = true
    var clauses = true
}

extension LabelColor {
    var color: Color {
        switch self {
        case .nom: .caseNom
        case .acc: .caseAcc
        case .dat: .caseDat
        case .gen: .caseGen
        case .ink: .ink
        case .slate: .slate
        case .neutral: .secondaryText
        }
    }
}

/// An annotated German sentence (DESIGN.md §5): case colors, part-of-speech text, constituent
/// lines and clause backgrounds. Measurements follow the visual reference page.
struct AnnotatedSentenceView: View {
    let annotation: SentenceAnnotation
    /// Token indices shown as cloze blanks (DESIGN.md §3.3).
    var blanks: Set<Int>
    var layers: AnnotationLayers
    var labels: LabelCatalog
    private let layout: AnnotationLayout

    init(
        _ annotation: SentenceAnnotation,
        blanks: Set<Int> = [],
        layers: AnnotationLayers = AnnotationLayers(),
        labels: LabelCatalog = LabelCatalog(language: NativeLanguage.current)
    ) {
        self.annotation = annotation
        self.blanks = blanks
        self.layers = layers
        self.labels = labels
        layout = AnnotationLayout(annotation)
    }

    var body: some View {
        WordFlowLayout(rowSpacing: 26) {
            ForEach(annotation.words.indices, id: \.self) { index in
                WordCell(
                    token: annotation.words[index],
                    index: index,
                    layout: layout,
                    isBlank: blanks.contains(index),
                    layers: layers,
                    labels: labels
                )
            }
        }
        .padding(.top, 12)  // room for clause tags above the first row
    }
}

// MARK: - Word cell

/// One vertical unit: word (case color) → small text (POS · case/form) → constituent line slots.
private struct WordCell: View {
    let token: AnnotationToken
    let index: Int
    let layout: AnnotationLayout
    let isBlank: Bool
    let layers: AnnotationLayers
    let labels: LabelCatalog

    private var caseColor: Color? {
        guard layers.caseColors, let grammaticalCase = GrammaticalCase(rawValue: token.feature) else { return nil }
        return LabelColor(grammaticalCase).color
    }

    private var clause: AnnotationLayout.ClauseSlice? {
        layers.clauses ? layout.clauses[index] : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                word
                    .frame(height: 32)
                smallText
                    .frame(height: 14)
                    .padding(.top, 2)
                    .padding(.bottom, 8)
                    .opacity(layers.partOfSpeech ? 1 : 0)
            }
            .padding(.horizontal, 5)
            .padding(.top, 4)
            .padding(.bottom, 2)

            ForEach(0..<layout.levelCount, id: \.self) { level in
                LineSlot(slice: layout.bars[level][index], labels: labels)
                    .frame(height: 25)
                    .opacity(layers.constituents ? 1 : 0)
            }
        }
        .background { clauseBackground }
        .overlay(alignment: .topLeading) { clauseTag }
    }

    @ViewBuilder
    private var word: some View {
        if isBlank {
            // Dashed box sized to the word, in the case color (reference: .blank).
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .foregroundStyle(caseColor ?? (layers.caseColors ? .ink : .secondaryText))
                .frame(width: (CGFloat(token.form.count) * 0.6 + 0.6) * 24, height: 26.4)
        } else {
            Text(token.form)
                .font(.system(size: 24, weight: token.isPunctuation ? .medium : .semibold))
                .foregroundStyle(token.isPunctuation ? Color.secondaryText : (caseColor ?? .ink))
                .fixedSize()
        }
    }

    @ViewBuilder
    private var smallText: some View {
        if !isBlank, let pos = labels.partOfSpeech(token) {
            Group {
                if let feature = labels.feature(token) {
                    if GrammaticalCase(rawValue: token.feature) != nil {
                        Text("\(pos) · \(Text(feature).fontWeight(.semibold).foregroundStyle(caseColor ?? .secondaryText))")
                    } else {
                        Text("\(pos) · \(feature)")
                    }
                } else {
                    Text(pos)
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(Color.secondaryText)
            .fixedSize()
        } else {
            Color.clear.frame(width: 0)
        }
    }

    @ViewBuilder
    private var clauseBackground: some View {
        if let clause {
            let start: CGFloat = clause.isStart ? 10 : 0
            let end: CGFloat = clause.isEnd ? 10 : 0
            UnevenRoundedRectangle(
                topLeadingRadius: start, bottomLeadingRadius: start,
                bottomTrailingRadius: end, topTrailingRadius: end
            )
            .fill(Color.clauseBackground)
        }
    }

    @ViewBuilder
    private var clauseTag: some View {
        if let clause, clause.isStart {
            Text(labels.clauseName(clause.kind))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.secondaryText)
                .fixedSize()
                .offset(x: 6, y: -15)
        }
    }
}

// MARK: - Constituent line

/// One line slot under a word: this word's piece of a constituent line, plus the name at the start.
private struct LineSlot: View {
    let slice: AnnotationLayout.BarSlice?
    let labels: LabelCatalog

    var body: some View {
        if let slice {
            let color = slice.color.color
            Canvas { context, size in
                let start: CGFloat = slice.isRunStart ? 3 : 0
                let end = size.width - (slice.isRunEnd ? 3 : 0)
                for rect in Self.pieces(of: slice.lineStyle, from: start, to: end) {
                    let radius: CGFloat = switch slice.lineStyle {
                    case .solid: 2
                    case .thin: 1
                    default: 0
                    }
                    context.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(color))
                }
            }
            .overlay(alignment: .topLeading) {
                if slice.showsName {
                    Text(labels.constituentName(slice.fn))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(color)
                        .fixedSize()
                        .offset(x: 3, y: 9)
                }
            }
        } else {
            Color.clear
        }
    }

    /// Rectangles that make up a line style between `start` and `end` (reference: .bar.st-*).
    static func pieces(of style: LineStyle, from start: CGFloat, to end: CGFloat) -> [CGRect] {
        let width = max(end - start, 0)
        switch style {
        case .solid:
            return [CGRect(x: start, y: 2, width: width, height: 4)]
        case .thin:
            return [CGRect(x: start, y: 3, width: width, height: 2)]
        case .double:
            return [CGRect(x: start, y: 1, width: width, height: 2), CGRect(x: start, y: 5, width: width, height: 2)]
        case .dashed, .dotted:
            let (on, off): (CGFloat, CGFloat) = style == .dashed ? (8, 4) : (3, 3)
            var rects: [CGRect] = []
            var x = start
            while x < end {
                rects.append(CGRect(x: x, y: 2, width: min(on, end - x), height: 4))
                x += on + off
            }
            return rects
        }
    }
}

// MARK: - Flow layout

/// Wraps word cells into rows (DESIGN.md §5.7). Cells sit edge to edge; their own padding
/// provides the word spacing, so constituent lines of consecutive words connect.
struct WordFlowLayout: Layout {
    var rowSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, maxWidth: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews, maxWidth: bounds.width)
        for (subview, frame) in zip(subviews, arrangement.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(_ subviews: Subviews, maxWidth: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + rowSpacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x)
        }
        return (frames, CGSize(width: widest, height: y + rowHeight))
    }
}
