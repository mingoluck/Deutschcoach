import SwiftUI

/// A library's progress as one bar, segmented by current stage of the mastery ladder
/// (DESIGN.md §6): mastered, translation, cloze and shadowing from strong to light; new sentences
/// are the track.
struct LibraryProgressBar: View {
    let progress: LibraryProgress

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    Rectangle()
                        .fill(Color.accentColor.opacity(segment.opacity))
                        .frame(width: geometry.size.width * progress.share(segment.count))
                }
                Spacer(minLength: 0)
            }
            .background(Color.secondary.opacity(0.15))
            .clipShape(Capsule())
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    private var segments: [(count: Int, opacity: Double)] {
        [(progress.mastered, 1), (progress.recall, 0.65), (progress.cloze, 0.4), (progress.shadow, 0.2)]
    }
}

/// Five rings after the progress bar (DESIGN.md §6), each a share of the library's sentences:
/// practiced, and reached level 2, 4, 6 and 7 of the ladder.
struct LibraryRings: View {
    let progress: LibraryProgress

    var body: some View {
        HStack(spacing: 10) {
            ring("Practiced", progress.practiced)
            ring(SentenceMode.shadow.displayName, progress.reached(2))
            ring(SentenceMode.cloze.displayName, progress.reached(4))
            ring(SentenceMode.recall.displayName, progress.reached(6))
            ring("Mastered", progress.reached(MasteryRules.masteredLevel))
        }
    }

    private func ring(_ label: LocalizedStringKey, _ count: Int) -> some View {
        let share = progress.share(count)
        return VStack(spacing: 3) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: share)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(verbatim: Self.percent(count: count, share: share))
                    .font(.system(size: 8.5, weight: .medium).monospacedDigit())
            }
            .frame(width: 30, height: 30)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    /// Whole percent; a share that is neither zero nor whole never shows as 0 % or 100 %.
    nonisolated static func percent(count: Int, share: Double) -> String {
        let value = Int((share * 100).rounded())
        if count > 0 && value == 0 { return "<1%" }
        if share < 1 && value == 100 { return "99%" }
        return "\(value)%"
    }
}

/// “Mastered X / N” (DESIGN.md §6).
struct MasteredLabel: View {
    let progress: LibraryProgress

    var body: some View {
        Text("Mastered \(progress.mastered) / \(progress.total)")
            .monospacedDigit()
            .font(.caption)
            .foregroundStyle(.secondary)
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
