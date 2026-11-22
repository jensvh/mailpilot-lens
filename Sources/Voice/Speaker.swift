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
    /// The utterances still to be said, in order, and the message each belongs to.
    private var jobs: [(utterance: AVSpeechUtterance, id: String)] = []
    private var voices: [String: AVSpeechSynthesisVoice] = [:]

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Says the pieces one after the other. `lead`: a short silence first, for a sound that plays before it.
    func speak(id: String, parts: [LensSay], lead: Double = 0) {
        let wanted = parts.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !wanted.isEmpty else { return }
        // It counts as speaking from now on, before the first callback: whoever asks gets the truth.
        speaking = true
        for (index, part) in wanted.enumerated() {
            let utterance = AVSpeechUtterance(string: part.text)
            utterance.voice = voice(part.lang ?? guess(part.text))
            let span = AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate
            utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate,
                                 max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate + Float(rate - 1) * span * 0.5))
            if index == 0, lead > 0 { utterance.preUtteranceDelay = lead }
            jobs.append((utterance, id))
            synth.speak(utterance)
        }
    }

    /// Something is still being said, or waits to be: by its own count, or by the synthesizer's.
    var busy: Bool { !jobs.isEmpty || synth.isSpeaking }

    /// Stops at once. What was being said, and what waited, counts as cut off.
    func stop() {
        guard busy || speaking else { return }
        var cut: [String] = []
        for job in jobs where !cut.contains(job.id) { cut.append(job.id) }
        jobs = []
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
        DispatchQueue.main.async { self.ended(utterance, done: true) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.ended(utterance, done: false) }
    }

    /// One utterance is over. The synthesizer says them in order, so when it hands back an utterance this list
    /// doesn't know by identity, it is the first one waiting.
    private func ended(_ utterance: AVSpeechUtterance, done: Bool) {
        guard !jobs.isEmpty else { return }  // stop() counted them already
        let index = jobs.firstIndex { $0.utterance === utterance } ?? 0
        let job = jobs.remove(at: index)
        let more = jobs.contains { $0.id == job.id }
        // Not speaking any more is true before anyone is told it finished.
        if jobs.isEmpty { speaking = false }
        if !more { onFinished?(job.id, done) }
    }

    /// The synthesizer went quiet without a word about the rest (it happens): what waited counts as said.
    func settle() {
        guard !synth.isSpeaking, !jobs.isEmpty || speaking else { return }
        var said: [String] = []
        for job in jobs where !said.contains(job.id) { said.append(job.id) }
        jobs = []
        speaking = false
        Log.say("speech: the voice went quiet without saying so; carrying on")
        for id in said { onFinished?(id, true) }
    }
}
