import Foundation
import Observation
import os

private nonisolated let logger = Logger(subsystem: "com.ming.Deutschcoach", category: "speech")

/// Drives the M2 speech test screen: read aloud → record → transcribe → align.
/// The practice engine (M5) will reuse the same pieces.
@Observable
final class SpeechLab {
    enum ModelState: Equatable {
        case checking
        case downloading(Double)
        case ready
        case unavailable(String)
    }

    enum Phase: Equatable {
        case idle
        case speaking
        case recording
        case transcribing
    }

    static let sentences = [
        "Ich gebe den Kindern einen Apfel.",
        "Wir wohnen seit drei Jahren in Wien.",
        "Am Sonntag stehe ich spät auf.",
        "Können Sie mir bitte helfen?",
        "Es gibt heute kein Wasser im Haus.",
    ]

    var sentence = SpeechLab.sentences[0] {
        didSet { if sentence != oldValue { clearResult() } }
    }

    private(set) var modelState: ModelState = .checking
    private(set) var phase: Phase = .idle
    private(set) var liveText = ""
    private(set) var transcript: Transcript?
    private(set) var alignment: Alignment?
    private(set) var errorMessage: String?

    let speaker: Speaker
    private let recognizer: any SpeechRecognizer
    private let recorder = AudioRecorder()
    private var transcription: Task<Transcript, any Error>?

    init(recognizer: any SpeechRecognizer = AppleSpeechRecognizer(), speaker: Speaker = Speaker()) {
        self.recognizer = recognizer
        self.speaker = speaker
    }

    var canRecord: Bool { modelState == .ready && (phase == .idle || phase == .recording) }

    // MARK: - Model

    func prepareModel() async {
        guard modelState != .ready else { return }
        modelState = .checking
        switch await recognizer.availability() {
        case .ready:
            modelState = .ready
        case .unsupported:
            modelState = .unavailable("German speech recognition is not supported on this Mac.")
        case .needsDownload:
            modelState = .downloading(0)
            do {
                try await recognizer.prepare { [weak self] fraction in
                    Task { @MainActor in self?.modelState = .downloading(fraction) }
                }
                modelState = .ready
            } catch {
                logger.error("Model download failed: \(error.localizedDescription, privacy: .public)")
                modelState = .unavailable("Downloading the German speech model failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Actions

    func speak() async {
        guard phase == .idle else { return }
        phase = .speaking
        await speaker.speak(sentence)
        phase = .idle
    }

    func stopSpeaking() {
        speaker.stop()
    }

    func toggleRecording() async {
        switch phase {
        case .idle: await startRecording()
        case .recording: await stopRecording()
        default: break
        }
    }

    // MARK: - Private

    private func startRecording() async {
        clearResult()
        do {
            let audio = try await recorder.start()
            phase = .recording
            let recognizer = self.recognizer
            transcription = Task.detached {
                try await recognizer.transcribe(audio) { [weak self] text in
                    Task { @MainActor in self?.liveText = text }
                }
            }
        } catch {
            fail(error)
        }
    }

    private func stopRecording() async {
        recorder.stop()
        phase = .transcribing
        guard let transcription else { phase = .idle; return }
        do {
            let transcript = try await transcription.value
            self.transcript = transcript
            alignment = WordAligner.align(sentence: sentence, heard: transcript.text)
            liveText = transcript.text
            logger.info("Heard \"\(transcript.text, privacy: .public)\" for \"\(self.sentence, privacy: .public)\"")
        } catch {
            fail(error)
        }
        self.transcription = nil
        phase = .idle
    }

    private func clearResult() {
        liveText = ""
        transcript = nil
        alignment = nil
        errorMessage = nil
    }

    private func fail(_ error: any Error) {
        logger.error("Speech error: \(error.localizedDescription, privacy: .public)")
        errorMessage = error.localizedDescription
        recorder.stop()
        phase = .idle
    }
}
