import AVFAudio
import SwiftUI

/// The Settings window (⌘,): API key, native language, voice (DESIGN.md §6).
struct SettingsView: View {
    let model: AppModel

    @State private var keyInput = ""
    @State private var keyError: String?
    @State private var isSaving = false
    @State private var voiceId: String = Speaker.selectedVoiceIdentifier ?? ""
    private let voices = Speaker.germanVoices()

    var body: some View {
        Form {
            Section("Claude API Key") {
                LabeledContent("Status") {
                    Text(model.hasAPIKey ? "Stored in the Keychain" : "Not set")
                        .foregroundStyle(model.hasAPIKey ? Color.secondary : Color.red)
                }
                SecureField("New key", text: $keyInput)
                    .onSubmit(save)
                HStack {
                    Button("Save", action: save)
                        .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                    if model.hasAPIKey {
                        Button("Delete", role: .destructive) {
                            Task {
                                do { try await model.deleteAPIKey() } catch { keyError = error.localizedDescription }
                            }
                        }
                    }
                }
                if let keyError {
                    Text(keyError).foregroundStyle(.red)
                }
            }

            Section("Native Language") {
                Picker("Native Language", selection: Binding(
                    get: { model.nativeLanguage },
                    set: { language in Task { await model.setNativeLanguage(language) } }
                )) {
                    ForEach(NativeLanguage.supported, id: \.code) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                Text("Changing it discards the current batch and generates a new one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Voice") {
                Picker("German voice", selection: $voiceId) {
                    Text("Automatic (best)").tag("")
                    ForEach(voices, id: \.identifier) { voice in
                        Text(Speaker.describe(voice)).tag(voice.identifier)
                    }
                }
                .onChange(of: voiceId) { _, id in
                    Speaker.selectedVoiceIdentifier = id.isEmpty ? nil : id
                }
                Button("Preview", systemImage: "speaker.wave.2.fill") {
                    let speaker = model.speaker
                    Task { await speaker.speak("Ich gebe den Kindern einen Apfel.") }
                }
                if !model.speaker.hasHighQualityVoice {
                    Text("Install enhanced German voices in System Settings → Accessibility → Spoken Content → System Voice → Manage Voices.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear { model.refreshKeyState() }
    }

    private func save() {
        let key = keyInput
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSaving = true
        Task {
            do {
                try await model.saveAPIKey(key)
                keyInput = ""
                keyError = nil
            } catch {
                keyError = error.localizedDescription
            }
            isSaving = false
        }
    }
}
