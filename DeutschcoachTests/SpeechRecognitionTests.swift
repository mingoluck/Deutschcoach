import AVFAudio
import Foundation
import Synchronization
import Testing
import os
@testable import Deutschcoach

/// Renders German speech into memory with the system TTS (no files, no microphone).
private func synthesize(_ text: String) async -> [AudioChunk] {
    let synthesizer = AVSpeechSynthesizer()
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "de-DE")
    let chunks = Mutex<[AudioChunk]>([])
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let done = Mutex(false)
        synthesizer.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                // A zero-length buffer marks the end of the utterance.
                let first = done.withLock { finished in
                    defer { finished = true }
                    return !finished
                }
                if first { continuation.resume() }
                return
            }
            chunks.withLock { $0.append(AudioChunk(buffer: pcm)) }
        }
    }
    _ = synthesizer  // keep alive until writing has finished
    return chunks.withLock { $0 }
}

private let logger = Logger(subsystem: "com.ming.Deutschcoach", category: "tests")

private func stream(_ chunks: [AudioChunk]) -> AsyncStream<AudioChunk> {
    AsyncStream { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
    }
}

struct AppleSpeechRecognizerTests {
    /// End to end on the real engine: TTS audio → SpeechAnalyzer → alignment.
    /// Downloads the German model on first run if needed (requires network once).
    @Test(.timeLimit(.minutes(5)))
    func transcribesSynthesizedGerman() async throws {
        let recognizer = AppleSpeechRecognizer()
        guard await recognizer.availability() != .unsupported else {
            Issue.record("German speech recognition is unsupported on this machine")
            return
        }
        try await recognizer.prepare { _ in }

        let sentence = "Ich gebe den Kindern einen Apfel."
        let chunks = await synthesize(sentence)
        #expect(!chunks.isEmpty)

        let volatileUpdates = Mutex(0)
        let transcript = try await recognizer.transcribe(stream(chunks)) { _ in
            volatileUpdates.withLock { $0 += 1 }
        }
        logger.info("Transcript of TTS audio: \(transcript.text, privacy: .public)")

        #expect(transcript.engine == "apple.speech_transcriber")
        #expect(!transcript.isEmpty)
        let alignment = WordAligner.align(sentence: sentence, heard: transcript.text)
        // Synthetic speech is clean, but leave room for one recognition slip.
        #expect(alignment.matchedCount >= alignment.words.count - 1, "heard: \(transcript.text)")
        #expect(volatileUpdates.withLock { $0 } > 0)
    }

    /// Live feedback must appear while the user is still speaking (needs `fastResults`).
    /// Audio is fed at real-time pace, like the microphone.
    @Test(.timeLimit(.minutes(5)))
    func liveTextArrivesWhileSpeaking() async throws {
        let recognizer = AppleSpeechRecognizer()
        guard await recognizer.availability() != .unsupported else { return }  // reported above
        try await recognizer.prepare { _ in }

        let chunks = await synthesize("Wir wohnen seit drei Jahren in Wien und arbeiten jeden Tag in der Stadt.")
        let duration = chunks.reduce(0.0) { $0 + Double($1.buffer.frameLength) / $1.buffer.format.sampleRate }
        let start = ContinuousClock.now
        let paced = AsyncStream<AudioChunk> { continuation in
            Task {
                for chunk in chunks {
                    continuation.yield(chunk)
                    try? await Task.sleep(for: .seconds(Double(chunk.buffer.frameLength) / chunk.buffer.format.sampleRate))
                }
                continuation.finish()
            }
        }
        let firstLiveText = Mutex<Duration?>(nil)
        _ = try await recognizer.transcribe(paced) { text in
            guard !text.isEmpty else { return }
            firstLiveText.withLock { if $0 == nil { $0 = ContinuousClock.now - start } }
        }

        let first = try #require(firstLiveText.withLock { $0 })
        logger.info("First live text after \(first.description, privacy: .public) of \(duration) s audio")
        // Measured ~1.2 s for ~4.7 s of audio; without fastResults it only came after the audio ended.
        #expect(first < .seconds(duration * 0.6))
    }
}

/// A scripted recognizer: shows that callers only depend on the protocol.
private struct FakeRecognizer: SpeechRecognizer {
    var engineName = "fake"
    var heard: String

    func availability() async -> RecognizerAvailability { .ready }
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws { progress(1) }

    func transcribe(_ audio: AsyncStream<AudioChunk>, onVolatile: @escaping @Sendable (String) -> Void) async throws -> Transcript {
        for await _ in audio {}
        onVolatile(heard)
        let words = heard.split(separator: " ").map { Transcript.Word(text: String($0), confidence: 1) }
        return Transcript(text: heard, words: words, engine: engineName)
    }
}

struct FakeRecognizerTests {
    @Test func protocolCanBeSubstituted() async throws {
        let recognizer: any SpeechRecognizer = FakeRecognizer(heard: "Ich gebe den Kinder einen Apfel")
        let transcript = try await recognizer.transcribe(stream([])) { _ in }
        let alignment = WordAligner.align(sentence: "Ich gebe den Kindern einen Apfel.", heard: transcript.text)
        #expect(transcript.engine == "fake")
        #expect(alignment.words[3].status == .substituted(heard: "Kinder"))
    }
}
