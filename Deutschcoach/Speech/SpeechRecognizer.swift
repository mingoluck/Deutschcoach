import AVFAudio
import Foundation

/// A chunk of recorded audio, kept in memory only (no audio is ever written to disk).
///
/// `AVAudioPCMBuffer` is not `Sendable`. Each chunk owns a private copy of the samples that is
/// never mutated after creation, so handing it across concurrency domains is safe.
nonisolated struct AudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

/// The result of recognizing one utterance.
nonisolated struct Transcript: Sendable, Equatable {
    struct Word: Sendable, Equatable {
        var text: String
        /// 0...1 when the engine reports it.
        var confidence: Double?
    }

    var text: String
    var words: [Word]
    /// Identifies the recognition engine; stored in `practice_event.detail` (DESIGN.md §2.2).
    var engine: String

    var isEmpty: Bool { words.isEmpty }
}

nonisolated enum RecognizerAvailability: Sendable, Equatable {
    case unsupported
    /// The model is supported but has to be downloaded first.
    case needsDownload
    case ready
}

/// Speech recognition, abstracted so engines can be swapped and faked in tests (DESIGN.md §1).
///
/// Implementations must never bias recognition toward the expected sentence (DESIGN.md §3.4).
nonisolated protocol SpeechRecognizer: Sendable {
    var engineName: String { get }

    func availability() async -> RecognizerAvailability

    /// Makes the model available, downloading it if needed. `progress` receives 0...1.
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws

    /// Transcribes audio until `audio` finishes. `onVolatile` receives the in-progress text
    /// (finalized part plus current guess) for live display only.
    func transcribe(
        _ audio: AsyncStream<AudioChunk>,
        onVolatile: @escaping @Sendable (String) -> Void
    ) async throws -> Transcript
}
