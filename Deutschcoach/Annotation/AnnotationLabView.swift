import SwiftUI

/// Temporary M3 screen: the sample sentences with the same controls as the visual reference page
/// (example, mode, layers, theme), for side-by-side comparison.
struct AnnotationLabView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case shadow = "Shadowing", cloze = "Cloze"
        var id: Self { self }
    }

    enum Theme: String, CaseIterable, Identifiable {
        case system = "System", light = "Light", dark = "Dark"
        var id: Self { self }
        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    @State private var examples: [AnnotationExample] = []
    @State private var loadError: String?
    @State private var selected = 0
    @State private var mode = Mode.shadow
    @State private var layers = AnnotationLayers()
    @State private var theme = Theme.system
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                controls
                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                } else if examples.indices.contains(selected) {
                    stage(examples[selected])
                        .environment(\.colorScheme, theme.colorScheme ?? systemScheme)
                }
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .task {
            do {
                examples = try AnnotationExample.loadBundled()
            } catch {
                loadError = "Could not load sample_annotations.json: \(error.localizedDescription)"
            }
        }
    }

    private var controls: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Example").foregroundStyle(.secondary)
                Picker("Example", selection: $selected) {
                    ForEach(examples.indices, id: \.self) { Text(examples[$0].title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            GridRow {
                Text("Mode").foregroundStyle(.secondary)
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            GridRow {
                Text("Layers").foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Toggle("Case colors", isOn: $layers.caseColors)
                    Toggle("Part of speech", isOn: $layers.partOfSpeech)
                    Toggle("Constituents", isOn: $layers.constituents)
                    Toggle("Clauses", isOn: $layers.clauses)
                }
                .toggleStyle(.checkbox)
            }
            GridRow {
                Text("Theme").foregroundStyle(.secondary)
                Picker("Theme", selection: $theme) {
                    ForEach(Theme.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .font(.callout)
    }

    private func stage(_ example: AnnotationExample) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            AnnotatedSentenceView(
                example.annotation,
                blanks: mode == .cloze ? Set(example.blanks) : [],
                layers: layers
            )
            Divider().overlay(Color.cardBorder).padding(.top, 20)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(example.level)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.secondaryText)
                    .padding(.horizontal, 6)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.cardBorder))
                Text(example.translation)
                    .font(.system(size: 17))
                    .foregroundStyle(Color.ink)
            }
            .padding(.top, 14)
        }
        .padding(EdgeInsets(top: 26, leading: 22, bottom: 20, trailing: 22))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.cardBorder))
    }
}
