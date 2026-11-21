import SwiftUI

/// A library's progress as one bar, segmented by stage of the mastery ladder (DESIGN.md §6):
/// mastered, translation, cloze and shadowing from strong to light; new sentences are the track.
struct LibraryProgressBar: View {
    let progress: LibraryProgress

    var body: some View {
        GeometryReader { geometry in
            let total = max(progress.total, 1)
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    Rectangle()
                        .fill(Color.accentColor.opacity(segment.opacity))
                        .frame(width: geometry.size.width * CGFloat(segment.count) / CGFloat(total))
                }
                Spacer(minLength: 0)
            }
            .background(Color.secondary.opacity(0.15))
            .clipShape(Capsule())
        }
        .frame(height: 6)
        .help(StageCounts(progress: progress).text)
        .accessibilityElement()
        .accessibilityLabel(StageCounts(progress: progress).text)
    }

    private var segments: [(count: Int, opacity: Double)] {
        [(progress.mastered, 1), (progress.recall, 0.65), (progress.cloze, 0.4), (progress.shadow, 0.2)]
    }
}

/// “Mastered X / N”, with the counts of every stage in a tooltip (DESIGN.md §6).
struct MasteredLabel: View {
    let progress: LibraryProgress

    var body: some View {
        Text("Mastered \(progress.mastered) / \(progress.total)")
            .monospacedDigit()
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(StageCounts(progress: progress).text)
    }
}

private struct StageCounts {
    let progress: LibraryProgress

    var text: Text {
        Text("New \(progress.new) · Shadowing \(progress.shadow) · Cloze \(progress.cloze) · Translation \(progress.recall) · Mastered \(progress.mastered)")
    }
}

/// The tag of a sentence with Austrian or Swiss entries (DESIGN.md §3.3); after answering it
/// also shows the headwords with the list's cross-reference.
struct RegionalTag: View {
    let entries: [RegionalEntry]
    let showsHeadwords: Bool

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ForEach(regions, id: \.self) { region in
                        Text(region.displayName)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                if showsHeadwords {
                    ForEach(entries, id: \.self) { entry in
                        Text(verbatim: entry.headword)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var regions: [Region] {
        var seen: [Region] = []
        for entry in entries where !seen.contains(entry.region) { seen.append(entry.region) }
        return seen
    }
}

extension Region {
    /// UI name, localized by the view's locale.
    var displayName: LocalizedStringKey {
        switch self {
        case .a: "Austrian usage"
        case .ch: "Swiss usage"
        }
    }
}
