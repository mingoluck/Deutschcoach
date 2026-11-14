import Foundation
import GRDB
import Observation
import os

private nonisolated let logger = Logger(subsystem: "com.ming.Deutschcoach", category: "practice")

/// Reads sentences aloud. `Speaker` in the app, a silent fake in tests.
protocol SentenceSpeaker: AnyObject {
    func speak(_ text: String) async
    func stop()
}

extension Speaker: SentenceSpeaker {}

/// Drives the practice screen (DESIGN.md §3): batch transitions with pre-generation, the
/// answer loop of each sentence, scoring and writing results.
@Observable
final class PracticeEngine {
    enum Status: Equatable {
        case starting
        /// No sentence to practice until the batch being generated is ready.
        case waitingForBatch
        case practicing
        /// §1: the LLM is unavailable; practice is blocked until a retry succeeds.
        case unavailable(String)
        /// Anything else that stops practice (database, speech).
        case failed(String)
    }

    enum Step: Equatable {
        case prompt
        case recording
        case transcribing
        case judging
        case result
    }

    /// The scored answer shown on the result step.
    struct Outcome: Equatable {
        var heard: String?
        var skipped: Bool
        /// Shadowing: which words were heard.
        var alignment: Alignment?
        var verdict: JudgeVerdict?
        var events: [EventDraft]
    }

    enum SpeechState: Equatable {
        case checking
        case downloading(Double)
        case ready
        case unavailable(String)
    }

    private enum Retry {
        case generate
        case judge(heard: String)
    }

    private(set) var status: Status = .starting
    private(set) var step: Step = .prompt
    private(set) var item: PracticeItem?
    private(set) var outcome: Outcome?
    private(set) var liveText = ""
    private(set) var progress: (answered: Int, total: Int) = (0, 0)
    private(set) var speechState: SpeechState = .checking
    private(set) var isGeneratingNext = false
    /// A recording or recognition error; the sentence can be answered again.
    private(set) var speechError: String?

    let nativeLang: String
    private let store: PracticeStore
    private let model: any LanguageModel
    private let recognizer: any SpeechRecognizer
    private let speaker: any SentenceSpeaker
    private let recorder = AudioRecorder()

    private var started = false
    private var batchId: Int64?
    private var batchDone = false
    private var retry: Retry?
    private var generationTask: Task<Void, Never>?
    private var transcription: Task<Transcript, any Error>?

    init(
        database: AppDatabase,
        model: any LanguageModel,
        recognizer: any SpeechRecognizer = AppleSpeechRecognizer(),
        speaker: any SentenceSpeaker = Speaker(),
        nativeLang: String = NativeLanguage.current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        store = PracticeStore(database: database, now: now)
        self.model = model
        self.recognizer = recognizer
        self.speaker = speaker
        self.nativeLang = nativeLang
    }

    var canRecord: Bool {
        status == .practicing && speechState == .ready && (step == .prompt || step == .recording)
    }

    // MARK: - Lifecycle (§3.1)

    func start() async {
        guard !started else { return }
        started = true
        Task { await prepareSpeech() }
        do {
            if let active = try await store.prepareOnLaunch() {
                try await enter(batch: active)
            } else {
                status = .waitingForBatch
                startGeneration()
            }
        } catch {
            fail(error)
        }
    }

    /// Practice `batchId` (already `active`) and pre-generate the next batch.
    private func enter(batch id: Int64) async throws {
        batchId = id
        batchDone = false
        logger.info("Practicing batch #\(id)")
        try await showNextSentence()
        // §3.1: as soon as a batch is active, generate the next one (also the LLM probe).
        if try await !store.hasReadyBatch() { startGeneration() }
    }

    /// Moves to the next batch: the ready one if any, otherwise waits for generation.
    private func advanceBatch() async throws {
        item = nil
        outcome = nil
        if let next = try await store.activeOrPromote() {
            try await enter(batch: next)
        } else {
            batchId = nil
            status = .waitingForBatch
            startGeneration()
        }
    }

