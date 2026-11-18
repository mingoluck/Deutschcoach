import SwiftUI

/// The practice screen (DESIGN.md §6). Until the sentence-based engine lands in M9 it shows the
/// loading state of the bundled seeds and how many sentences the chosen level has.
struct PracticeView: View {
    let model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .starting, .importing:
                ProgressView("Loading the word lists…")
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
            case .ready:
                VStack(spacing: 12) {
                    Image(systemName: "hammer")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Practice is being rebuilt.")
                        .font(.title3)
                    Text("\(model.library.sentences[model.userLevel] ?? 0) sentences at \(model.userLevel.rawValue)")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension SentenceMode {
    /// UI name (DESIGN.md §3.3), localized by the view's locale.
    var displayName: LocalizedStringKey {
        switch self {
        case .shadow: "Shadowing"
        case .cloze: "Cloze"
        case .recall: "Translation"
        }
    }
}
