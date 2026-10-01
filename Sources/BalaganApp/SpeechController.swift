import AVFoundation
import Foundation
import BalaganCore

/// App-wide text-to-speech for agent responses. One long-lived instance (an `AVSpeechSynthesizer`
/// stops the moment it deallocates, and one voice at a time is the right UX): speaks the
/// `SpeakableText` sentences of a response one utterance at a time, which is what makes
/// sentence-level skip back/forward and the HUD's current-sentence display work — and sidesteps the
/// synthesizer's known range-callback drift on long strings.
@MainActor
final class SpeechController: NSObject, ObservableObject {
    static let shared = SpeechController()

    enum PlaybackState: Equatable {
        case idle
        case speaking
        case paused
    }

    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var sentences: [String] = []
    @Published private(set) var currentIndex = 0
    /// Transient HUD message ("No agent response to speak"), auto-cleared.
    @Published private(set) var notice: String?

    /// Rate presets as multipliers. The synthesizer's 0–1 rate scale is nonlinear, so these map to
    /// values picked by ear rather than arithmetic.
    static let rateMultipliers: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]
    private static let rateValues: [Double: Float] = [
        0.75: 0.42, 1.0: 0.5, 1.25: 0.535, 1.5: 0.565, 2.0: 0.62,
    ]

    @Published var rateMultiplier: Double {
        didSet { UserDefaults.standard.set(rateMultiplier, forKey: Self.rateDefaultsKey) }
    }
    @Published var voiceIdentifier: String? {
        didSet { UserDefaults.standard.set(voiceIdentifier, forKey: Self.voiceDefaultsKey) }
    }

    private static let rateDefaultsKey = "speechRateMultiplier"
    private static let voiceDefaultsKey = "speechVoiceIdentifier"

    private let synthesizer = AVSpeechSynthesizer()
    private let readQueue = DispatchQueue(label: "balagan.speech-transcript-read", qos: .userInitiated)
    /// Sentence index per queued utterance, current batch only. All sentences are enqueued together
    /// (back-to-back playback has no per-sentence gap — the didFinish→speak roundtrip sounded
    /// choppy); callbacks for utterances not in this map (flushed batches) are ignored, which
    /// replaces the fragile one-shot suppress flag.
    private var utteranceIndexes: [ObjectIdentifier: Int] = [:]
    private var noticeDismissal: DispatchWorkItem?

    override private init() {
        let storedRate = UserDefaults.standard.double(forKey: Self.rateDefaultsKey)
        rateMultiplier = Self.rateMultipliers.contains(storedRate) ? storedRate : 1.0
        voiceIdentifier = UserDefaults.standard.string(forKey: Self.voiceDefaultsKey)
        super.init()
        synthesizer.delegate = self
    }

    var isActive: Bool {
        state != .idle
    }

    // MARK: - Entry points

    /// Reads the transcript off-main, extracts the agent's last response, and speaks it.
    func speakLastResponse(transcriptPath: String, format: AgentTranscriptFormat) {
        readQueue.async {
            let text = (try? String(contentsOfFile: transcriptPath, encoding: .utf8))
                .map { AgentTranscriptParser.entries(fromJSONL: $0, format: format) }
                .flatMap { AgentTranscriptParser.lastAssistantResponse(in: $0) }
            DispatchQueue.main.async {
                guard let text else {
                    self.showNotice("No agent response to speak")
                    return
                }
                self.speak(markdown: text)
            }
        }
    }

    func speak(markdown: String) {
        let speakable = SpeakableText.sentences(fromMarkdown: markdown)
        guard speakable.isEmpty == false else {
            showNotice("Nothing speakable in that response")
            return
        }
        flushQueue()
        sentences = speakable
        currentIndex = 0
        state = .speaking
        enqueueSentences(from: 0)
    }

    func showNotice(_ message: String) {
        notice = message
        noticeDismissal?.cancel()
        let dismissal = DispatchWorkItem { [weak self] in self?.notice = nil }
        noticeDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: dismissal)
    }

    // MARK: - Transport

    func stop() {
        flushQueue()
        state = .idle
        sentences = []
        currentIndex = 0
    }

    func togglePause() {
        switch state {
        case .speaking:
            // Word boundary pauses less jarringly; stop (below) is immediate by design.
            synthesizer.pauseSpeaking(at: .word)
            state = .paused
        case .paused:
            synthesizer.continueSpeaking()
            state = .speaking
        case .idle:
            break
        }
    }

    func skip(_ delta: Int) {
        guard isActive, sentences.isEmpty == false else { return }
        let target = min(max(currentIndex + delta, 0), sentences.count - 1)
        flushQueue()
        currentIndex = target
        state = .speaking
        enqueueSentences(from: target)
    }

    func setRateMultiplier(_ multiplier: Double) {
        rateMultiplier = multiplier
        // Take effect mid-playback by re-queueing from the current sentence at the new rate.
        if state == .speaking {
            let index = currentIndex
            flushQueue()
            enqueueSentences(from: index)
        }
    }

    // MARK: - Synthesis

    private func enqueueSentences(from index: Int) {
        guard sentences.indices.contains(index) else {
            state = .idle
            return
        }
        for i in index..<sentences.count {
            let utterance = AVSpeechUtterance(string: sentences[i])
            utterance.rate = Self.rateValues[rateMultiplier] ?? AVSpeechUtteranceDefaultSpeechRate
            if let voice = selectedVoice() {
                utterance.voice = voice
            }
            utteranceIndexes[ObjectIdentifier(utterance)] = i
            synthesizer.speak(utterance)
        }
    }

    /// Sentinel stored in `voiceIdentifier` for an explicit "use the system default voice" choice
    /// (utterances then carry no voice at all). Distinct from nil, which means Automatic.
    static let systemDefaultVoiceChoice = "system-default"

    /// Voice resolution: an explicit choice wins; "System Default" leaves the voice unset; Automatic
    /// (nothing chosen, or the chosen voice was deleted) picks the best-quality installed voice for
    /// the user's language — the compact system default is the main reason TTS sounds robotic.
    /// Resolved per batch so a voice downloaded mid-session gets picked up without a relaunch.
    private func selectedVoice() -> AVSpeechSynthesisVoice? {
        if let voiceIdentifier {
            if voiceIdentifier == Self.systemDefaultVoiceChoice {
                return nil
            }
            if let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
                return voice
            }
        }
        return Self.bestInstalledVoice()
    }

    static func bestInstalledVoice() -> AVSpeechSynthesisVoice? {
        let languagePrefix = Locale.preferredLanguages.first?.prefix(2) ?? "en"
        let best = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(languagePrefix) && $0.quality != .default }
            .max { $0.quality.rawValue < $1.quality.rawValue }
        return best.flatMap { AVSpeechSynthesisVoice(identifier: $0.identifier) }
    }

    private func flushQueue() {
        utteranceIndexes.removeAll()
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    private func utteranceStarted(_ id: ObjectIdentifier) {
        if let index = utteranceIndexes[id] {
            currentIndex = index
        }
    }

    private func utteranceFinished(_ id: ObjectIdentifier) {
        guard let index = utteranceIndexes.removeValue(forKey: id) else {
            return // flushed batch — already superseded by a skip/stop/rate change
        }
        if index == sentences.count - 1 {
            state = .idle
            sentences = []
            currentIndex = 0
        }
    }
}

