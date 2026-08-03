import AVFoundation
import SwiftUI

/// Reads assistant replies aloud. Deliberately plain `AVSpeechSynthesizer` —
/// it is on-device, has no latency to speak of, and needs no permission.
@MainActor
final class Speaker: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        stop()
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = Self.preferredVoice()
        // Slightly above default: the answers are short and a neutral pace
        // reads as sluggish in a transient panel.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    func stop() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    /// Match the system language, and prefer a higher-quality voice when the
    /// user has downloaded one.
    private static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let language = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { language.hasPrefix($0.language.prefix(2)) }

        return candidates.first(where: { $0.quality == .premium })
            ?? candidates.first(where: { $0.quality == .enhanced })
            ?? candidates.first
            ?? AVSpeechSynthesisVoice(language: language)
    }
}

extension Speaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
