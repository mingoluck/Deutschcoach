import SwiftUI

@main
struct DeutschcoachApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            TabView {
                Tab("Practice", systemImage: "mic.fill") {
                    PracticeView(model: model)
                }
                Tab("History", systemImage: "clock") {
                    if let history = model.history {
                        HistoryView(history: history, language: model.nativeLanguage)
                    } else {
                        Text("No sessions yet.").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minWidth: 640, minHeight: 480)
            .environment(\.locale, NativeLanguage.locale(for: model.nativeLanguage))
            .task { await model.start() }
        }

        Settings {
            SettingsView(model: model)
                .environment(\.locale, NativeLanguage.locale(for: model.nativeLanguage))
        }
    }
}
