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
        /// §3.1: the library has nothing to build a batch from; the user must import seeds.
        case emptyLibrary
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
        /// Nothing failed (blocked because the network went away): just continue.
        case resume
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

    private(set) var nativeLang: String
    private(set) var userLevel: CEFRLevel
    private let store: PracticeStore
    private let model: any LanguageModel
    private let recognizer: any SpeechRecognizer
    private let speaker: any SentenceSpeaker
    private let network: any NetworkMonitor
    private let recorder = AudioRecorder()

    private var started = false
    private var batchId: Int64?
    private var batchDone = false
    private var retry: Retry?
    private var generationTask: Task<Void, Never>?
    /// Identifies the current generation; results of an older one (before a language change)
    /// are discarded.
    private var generationToken = 0
    private var transcription: Task<Transcript, any Error>?

    init(
        database: AppDatabase,
        model: any LanguageModel,
        recognizer: any SpeechRecognizer = AppleSpeechRecognizer(),
        speaker: any SentenceSpeaker = Speaker(),
        network: any NetworkMonitor = SystemNetworkMonitor(),
        nativeLang: String = NativeLanguage.current,
        userLevel: CEFRLevel = .a1,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        store = PracticeStore(database: database, now: now)
        self.model = model
        self.recognizer = recognizer
        self.speaker = speaker
        self.network = network
        self.nativeLang = nativeLang
        self.userLevel = userLevel
    }

    var canRecord: Bool {
        status == .practicing && speechState == .ready && (step == .prompt || step == .recording)
    }

    // MARK: - Lifecycle (§3.1)

    func start() async {
        guard !started else { return }
        started = true
        Task { await prepareSpeech() }
        network.start { [weak self] online in
            Task { await self?.networkChanged(online: online) }
        }
        await launch()
    }

    /// The launch sequence of §3.1; also re-run after the library or the database changed.
    private func launch() async {
        do {
            if let active = try await store.prepareOnLaunch() {
                if !network.isOnline { block(LLMError.offline, retry: .resume) }
                try await enter(batch: active)
            } else if try await !hasContent() {
                // §3.1: checked before the LLM-unavailable block; the LLM is not called.
                status = .emptyLibrary
                return
            } else {
                status = .waitingForBatch
                startGeneration()  // blocks at once when offline
            }
        } catch {
            fail(error)
            return
        }
        await checkAccess()
    }

    private func hasContent() async throws -> Bool {
        let level = userLevel
        return try await store.database.writer.read { db in
            try ElementPicker.hasPracticableContent(upTo: level, in: db)
        }
    }

    /// Stops everything in flight: recording, speech, generation, the current sentence.
    private func stopAll() {
        stopRecording()
        speaker.stop()
        generationTask?.cancel()
        generationTask = nil
        generationToken += 1  // results of the running generation are discarded
        isGeneratingNext = false
        item = nil
        outcome = nil
        batchId = nil
        batchDone = false
        retry = nil
    }

    /// The library changed (seeds imported): restart as on launch (§2.5, §3.1). Batches stay.
    func libraryChanged() async {
        guard started else { return }
        switch status {
        case .emptyLibrary, .failed:
            stopAll()
            status = .starting
            await launch()
        default:
            // Practicing or waiting: the next generation picks from the new content anyway.
            break
        }
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

    /// Practice `batchId` (already `active`) and pre-generate the next batch.
    private func enter(batch id: Int64) async throws {
        batchId = id
        batchDone = false
        logger.info("Practicing batch #\(id)")
        try await showNextSentence()
        // §3.1: as soon as a batch is active, generate the next one (also the LLM probe).
        if try await !store.hasReadyBatch(), try await hasContent() { startGeneration() }
    }

    /// Moves to the next batch: the ready one if any, otherwise waits for generation.
    private func advanceBatch() async throws {
        item = nil
        outcome = nil
        if let next = try await store.activeOrPromote() {
            try await enter(batch: next)
        } else if try await !hasContent() {
            batchId = nil
            status = .emptyLibrary
        } else {
            batchId = nil
            status = .waitingForBatch
            startGeneration()
        }
    }

    private func startGeneration() {
        guard generationTask == nil else { return }
        guard network.isOnline else {
            block(LLMError.offline, retry: .generate)
            return
        }
        isGeneratingNext = true
        generationToken += 1
        let token = generationToken
        let store = self.store
        let model = self.model
        let nativeLang = self.nativeLang
        let userLevel = self.userLevel
        generationTask = Task {
            let result: Result<Int64, any Error>
            do {
                let request = try await store.database.writer.read { db in
                    try ElementPicker(nativeLang: nativeLang, userLevel: userLevel).makeRequest(from: db)
                }
                logger.info("Generating a batch: modes \(request.sentences.map(\.mode.rawValue), privacy: .public)")
                let report = try await BatchGenerator(database: store.database, model: model).generate(request)
                result = .success(report.batchId)
            } catch {
                result = .failure(error)
            }
            await self.generationFinished(result, token: token)
        }
    }

    private func generationFinished(_ result: Result<Int64, any Error>, token: Int) async {
        guard token == generationToken else {
            // Started before a language or level change, or a reset: its batch is stale.
            if case .success(let id) = result { try? await store.discardReadyBatch(id) }
            return
        }
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
        // §3.1: an empty library is shown before the LLM-unavailable block.
        if status == .emptyLibrary { return }
        stopRecording()
        speaker.stop()
        // A real failure is what needs retrying; `.resume` never replaces it.
        let keepPending: Bool
        if case .resume = retry { keepPending = isBlocked && self.retry != nil } else { keepPending = false }
        if !keepPending { self.retry = retry }
        status = .unavailable(error.localizedDescription)
    }

    var isBlocked: Bool {
        if case .unavailable = status { return true }
        return false
    }

    /// §1: losing the network blocks at once; when it comes back, the failed operation is
    /// retried automatically.
    func networkChanged(online: Bool) async {
        logger.info("Network \(online ? "online" : "offline", privacy: .public)")
        if online {
            await retryAfterFailure()
        } else {
            if case .failed = status { return }
            if status == .emptyLibrary || status == .starting { return }
            block(LLMError.offline, retry: .resume)
        }
    }

    /// Settings saved or deleted the API key (§1): check it at once.
    func apiKeyChanged() async {
        await checkAccess()
    }

    /// §1: checks the API key (free, no model call) at launch and when it changes. A missing or
    /// rejected key blocks at once instead of at the next LLM call; an accepted key lifts a block.
    func checkAccess() async {
        guard network.isOnline, status != .emptyLibrary else { return }
        if isBlocked {
            await retryAfterFailure()  // re-checks the key itself
            return
        }
        do {
            try await model.verifyAccess()
        } catch {
            logger.error("API key check failed: \(error.localizedDescription, privacy: .public)")
            block(error, retry: .resume)
        }
    }

    /// The Retry button of the blocked screen.
    func retryAfterFailure() async {
        guard isBlocked, let retry else { return }
        guard network.isOnline else {
            status = .unavailable(LLMError.offline.localizedDescription)
            return
        }
        self.retry = nil
        switch retry {
        case .resume:
            do {
                try await model.verifyAccess()
            } catch {
                block(error, retry: .resume)
                return
            }
            status = item == nil ? .waitingForBatch : .practicing
            if batchId == nil {
                startGeneration()
            } else if (try? await store.hasReadyBatch()) == false {
                startGeneration()
            }
        case .generate:
            status = batchId == nil ? .waitingForBatch : .practicing
            startGeneration()
        case .judge(let heard):
            status = .practicing
            await judge(heard: heard)
        }
    }

    // MARK: - Native language (§3.1)

    /// Discards the active and ready batches (and the one being generated) and generates a new
    /// batch in `language`. Events already written are kept.
    func changeLanguage(to language: String) async {
        guard language != nativeLang else { return }
        logger.info("Native language \(self.nativeLang, privacy: .public) → \(language, privacy: .public)")
        nativeLang = language
        stopRecording()
        speaker.stop()
        generationTask?.cancel()
        generationTask = nil
        generationToken += 1  // results of the running generation are discarded
        isGeneratingNext = false
        item = nil
        outcome = nil
        batchId = nil
        batchDone = false
        do {
            try await store.discardCurrentBatches()
        } catch {
            fail(error)
            return
        }
        guard started else { return }
        if isBlocked {
            retry = .generate
            if network.isOnline { await retryAfterFailure() }
        } else {
            status = .waitingForBatch
            startGeneration()
        }
    }

    // MARK: - User level (§3.2)

    /// Discards the `ready` batch and any batch being generated, and generates the next one at
    /// `level`. The `active` batch is finished as is.
    func changeLevel(to level: CEFRLevel) async {
        guard level != userLevel else { return }
        logger.info("User level \(self.userLevel.rawValue, privacy: .public) → \(level.rawValue, privacy: .public)")
        userLevel = level
        generationTask?.cancel()
        generationTask = nil
        generationToken += 1
        isGeneratingNext = false
        do {
            try await store.discardPendingBatches()
        } catch {
            fail(error)
            return
        }
        guard started else { return }
        switch status {
        case .emptyLibrary, .starting:
            stopAll()
            await launch()
        case .practicing, .waitingForBatch:
            do {
                if try await hasContent() {
                    startGeneration()
                } else if batchId == nil {
                    status = .emptyLibrary
                }
            } catch {
                fail(error)
            }
        case .unavailable:
            retry = .generate
            if network.isOnline { await retryAfterFailure() }
        case .failed:
            break
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
            guard self.item == item else { return }  // the batch was discarded meanwhile
            let events = Scorer.events(from: verdict, targets: item.targets)
            await write(Outcome(heard: heard, skipped: false, verdict: verdict, events: events), status: .done, speakAnswer: false)
        } catch {
            guard self.item == item else { return }
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