    private func startGeneration() {
        guard generationTask == nil else { return }
        isGeneratingNext = true
        let store = self.store
        let model = self.model
        let nativeLang = self.nativeLang
        generationTask = Task {
            let result: Result<Void, any Error>
            do {
                let request = try await store.database.writer.read { db in
                    try ElementPicker(nativeLang: nativeLang).makeRequest(from: db)
                }
                logger.info("Generating a batch: modes \(request.sentences.map(\.mode.rawValue), privacy: .public)")
                _ = try await BatchGenerator(database: store.database, model: model).generate(request)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            await self.generationFinished(result)
        }
    }

    private func generationFinished(_ result: Result<Void, any Error>) async {
        generationTask = nil
        isGeneratingNext = false
        switch result {
        case .success:
            if batchId == nil, status == .waitingForBatch {
                do { try await advanceBatch() } catch { fail(error) }
            }
        case .failure(let error):
            // §3.1: a failed generation means the LLM is unavailable.
            logger.error("Generation failed: \(error.localizedDescription, privacy: .public)")
            block(error, retry: .generate)
        }
    }

    /// Awaits the running generation, if any (tests).
    func waitForGeneration() async {
        await generationTask?.value
    }

    // MARK: - LLM unavailable

    private func block(_ error: any Error, retry: Retry) {
        stopRecording()
        speaker.stop()
        self.retry = retry
        status = .unavailable(error.localizedDescription)
    }

    /// The Retry button of the blocked screen.
    func retryAfterFailure() async {
        guard case .unavailable = status, let retry else { return }
        self.retry = nil
        switch retry {
        case .generate:
            status = batchId == nil ? .waitingForBatch : .practicing
            startGeneration()
        case .judge(let heard):
            status = .practicing
            await judge(heard: heard)
        }
    }

    // MARK: - Sentences

    private func showNextSentence() async throws {
        guard let batchId else { return }
        guard let next = try await store.nextItem(inBatch: batchId) else {
            try await advanceBatch()
            return
        }
        item = next
        outcome = nil
        liveText = ""
        step = .prompt
        progress = try await store.progress(ofBatch: batchId)
        status = .practicing
        // §3.3: only shadowing reads the sentence before the answer.
        if next.mode == .shadow { speak(next.sentence.de) }
    }

    /// The Next button on the result step.
    func next() async {
        guard step == .result else { return }
        speaker.stop()
        do {
            if batchDone {
                try await advanceBatch()
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

    /// Scores an answer and writes it (§3.4). `heard` is the final transcription; `nil` when
    /// skipped. Internal so tests can answer without audio.
    func submit(heard: String?, skipped: Bool) async {
        guard let item else { return }
        logger.info("Answer for sentence #\(item.sentence.id ?? 0): \(skipped ? "skipped" : "\"\(heard ?? "")\"", privacy: .public)")
        switch item.mode {
        case .shadow:
            let result = Scorer.scoreShadow(item, heard: heard, skipped: skipped)
            await write(Outcome(heard: heard, skipped: skipped, alignment: result.alignment, events: result.events),
                        status: skipped ? .skipped : .done)
        case .cloze, .recall:
            switch Scorer.scoreLocally(item, heard: heard, skipped: skipped) {
            case .pass(let events), .notAttempted(let events):
                await write(Outcome(heard: heard, skipped: skipped, events: events), status: skipped ? .skipped : .done)
            case .needsJudge:
                // §3.4 ③: show and read the answer while the judge runs.
                speak(item.sentence.de)
                await judge(heard: heard ?? "")
            }
        }
    }

    private func judge(heard: String) async {
        guard let item else { return }
        step = .judging
        outcome = Outcome(heard: heard, skipped: false, events: [])
        do {
            let verdict = try await model.judge(Scorer.judgeRequest(for: item, heard: heard, nativeLang: nativeLang))
            let events = Scorer.events(from: verdict, targets: item.targets)
            await write(Outcome(heard: heard, skipped: false, verdict: verdict, events: events), status: .done, speakAnswer: false)
        } catch {
            // §3.4: the attempt is discarded; Retry re-sends the same answer.
            logger.error("Judge failed: \(error.localizedDescription, privacy: .public)")
            block(error, retry: .judge(heard: heard))
        }
    }

    private func write(_ outcome: Outcome, status sentenceStatus: SentenceStatus, speakAnswer: Bool = true) async {
        guard let item else { return }
        do {
            batchDone = try await store.record(
                outcome.events,
                for: item,
                status: sentenceStatus,
                heard: outcome.heard,
                engine: outcome.heard == nil ? nil : recognizer.engineName,
                judge: outcome.verdict
            )
            if let batchId { progress = try await store.progress(ofBatch: batchId) }
            self.outcome = outcome
            step = .result
            // §3.3: after answering, the correct sentence is shown and read aloud.
            if speakAnswer { speak(item.sentence.de) }
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
