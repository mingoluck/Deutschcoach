import SwiftUI

/// Temporary M2 screen for testing the speech loop with hard-coded sentences.
struct SpeechLabView: View {
    @State private var lab = SpeechLab()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            statusSection

            Picker("Sentence", selection: $lab.sentence) {
                ForEach(SpeechLab.sentences, id: \.self) { Text($0).tag($0) }
            }
            .disabled(lab.phase != .idle)

            Text(lab.sentence)
                .font(.title2)
                .textSelection(.enabled)

            HStack(spacing: 12) {
                if lab.phase == .speaking {
                    Button("Stop", systemImage: "stop.fill") { lab.stopSpeaking() }
                } else {
                    Button("Read Aloud", systemImage: "speaker.wave.2.fill") {
                        Task { await lab.speak() }
                    }
                    .disabled(lab.phase != .idle)
                }

                Button(lab.phase == .recording ? "Stop Recording" : "Record",
                       systemImage: lab.phase == .recording ? "stop.circle.fill" : "mic.fill") {
                    Task { await lab.toggleRecording() }
                }
                .tint(lab.phase == .recording ? .red : nil)
                .disabled(!lab.canRecord)
                .keyboardShortcut(.space, modifiers: [])

                if lab.phase == .transcribing {
                    ProgressView().controlSize(.small)
                }
            }
            .buttonStyle(.borderedProminent)

            resultSection

            if let message = lab.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task { await lab.prepareModel() }
    }

    @ViewBuilder
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch lab.modelState {
            case .checking:
                Label("Checking German speech model…", systemImage: "hourglass")
            case .downloading(let fraction):
                ProgressView("Downloading German speech model…", value: fraction)
                    .frame(maxWidth: 320)
            case .ready:
                Label("German speech model ready", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            case .unavailable(let message):
                Label(message, systemImage: "xmark.octagon").foregroundStyle(.red)
            }
            Label("Voice: \(lab.speaker.voiceDescription)", systemImage: "person.wave.2")
            if !lab.speaker.hasHighQualityVoice {
                Text("Tip: install an enhanced German voice in System Settings → Accessibility → Spoken Content → System Voice → Manage Voices.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if lab.phase == .recording || !lab.liveText.isEmpty {
                LabeledContent("Heard") {
                    Text(lab.liveText.isEmpty ? "…" : lab.liveText)
                        .foregroundStyle(lab.phase == .recording ? .secondary : .primary)
                        .textSelection(.enabled)
                }
            }

            if let alignment = lab.alignment {
                LabeledContent("Alignment") {
                    Text(alignment.attributedText)
                }
                if !alignment.extra.isEmpty {
                    LabeledContent("Extra words") {
                        Text(alignment.extra.joined(separator: " ")).foregroundStyle(.orange)
                    }
                }
                LabeledContent("Score") {
                    Text("\(alignment.matchedCount) / \(alignment.words.count) words")
                        .monospacedDigit()
                }
            }
        }
        .font(.title3)
    }
}
