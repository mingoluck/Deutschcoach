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
            case .waitingForBatch:
                centered { ProgressView("正在生成句子…") }  // Generating sentences…
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

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            if engine.status == .practicing, let item = engine.item {
                Text(Self.modeName(item.mode))
                    .font(.headline)
                Text("\(min(engine.progress.answered + 1, engine.progress.total)) / \(engine.progress.total)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if engine.isGeneratingNext && engine.status == .practicing {
                ProgressView().controlSize(.small)
                Text("正在准备下一组").font(.caption).foregroundStyle(.secondary)  // Preparing the next batch
            }
            switch engine.speechState {
            case .checking:
                EmptyView()
            case .downloading(let fraction):
                ProgressView("语音模型下载中", value: fraction).frame(width: 160)  // Downloading speech model
            case .ready:
                EmptyView()
            case .unavailable(let message):
                Label(message, systemImage: "mic.slash").foregroundStyle(.red).font(.caption)
            }
        }
    }

    static func modeName(_ mode: SentenceMode) -> String {
        switch mode {
        case .shadow: "跟读"  // Shadowing
        case .cloze: "填空"   // Cloze
        case .recall: "回忆"  // Recall
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
                    Text("判分中…").foregroundStyle(.secondary)  // Judging…
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
        Text(text.map { $0.isEmpty ? "（没有听到）" : $0 } ?? "")  // (nothing heard)
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
    static func summary(_ outcome: PracticeEngine.Outcome) -> (String, Color, String) {
        if outcome.skipped { return ("forward", .secondary, "已跳过") }  // Skipped
        let outcomes = outcome.events.map(\.outcome)
        if outcomes.isEmpty || outcomes.allSatisfy({ $0 == .notAttempted }) {
            let reason = outcome.events.first?.reason
            switch reason {
            case .unclear: return ("questionmark.circle", .orange, "没听清，不计分")  // Unclear, not scored
            case .paraphrase: return ("arrow.triangle.branch", .orange, "意思对，但没用目标表达")  // Right meaning, targets not used
            default: return ("mic.slash", .secondary, "没有听到声音")  // No speech heard
            }
        }
        if outcomes.contains(.fail) {
            return ("xmark.circle.fill", .red, "有错误")  // Mistakes
        }
        if outcomes.contains(.notAttempted) {
            return ("checkmark.circle", .green, "正确（部分改写）")  // Correct (partly paraphrased)
        }
        return ("checkmark.circle.fill", .green, "正确")  // Correct
    }

    // MARK: - Controls

    private func controls(_ item: PracticeItem) -> some View {
        HStack(spacing: 12) {
            if engine.step == .result {
                Button("重播", systemImage: "speaker.wave.2.fill") { engine.replay() }  // Replay
                Spacer()
                Button("下一句", systemImage: "arrow.right") {  // Next
                    Task { await engine.next() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
            } else {
                if item.mode == .shadow {
                    Button("重播", systemImage: "speaker.wave.2.fill") { engine.replay() }
                        .disabled(engine.step != .prompt)
                }
                Spacer()
                Button("跳过", systemImage: "forward") {  // Skip
                    Task { await engine.skip() }
                }
                .disabled(engine.step != .prompt && engine.step != .recording)

                let recording = engine.step == .recording
                Button(recording ? "停止" : "录音", systemImage: recording ? "stop.circle.fill" : "mic.fill") {  // Stop / Record
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
                Text("暂时无法练习").font(.title2.weight(.semibold))  // Practice unavailable
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("重试") { Task { await engine.retryAfterFailure() } }  // Retry
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: 420)
        }
    }

    private func centered(@ViewBuilder _ content: () -> some View) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
