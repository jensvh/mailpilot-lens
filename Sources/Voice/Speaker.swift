import AVFoundation
import Combine
import NaturalLanguage

/// Says what MailPilot wants said, with the iPhone's own voices: instant, free,
/// and they work with the phone locked. Each piece is said with a voice of its
/// language, so a Dutch subject inside an English sentence sounds right.
///
/// The sound goes wherever the app's audio session sends it: the glasses while
/// the headset link is up (see `Audio`).
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var speaking = false

    /// A speech message was said to the end (true) or cut off (false). Main thread.
    var onFinished: ((String, Bool) -> Void)?
    /// How fast it talks: 1 is the iPhone's normal speed.
    var rate: Double = 1.0
    /// The language of text that doesn't say which it is.
    var language = "en"

    private let synth = AVSpeechSynthesizer()
    /// The utterances still to be said, and the message each belongs to.
    private var jobs: [ObjectIdentifier: (utterance: AVSpeechUtterance, id: String)] = [:]
    private var left: [String: Int] = [:]
    private var voices: [String: AVSpeechSynthesisVoice] = [:]

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Says the pieces one after the other. `lead`: a short silence first, for a sound that plays before it.
    func speak(id: String, parts: [LensSay], lead: Double = 0) {
        let wanted = parts.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !wanted.isEmpty else { return }
        left[id] = wanted.count
        for (index, part) in wanted.enumerated() {
            let utterance = AVSpeechUtterance(string: part.text)
            utterance.voice = voice(part.lang ?? guess(part.text))
            let span = AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate
            utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate,
                                 max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate + Float(rate - 1) * span * 0.5))
            if index == 0, lead > 0 { utterance.preUtteranceDelay = lead }
            jobs[ObjectIdentifier(utterance)] = (utterance, id)
            synth.speak(utterance)
        }
        speaking = true
    }

    /// Stops at once. What was being said, and what waited, counts as cut off.
    func stop() {
        guard !left.isEmpty || synth.isSpeaking else { return }
        let cut = Array(left.keys)
        left = [:]
        jobs = [:]
        synth.stopSpeaking(at: .immediate)
        speaking = false
        for id in cut { onFinished?(id, false) }
    }

    // MARK: Voices

    /// The best voice on this phone for a language: Belgian first for Dutch and French.
    private func voice(_ language: String) -> AVSpeechSynthesisVoice? {
        let short = String(language.lowercased().prefix(2))
        if let known = voices[short] { return known }
        let codes: [String]
        switch short {
        case "nl": codes = ["nl-BE", "nl-NL"]
        case "fr": codes = ["fr-BE", "fr-FR"]
        default: codes = ["en-GB", "en-US"]
        }
        let all = AVSpeechSynthesisVoice.speechVoices()
        var best: AVSpeechSynthesisVoice?
        for code in codes {
            for candidate in all where candidate.language == code {
                if best == nil || candidate.quality.rawValue > (best?.quality.rawValue ?? 0) { best = candidate }
            }
        }
        let chosen = best ?? AVSpeechSynthesisVoice(language: codes[0])
        if let chosen {
            voices[short] = chosen
            Log.say("voice for \(short): \(chosen.name) (\(chosen.language))")
        }
        return chosen
    }

    /// English, Dutch or French; short text is taken to be in the user's language.
    private func guess(_ text: String) -> String {
        guard text.count >= 16 else { return language }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, .dutch, .french]
        recognizer.processString(text)
        let found = recognizer.dominantLanguage
        if found == .dutch { return "nl" }
        if found == .french { return "fr" }
        if found == .english { return "en" }
        return language
    }

    // MARK: AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        DispatchQueue.main.async { self.ended(key, done: true) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        DispatchQueue.main.async { self.ended(key, done: false) }
    }

    private func ended(_ key: ObjectIdentifier, done: Bool) {
        // One that `stop()` already counted as cut off is no longer listed.
        guard let job = jobs.removeValue(forKey: key) else { return }
        let remaining = (left[job.id] ?? 1) - 1
        if remaining > 0 {
            left[job.id] = remaining
        } else {
            left[job.id] = nil
            onFinished?(job.id, done)
        }
        if left.isEmpty { speaking = false }
    }
}
