import AVFAudio
import Foundation
import Speech

/// On-device German recognition with `SpeechAnalyzer` + `SpeechTranscriber` (DESIGN.md §1).
nonisolated final class AppleSpeechRecognizer: SpeechRecognizer {
    enum RecognizerError: Error, LocalizedError {
        case localeUnsupported(String)
        case modelNotInstalled

        var errorDescription: String? {
            switch self {
            case .localeUnsupported(let id): "Speech recognition does not support \(id) on this Mac."
            case .modelNotInstalled: "The German speech model is not installed yet."
            }
        }
    }

    let engineName = "apple.speech_transcriber"
    private let requestedLocale: Locale

    init(locale: Locale = Locale(identifier: "de-DE")) {
        requestedLocale = locale
    }

    // MARK: - Model

    func availability() async -> RecognizerAvailability {
        guard let transcriber = try? await makeTranscriber() else { return .unsupported }
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed: return .ready
        case .supported, .downloading: return .needsDownload
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        let transcriber = try await makeTranscriber()
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            progress(1)
            return  // already installed
        }
        let observed = request.progress
        let poller = Task {
            while !Task.isCancelled {
                progress(observed.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { poller.cancel() }
        try await request.downloadAndInstall()
        progress(1)
    }

    // MARK: - Transcription

    func transcribe(
        _ audio: AsyncStream<AudioChunk>,
        onVolatile: @escaping @Sendable (String) -> Void
    ) async throws -> Transcript {
        let transcriber = try await makeTranscriber()
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw RecognizerError.modelNotInstalled
        }
        // No AnalysisContext / contextualStrings: recognition must not be biased (DESIGN.md §3.4).
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let converter = try await AnalyzerInputConverter.converter(compatibleWith: [transcriber])
        let (input, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)

        // Start consuming results before audio flows in.
        let collector = Task {
            var finalized = AttributedString()
            for try await result in transcriber.results {
                if result.isFinal {
                    finalized += result.text
                    onVolatile(String(finalized.characters))
                } else {
                    onVolatile(String((finalized + result.text).characters))
                }
            }
            return finalized
        }

        do {
            try await analyzer.start(inputSequence: input)
            for await chunk in audio {
                for item in try converter.convert(chunk.buffer, at: nil) {
                    inputContinuation.yield(item)
                }
            }
            for item in try converter.flush() {
                inputContinuation.yield(item)
            }
            inputContinuation.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            inputContinuation.finish()
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }

        let text = try await collector.value
        return Transcript(
            text: String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines),
            words: Self.words(from: text),
            engine: engineName
        )
    }

    // MARK: - Private

    private func makeTranscriber() async throws -> SpeechTranscriber {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw RecognizerError.localeUnsupported(requestedLocale.identifier)
        }
        return SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.transcriptionConfidence]
        )
    }

    /// Splits the transcription into words, carrying over the per-run confidence.
    private static func words(from text: AttributedString) -> [Transcript.Word] {
        var words: [Transcript.Word] = []
        for run in text.runs {
            let piece = String(text[run.range].characters)
            let confidence = run.transcriptionConfidence
            for word in piece.split(whereSeparator: \.isWhitespace) {
                words.append(.init(text: String(word), confidence: confidence))
            }
        }
        return words
    }
}
