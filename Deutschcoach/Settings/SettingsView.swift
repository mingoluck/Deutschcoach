import AVFAudio
import SwiftUI

/// The tabs of the Settings window; the selection is remembered so that the practice screen
/// can open the Library tab directly.
enum SettingsTab: String {
    case general, library

    static let defaultsKey = "settingsTab"
}

/// The Settings window (⌘,) with the General and Library tabs (DESIGN.md §6).
struct SettingsView: View {
    let model: AppModel
    @AppStorage(SettingsTab.defaultsKey) private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) {
                GeneralSettingsView(model: model)
            }
            Tab("Library", systemImage: "books.vertical", value: SettingsTab.library) {
                LibrarySettingsView(model: model)
            }
        }
    }
}

/// API key, native language, user level, voice.
private struct GeneralSettingsView: View {
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
                Text("Translations and the interface follow this language.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Level") {
                Picker("My level", selection: Binding(
                    get: { model.userLevel },
                    set: { level in Task { await model.setUserLevel(level) } }
                )) {
                    ForEach(CEFRLevel.practiceLevels, id: \.self) { level in
                        Text(verbatim: level.rawValue).tag(level)
                    }
                }
                Text("Practice uses only the sentences of this level. The next session uses the new level.")
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
