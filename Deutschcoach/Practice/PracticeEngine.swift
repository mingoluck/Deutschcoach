import Foundation
import Observation
import os

private nonisolated let logger = Logger(subsystem: "com.ming.Deutschcoach", category: "practice")

/// Reads sentences aloud. `Speaker` in the app, a silent fake in tests.
protocol SentenceSpeaker: AnyObject {
    func speak(_ text: String) async
    func stop()
}

extension Speaker: SentenceSpeaker {}

/// A random source that can be stored and replaced in tests.
nonisolated struct AnyRandomSource: RandomNumberGenerator, @unchecked Sendable {
    var base: any RandomNumberGenerator
    mutating func next() -> UInt64 { base.next() }
}

/// Drives the practice screen (DESIGN.md §3): sessions, the answer loop of each sentence,
/// scoring and writing results. Everything is local; no LLM is involved.
@Observable
final class PracticeEngine {
    enum Status: Equatable {
        case starting
        /// The user's level has no sentence to practice (§3.1).
        case noContent
        case practicing
        /// Database or other errors that stop practice.
        case failed(String)
    }

    enum Step: Equatable {
        case prompt
        case recording
        case transcribing
        case result
    }

    enum SpeechState: Equatable {
        case checking
        case downloading(Double)
        case ready
        case unavailable(String)
    }

    private(set) var status: Status = .starting
    private(set) var step: Step = .prompt
    private(set) var item: PracticeItem?
    private(set) var outcome: ScoredAnswer?
    private(set) var liveText = ""
    private(set) var progress: (answered: Int, total: Int) = (0, 0)
    private(set) var speechState: SpeechState = .checking
    /// A recording or recognition error; the sentence can be answered again.
    private(set) var speechError: String?
    private(set) var userLevel: CEFRLevel
    /// Called after a session is finished, e.g. to refresh the history.
    var onSessionFinished: (() -> Void)?

    private let store: PracticeStore
    private let recognizer: any SpeechRecognizer
    private let speaker: any SentenceSpeaker
    private let recorder = AudioRecorder()
    private var rng: AnyRandomSource

    private var started = false
    private var sessionId: Int64?
    private var sessionDone = false
    private var transcription: Task<Transcript, any Error>?

    init(
        database: AppDatabase,
        recognizer: any SpeechRecognizer = AppleSpeechRecognizer(),
        speaker: any SentenceSpeaker = Speaker(),
        userLevel: CEFRLevel = .a1,
        now: @escaping @Sendable () -> Date = { Date() },
        random: any RandomNumberGenerator = SystemRandomNumberGenerator()
    ) {
        store = PracticeStore(database: database, now: now)
        self.recognizer = recognizer
        self.speaker = speaker
        self.userLevel = userLevel
        rng = AnyRandomSource(base: random)
    }

    var canRecord: Bool {
        status == .practicing && speechState == .ready && (step == .prompt || step == .recording)
    }

    // MARK: - Lifecycle (§3.1)

    /// Starts practice. `prepareSpeech` is false in tests, which answer without audio.
    func start(prepareSpeech: Bool = true) async {
        guard !started else { return }
        started = true
        if prepareSpeech {
            Task { await self.prepareSpeech() }
        } else {
            speechState = .ready
        }
        await launch()
    }

    /// Resumes the `active` session or builds a new one.
    private func launch() async {
        do {
            if let active = try await store.activeSession() {
                try await enter(session: active)
            } else {
                try await startNewSession()
            }
        } catch {
            fail(error)
        }
    }

    private func startNewSession() async throws {
        item = nil
        outcome = nil
        sessionId = nil
        let level = userLevel
        let candidates = try await store.candidates(level: level)
        let picks = SessionBuilder.pick(from: candidates, now: store.now(), using: &rng)
        guard let id = try await store.createSession(level: level, picks: picks) else {
            status = .noContent
            return
        }
        try await enter(session: id)
    }

    private func enter(session id: Int64) async throws {
        sessionId = id
        sessionDone = false
        try await showNextSentence()
    }

    private func stopAll() {
        stopRecording()
        speaker.stop()
        item = nil
        outcome = nil
        sessionId = nil
        sessionDone = false
    }

    /// The content changed (a seed was imported): start over if there was nothing to practice.
    func libraryChanged() async {
        guard started, status == .noContent || status == .starting else { return }
        stopAll()
        await launch()
    }

    /// §2.6: stops all work before practice records or the whole database are deleted.
    func prepareForDataReset() {
        stopAll()
        status = .starting
    }

    /// §2.6: after the deletion, practice restarts as on launch.
    func dataWasReset() async {
        guard started else { return }
        await launch()
    }

