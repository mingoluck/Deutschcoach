import SwiftUI

@main
struct DeutschcoachApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            // Temporary milestone screens; replaced by the practice screen later.
            TabView {
                Tab("Speech", systemImage: "waveform") {
                    SpeechLabView()
                }
                Tab("Database", systemImage: "cylinder") {
                    ContentView(model: model)
                }
            }
            .frame(minWidth: 640, minHeight: 480)
            .task { await model.start() }
        }
    }
}
