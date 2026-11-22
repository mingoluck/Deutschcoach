import Foundation
import Observation

/// State of the history screen (DESIGN.md §6) and its re-practice (§3.6).
@Observable
final class HistoryModel {
    private(set) var sessions: [HistorySession] = []
    private(set) var loadError: String?
    /// The items checked for re-practice; kept while switching tabs.
    var selection: Set<HistoryItem.Key> = []
    /// The running re-practice, shown as a sheet; nil when there is none.
    private(set) var replay: PracticeEngine?
    /// Called when a re-practice starts, e.g. to stop a recording on the practice screen.
    var onReplayStart: (() -> Void)?

    private let store: HistoryStore
    private let database: AppDatabase
    private let speaker: any SentenceSpeaker
    private let makeRecognizer: () -> any SpeechRecognizer

    init(database: AppDatabase, speaker: any SentenceSpeaker = Speaker(),
         makeRecognizer: @escaping () -> any SpeechRecognizer = { AppleSpeechRecognizer() }) {
        store = HistoryStore(database: database)
        self.database = database
        self.speaker = speaker
        self.makeRecognizer = makeRecognizer
    }

    func reload() async {
        do {
            sessions = try await store.load()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// The checked items that are still in the history, in history order (§3.6).
    var selectedItems: [HistoryItem] {
        sessions.flatMap(\.items).filter { selection.contains($0.id) }
    }

    /// §3.6: starts a temporary re-practice of the checked items.
    func startReplay(prepareSpeech: Bool = true) async {
        let items = selectedItems
        guard replay == nil, !items.isEmpty else { return }
        do {
            let practiceItems = try await store.practiceItems(items)
            onReplayStart?()
            let engine = PracticeEngine(replaying: practiceItems, database: database,
                                        recognizer: makeRecognizer(), speaker: speaker)
            replay = engine
            await engine.start(prepareSpeech: prepareSpeech)
        } catch {
            loadError = error.localizedDescription
        }
    }

    func endReplay() {
        replay?.interrupt()
        replay = nil
    }
}