    /// §3.1: the active session is finished as is; the next one uses `level`.
    func changeLevel(to level: CEFRLevel) async {
        guard level != userLevel else { return }
        logger.info("User level \(self.userLevel.rawValue, privacy: .public) → \(level.rawValue, privacy: .public)")
        userLevel = level
        if started, status == .noContent {
            stopAll()
            await launch()
        }
    }

    // MARK: - Sentences

    private func showNextSentence() async throws {
        guard let sessionId else { return }
        guard let next = try await store.nextItem(inSession: sessionId) else {
            try await startNewSession()
            return
        }
        item = next
        outcome = nil
        liveText = ""
        speechError = nil
        step = .prompt
        progress = try await store.progress(ofSession: sessionId)
        status = .practicing
        // §3.3: only shadowing reads the sentence before the answer.
        if next.mode == .shadow { speak(next.sentence.de) }
    }

    /// The Next button on the result step.
    func next() async {
        guard step == .result else { return }
        speaker.stop()
        do {
            if sessionDone {
                try await startNewSession()
            } else {
                try await showNextSentence()
            }
        } catch {
            fail(error)
        }
    }

    func replay() {
        guard let item, item.mode == .shadow || step == .result else { return }
        speak(item.sentence.de)
    }

    private func speak(_ text: String) {
        let speaker = self.speaker
        Task { await speaker.speak(text) }
    }

    // MARK: - Answering

    func toggleRecording() async {
        switch step {
        case .prompt: await startRecording()
        case .recording: await finishRecording()
        default: break
        }
    }

    func skip() async {
        guard status == .practicing, step == .prompt || step == .recording else { return }
        stopRecording()
        await submit(heard: nil, skipped: true)
    }

    private func startRecording() async {
        guard canRecord else { return }
        speaker.stop()
        liveText = ""
        speechError = nil
        do {
            let audio = try await recorder.start()
            step = .recording
            let recognizer = self.recognizer
            transcription = Task.detached { [weak self] in
                try await recognizer.transcribe(audio) { [weak self] text in
                    Task { @MainActor in self?.liveText = text }
                }
            }
        } catch {
            speechFailed(error)
        }
    }

    private func finishRecording() async {
        recorder.stop()
        step = .transcribing
        guard let transcription else { step = .prompt; return }
        self.transcription = nil
        do {
            let transcript = try await transcription.value
            liveText = transcript.text
            await submit(heard: transcript.text, skipped: false)
        } catch {
            speechFailed(error)
        }
    }

    private func stopRecording() {
        recorder.stop()
        transcription?.cancel()
        transcription = nil
        if step == .recording || step == .transcribing { step = .prompt }
    }

    private func speechFailed(_ error: any Error) {
        logger.error("Speech error: \(error.localizedDescription, privacy: .public)")
        stopRecording()
        step = .prompt
        speechError = error.localizedDescription
    }

    /// Scores an answer and writes it (§3.4). `heard` is the final transcription; nil when
    /// skipped. Internal so tests can answer without audio.
    func submit(heard: String?, skipped: Bool) async {
        guard let item, step != .result else { return }
        let result = AnswerMatcher.score(de: item.sentence.de, spoken: item.sentence.spoken, heard: heard, skipped: skipped)
        logger.info("Sentence #\(item.sentence.id) (\(item.mode.rawValue, privacy: .public)): \(result.outcome.rawValue, privacy: .public)")
        let answer = AnswerRecord(
            outcome: result.outcome, reason: result.reason, heard: heard,
            engine: heard == nil ? nil : recognizer.engineName, mismatched: result.mismatched
        )
        do {
            sessionDone = try await store.record(answer, for: item)
            if sessionDone { onSessionFinished?() }
            if let sessionId { progress = try await store.progress(ofSession: sessionId) }
            outcome = ScoredAnswer(heard: heard, result: result)
            step = .result
            // §3.3: after answering, the correct sentence is shown and read aloud.
            speak(item.sentence.de)
        } catch {
            fail(error)
        }
    }

    // MARK: - Speech model

    private func prepareSpeech() async {
        switch await recognizer.availability() {
        case .ready:
            speechState = .ready
        case .unsupported:
            speechState = .unavailable("German speech recognition is not supported on this Mac.")
        case .needsDownload:
            speechState = .downloading(0)
            do {
                try await recognizer.prepare { [weak self] fraction in
                    Task { @MainActor in self?.speechState = .downloading(fraction) }
                }
                speechState = .ready
            } catch {
                speechState = .unavailable("Downloading the German speech model failed: \(error.localizedDescription)")
            }
        }
    }

    private func fail(_ error: any Error) {
        logger.error("Practice error: \(error.localizedDescription, privacy: .public)")
        stopRecording()
        status = .failed(error.localizedDescription)
    }
}
