import AVFAudio
import Foundation

/// Records from the default input device with `AVAudioEngine` and streams the audio in memory.
/// Nothing is written to disk (DESIGN.md §1).
final class AudioRecorder {
    enum RecorderError: Error, LocalizedError {
        case permissionDenied
        case noInputDevice

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                "Microphone access is denied. Allow Deutschcoach in System Settings → Privacy & Security → Microphone."
            case .noInputDevice:
                "No microphone is available."
            }
        }
    }

    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AudioChunk>.Continuation?

    private(set) var isRecording = false

    static var permission: AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }

    /// Shows the system prompt the first time; afterwards returns the stored decision.
    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Starts recording. The returned stream finishes when `stop()` is called.
    func start() async throws -> AsyncStream<AudioChunk> {
        guard await Self.requestPermission() else { throw RecorderError.permissionDenied }
        stop()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw RecorderError.noInputDevice }

        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .unbounded)
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: makeTapBlock(continuation))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            continuation.finish()
            throw error
        }
        self.continuation = continuation
        isRecording = true
        return stream
    }

    func stop() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
        isRecording = false
    }
}

/// Built outside the main actor: the tap runs on the real-time audio thread, and a closure
/// created in a `@MainActor` context would trap there under Swift 6 isolation checks.
private nonisolated func makeTapBlock(_ continuation: AsyncStream<AudioChunk>.Continuation) -> AVAudioNodeTapBlock {
    { buffer, _ in
        // The engine reuses its buffer, so copy the samples before handing them off.
        guard let copy = buffer.copy() as? AVAudioPCMBuffer else { return }
        continuation.yield(AudioChunk(buffer: copy))
    }
}
