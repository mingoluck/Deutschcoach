import AVFAudio
import Foundation

/// Reads German sentences aloud with `AVSpeechSynthesizer` (DESIGN.md §1). No audio is stored.
final class Speaker: NSObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?
    /// The utterance `continuation` waits for; late callbacks of interrupted utterances are ignored.
    private var current: ObjectIdentifier?

    /// The best installed German voice. Voice selection by the user comes with the settings screen (M6).
    let voice: AVSpeechSynthesisVoice?

    override init() {
        voice = Self.bestGermanVoice()
        super.init()
        synthesizer.delegate = self
    }

    var voiceDescription: String {
        guard let voice else { return "No German voice installed" }
        return "\(voice.name) (\(Self.qualityName(voice.quality)))"
    }

    var hasHighQualityVoice: Bool {
        (voice?.quality ?? .default) != .default
    }

    /// Speaks `text` and returns when it has finished (or was stopped).
    func speak(_ text: String) async {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            current = ObjectIdentifier(utterance)
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        resume()
    }

    fileprivate func finished(_ utterance: ObjectIdentifier) {
        guard utterance == current else { return }
        resume()
    }

    private func resume() {
        continuation?.resume()
        continuation = nil
        current = nil
    }

    // MARK: - Voice selection

    /// Highest quality first (premium > enhanced > default); among equals, prefer the regular
    /// system voices over the Eloquence novelty voices.
    static func bestGermanVoice() -> AVSpeechSynthesisVoice? {
        let german = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "de-DE" }
        let best = german.max { a, b in
            if a.quality != b.quality { return a.quality.rawValue < b.quality.rawValue }
            let aEloquence = a.identifier.contains("eloquence")
            let bEloquence = b.identifier.contains("eloquence")
            if aEloquence != bEloquence { return aEloquence }
            return a.name > b.name
        }
        return best ?? AVSpeechSynthesisVoice(language: "de-DE")
    }

    private static func qualityName(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: "premium"
        case .enhanced: "enhanced"
        default: "default"
        }
    }
}

extension Speaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finished(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finished(id) }
    }
}
