import SwiftUI

/// Temporary M4 screen: store the API key, generate a batch, inspect the stored sentences.
/// The settings screen (M6) and the practice screen (M5) replace it.
struct GenerationLabView: View {
    let model: AppModel
    @State private var lab = GenerationLab()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                keySection
                generateSection
                if !lab.log.isEmpty { logSection }
                sentencesSection
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .task {
            lab.refreshKeyState()
            if let database = model.database { await lab.loadLatest(database: database) }
        }
    }

    private var keySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude API key").font(.headline)
            if lab.hasKey {
                HStack {
                    Label("Stored in the Keychain", systemImage: "key.fill").foregroundStyle(.green)
                    Button("Remove Key", role: .destructive) { lab.deleteKey() }
                }
            } else {
                HStack {
                    SecureField("sk-ant-…", text: $lab.keyInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 420)
                        .onSubmit { lab.saveKey() }
                    Button("Save to Keychain") { lab.saveKey() }
                        .disabled(lab.keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Create a key at console.anthropic.com. It is stored only in the Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var generateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button("Generate Batch", systemImage: "sparkles") {
                    guard let database = model.database else { return }
                    Task { await lab.generate(database: database) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!lab.hasKey || lab.isGenerating || model.database == nil)
                if lab.isGenerating { ProgressView().controlSize(.small) }
                Text("\(lab.batchCount) batch(es) in the database")
                    .foregroundStyle(.secondary)
            }
            if let report = lab.report {
                let usage = report.usage
                Text("Tokens: in \(usage.input), out \(usage.output), cache write \(usage.cacheWrite), cache read \(usage.cacheRead) · ≈ $\(GenerationLab.estimatedCost(usage), format: .number.precision(.fractionLength(4)))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let message = lab.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lab.log.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var sentencesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !lab.sentences.isEmpty {
                Text("Latest batch").font(.headline)
            }
            ForEach(lab.sentences) { sentence in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("#\(sentence.position)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(sentence.mode.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                    if let annotation = sentence.annotation {
                        AnnotatedSentenceView(annotation)
                    } else {
                        Text(sentence.de).font(.title3)
                    }
                    Text(sentence.translation).font(.body)
                    Text("Targets: \(sentence.targets.joined(separator: " · "))")
                        .font(.caption)
                    if !sentence.incidental.isEmpty {
                        Text("Incidental: \(sentence.incidental.joined(separator: " · "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.cardBorder))
            }
        }
    }
}
