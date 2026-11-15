import SwiftUI

/// The practice screen (DESIGN.md §6): only the German sentence, its annotation and the
/// translation (recall: translation only), with record and skip buttons. After answering, the
/// correct sentence is shown and read aloud.
struct PracticeView: View {
    let model: AppModel

    var body: some View {
        if let engine = model.practice {
            PracticeContent(engine: engine)
        } else if case .failed(let message) = model.phase {
            Label(message, systemImage: "xmark.octagon")
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct PracticeContent: View {
    let engine: PracticeEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            switch engine.status {
            case .starting:
                centered { ProgressView() }
            case .emptyLibrary:
                emptyLibrary
            case .waitingForBatch:
                centered { ProgressView("Generating sentences…") }
            case .unavailable(let message):
                blocked(message)
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

    // MARK: - Empty library (§3.1)

    @Environment(\.openSettings) private var openSettings

    private var emptyLibrary: some View {
        centered {
            VStack(spacing: 14) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("The library is empty; import a seed first.")
                    .font(.title3)
                Button("Open Library Settings") {
                    UserDefaults.standard.set(SettingsTab.library.rawValue, forKey: SettingsTab.defaultsKey)
                    openSettings()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            if engine.status == .practicing, let item = engine.item {
                Text(item.mode.displayName)
                    .font(.headline)
                Text("\(min(engine.progress.answered + 1, engine.progress.total)) / \(engine.progress.total)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if engine.isGeneratingNext && engine.status == .practicing {
                ProgressView().controlSize(.small)
                Text("Preparing the next batch").font(.caption).foregroundStyle(.secondary)
            }
            switch engine.speechState {
            case .checking:
                EmptyView()
            case .downloading(let fraction):
                ProgressView("Downloading the speech model", value: fraction).frame(width: 160)
            case .ready:
                EmptyView()
            case .unavailable(let message):
                Label(message, systemImage: "mic.slash").foregroundStyle(.red).font(.caption)
            }
        }
    }


    // MARK: - Sentence

    @ViewBuilder
    private func sentence(_ item: PracticeItem) -> some View {
        let answered = engine.step == .result || engine.step == .judging
        VStack(alignment: .leading, spacing: 18) {
            if answered || item.mode == .shadow {
                AnnotatedSentenceView(item.annotation)
            } else if item.mode == .cloze {
                AnnotatedSentenceView(item.annotation, blanks: Set(item.blanks))
            }
            Text(item.translation(for: engine.nativeLang))
                .font(item.mode == .recall && !answered ? .title : .title3)
                .foregroundStyle(item.mode == .recall && !answered ? .primary : .secondary)
                .textSelection(.enabled)

            answerSection(item)
        }
    }

    @ViewBuilder
    private func answerSection(_ item: PracticeItem) -> some View {
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
            case .judging:
                heard(engine.outcome?.heard)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Judging…").foregroundStyle(.secondary)
                }
            case .result:
                if let outcome = engine.outcome {
                    result(outcome)
                }
            }
        }
        .padding(.top, 8)
    }

    private func heard(_ text: String?) -> some View {
        Group {
            if let text, !text.isEmpty {
                Text(verbatim: text)
            } else if text != nil {
                Text("(nothing heard)")
            }
        }
        .font(.title3)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func result(_ outcome: PracticeEngine.Outcome) -> some View {
        let (symbol, color, text) = Self.summary(outcome)
        Label(text, systemImage: symbol)
            .font(.title3.weight(.semibold))
            .foregroundStyle(color)
        if let alignment = outcome.alignment {
            Text(alignment.attributedText).font(.title3)
        } else if !outcome.skipped {
            heard(outcome.heard)
        }
    }

    /// One-line result: no explanations of elements (§0).
    static func summary(_ outcome: PracticeEngine.Outcome) -> (String, Color, LocalizedStringKey) {
        if outcome.skipped { return ("forward", .secondary, "Skipped") }
        let outcomes = outcome.events.map(\.outcome)
        if outcomes.isEmpty || outcomes.allSatisfy({ $0 == .notAttempted }) {
            let reason = outcome.events.first?.reason
            switch reason {
            case .unclear: return ("questionmark.circle", .orange, "Unclear, not scored")
            case .paraphrase: return ("arrow.triangle.branch", .orange, "Right meaning, but without the target words")
            default: return ("mic.slash", .secondary, "No speech heard")
            }
        }
        if outcomes.contains(.fail) {
            return ("xmark.circle.fill", .red, "Mistakes")
        }
        if outcomes.contains(.notAttempted) {
            return ("checkmark.circle", .green, "Correct (partly paraphrased)")
        }
        return ("checkmark.circle.fill", .green, "Correct")
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

    // MARK: - Blocked (§1, §6)

    private func blocked(_ message: String) -> some View {
        centered {
            VStack(spacing: 16) {
                Image(systemName: "icloud.slash").font(.largeTitle).foregroundStyle(.secondary)
                Text("Practice is unavailable").font(.title2.weight(.semibold))
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Retry") { Task { await engine.retryAfterFailure() } }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: 420)
        }
    }

    private func centered(@ViewBuilder _ content: () -> some View) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension SentenceMode {
    /// UI name (DESIGN.md §3.3), localized by the view's locale.
    var displayName: LocalizedStringKey {
        switch self {
        case .shadow: "Shadowing"
        case .cloze: "Cloze"
        case .recall: "Recall"
        }
    }
}
