import SwiftUI

/// The practice screen (DESIGN.md §6): only the German sentence, its annotation and the
/// translation (translation mode: translation only), with record and skip buttons. After
/// answering, the correct sentence is shown and read aloud, with mismatched words marked.
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
                if let engine = model.practice {
                    PracticeContent(engine: engine, language: model.nativeLanguage)
                } else {
                    ProgressView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PracticeContent: View {
    let engine: PracticeEngine
    let language: String

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            switch engine.status {
            case .starting:
                centered { ProgressView() }
            case .noContent:
                noContent
            case .failed(let message):
                centered {
                    Label(message, systemImage: "xmark.octagon").foregroundStyle(.red)
                }
            case .practicing:
                if let item = engine.item {
                    sentence(item)
                    Spacer(minLength: 0)
                    controls(item)
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - No content (§3.1)

    private var noContent: some View {
        centered {
            VStack(spacing: 14) {
                Image(systemName: "text.book.closed")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("There are no sentences at level \(engine.userLevel.rawValue) yet.")
                    .font(.title3)
                Text("Choose another level in Settings.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            if engine.status == .practicing, let item = engine.item {
                Text(item.mode.displayName)
                    .font(.headline)
                Text("\(min(engine.progress.answered + (engine.step == .result ? 0 : 1), engine.progress.total)) / \(engine.progress.total)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch engine.speechState {
            case .checking, .ready:
                EmptyView()
            case .downloading(let fraction):
                ProgressView("Downloading the speech model", value: fraction).frame(width: 160)
            case .unavailable(let message):
                Label(message, systemImage: "mic.slash").foregroundStyle(.red).font(.caption)
            }
        }
    }

    // MARK: - Sentence

    @ViewBuilder
    private func sentence(_ item: PracticeItem) -> some View {
        let answered = engine.step == .result
        let labels = LabelCatalog(language: language)
        VStack(alignment: .leading, spacing: 18) {
            if answered || item.mode == .shadow {
                AnnotatedSentenceView(item.annotation, labels: labels)
            } else if item.mode == .cloze {
                AnnotatedSentenceView(item.annotation, blanks: Set(item.blanks), labels: labels)
            }
            Text(item.translation(for: language))
                .font(item.mode == .recall && !answered ? .title : .title3)
                .foregroundStyle(item.mode == .recall && !answered ? .primary : .secondary)
                .textSelection(.enabled)

            answerSection
        }
    }

    @ViewBuilder
    private var answerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch engine.step {
            case .prompt:
                if let error = engine.speechError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            case .recording, .transcribing:
                Text(engine.liveText.isEmpty ? "…" : engine.liveText)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            case .result:
                if let outcome = engine.outcome {
                    ResultView(outcome: outcome)
                }
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Controls

    private func controls(_ item: PracticeItem) -> some View {
        HStack(spacing: 12) {
            if engine.step == .result {
                Button("Replay", systemImage: "speaker.wave.2.fill") { engine.replay() }
                Spacer()
                Button("Next", systemImage: "arrow.right") {
                    Task { await engine.next() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
            } else {
                if item.mode == .shadow {
                    Button("Replay", systemImage: "speaker.wave.2.fill") { engine.replay() }
                        .disabled(engine.step != .prompt)
                }
                Spacer()
                Button("Skip", systemImage: "forward") {
                    Task { await engine.skip() }
                }
                .disabled(engine.step != .prompt && engine.step != .recording)

                let recording = engine.step == .recording
                Button(recording ? "Stop" : "Record", systemImage: recording ? "stop.circle.fill" : "mic.fill") {
                    Task { await engine.toggleRecording() }
                }
                .buttonStyle(.borderedProminent)
                .tint(recording ? .red : nil)
                .disabled(!engine.canRecord)
                .keyboardShortcut(.space, modifiers: [])

                if engine.step == .transcribing {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .controlSize(.large)
    }

    private func centered(@ViewBuilder _ content: () -> some View) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The one-line result and, for a wrong answer, the sentence with the mismatched words marked.
struct ResultView: View {
    let outcome: ScoredAnswer

    var body: some View {
        let (symbol, color, text) = Self.summary(outcome.result)
        VStack(alignment: .leading, spacing: 8) {
            Label(text, systemImage: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)
            if outcome.result.outcome == .fail, let alignment = outcome.result.alignment {
                Text(alignment.attributedText).font(.title3)
                if !alignment.extra.isEmpty {
                    Text("Extra: \(alignment.extra.joined(separator: " "))")
                        .foregroundStyle(.secondary)
                }
            }
            if outcome.result.outcome != .notAttempted || outcome.result.reason == .noSpeech {
                heard
            }
        }
    }

    @ViewBuilder
    private var heard: some View {
        if let text = outcome.heard, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            Text(verbatim: text).foregroundStyle(.secondary).textSelection(.enabled)
        } else {
            Text("(nothing heard)").foregroundStyle(.secondary)
        }
    }

    /// One-line result: no explanations (§0).
    static func summary(_ result: AnswerMatcher.Result) -> (String, Color, LocalizedStringKey) {
        switch (result.outcome, result.reason) {
        case (.pass, _): ("checkmark.circle.fill", .green, "Correct")
        case (.fail, _): ("xmark.circle.fill", .red, "Mistakes")
        case (.notAttempted, .skipped): ("forward", .secondary, "Skipped")
        case (.notAttempted, _): ("mic.slash", .secondary, "No speech heard")
        }
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
