import SwiftUI

@main
struct DeutschcoachApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            // The lab tabs are temporary milestone screens.
            TabView {
                Tab("Practice", systemImage: "mic.fill") {
                    PracticeView(model: model)
                }
                Tab("Generation", systemImage: "sparkles") {
                    GenerationLabView(model: model)
                }
                Tab("Annotation", systemImage: "textformat") {
                    AnnotationLabView()
                }
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