extension SpeechController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async {
            self.utteranceStarted(id)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async {
            self.utteranceFinished(id)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async {
            // Cancellations only come from our own flush; drop the stale mapping and nothing more.
            self.utteranceIndexes.removeValue(forKey: id)
        }
    }
}

// MARK: - Voice catalog (Settings)

extension SpeechController {
    struct VoiceOption: Identifiable, Equatable {
        var id: String
        var name: String
        var language: String
        var quality: AVSpeechSynthesisVoiceQuality
    }

    /// Every installed voice, unfiltered — the user's language first, then by language, best quality
    /// first within each. Premium/enhanced voices appear only after the user downloads them in
    /// System Settings (there is no API to list or trigger downloads), and Siri voices are never
    /// exposed to apps.
    static func availableVoices() -> [VoiceOption] {
        let languagePrefix = String(Locale.preferredLanguages.first?.prefix(2) ?? "en")
        return AVSpeechSynthesisVoice.speechVoices()
            .sorted { lhs, rhs in
                let lhsIsUserLanguage = lhs.language.hasPrefix(languagePrefix)
                let rhsIsUserLanguage = rhs.language.hasPrefix(languagePrefix)
                if lhsIsUserLanguage != rhsIsUserLanguage {
                    return lhsIsUserLanguage
                }
                if lhs.language != rhs.language {
                    return lhs.language < rhs.language
                }
                if lhs.quality != rhs.quality {
                    return lhs.quality.rawValue > rhs.quality.rawValue
                }
                return lhs.name < rhs.name
            }
            .map {
                VoiceOption(
                    id: $0.identifier,
                    name: voiceDisplayName($0),
                    language: $0.language,
                    quality: $0.quality
                )
            }
    }

    private static func voiceDisplayName(_ voice: AVSpeechSynthesisVoice) -> String {
        // The catalog names already carry "(Enhanced)"/"(Premium)" on some systems; only add the
        // suffix when it's missing so it never doubles up.
        switch voice.quality {
        case .premium where voice.name.contains("Premium") == false: return "\(voice.name) (Premium)"
        case .enhanced where voice.name.contains("Enhanced") == false: return "\(voice.name) (Enhanced)"
        default: return voice.name
        }
    }
}
