import Combine
import Foundation

/// What the microphone's audio is used for right now. Read on the audio thread.
final class PcmGate: @unchecked Sendable {
    enum Mode {
        /// Nothing goes to the speech server.
        case closed
        /// Silence goes instead of the microphone: the glasses are speaking, and they shouldn't hear themselves.
        case silence
        case open
    }

    private let lock = NSLock()
    private var value: Mode = .closed

    var mode: Mode {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// Conversation mode: a pinch wakes it, it keeps listening across turns, it
/// opens by itself after it has spoken, and it sleeps when it stays quiet.
///
/// - Listening: the microphone goes to your speech server; what it hears goes
///   to MailPilot as `heard`.
/// - Speaking: MailPilot's words through the glasses. Meanwhile the speech
///   server gets silence, so the glasses don't answer themselves (unless
///   "talk over it" is on in Settings).
/// - Asleep: the headset link stays up (dropping it upsets the glasses), but
///   nothing is sent anywhere. A pinch, or something MailPilot says, wakes it.
@MainActor
final class VoiceLoop: ObservableObject {
    enum Mode: String {
        case off, asleep, listening, speaking
    }

    @Published private(set) var mode: Mode = .off
    /// The words so far of what is being said.
    @Published private(set) var partial = ""
    @Published private(set) var lastHeard = ""
    /// What is wrong with speech to text, when something is.
    @Published private(set) var problem: String?

    /// A finished utterance, and whether it was heard while the glasses spoke.
    var onHeard: ((String, Bool) -> Void)?
    var onSpeakingStarted: (() -> Void)?
    /// A speech message was said to the end, or cut off.
    var onSpoke: ((String, Bool) -> Void)?
    var onModeChanged: (() -> Void)?
    /// Where speech to text is; nil when MailPilot didn't give one.
    var speechServer: () -> (url: String, key: String)? = { nil }

    private let audio: Audio
    private let stt: SttClient
    private let speaker: Speaker
    private let settings: AppSettings
    private let gate = PcmGate()
    private var quietTimer: Task<Void, Never>?
    private var tail: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var retries = 0
    private var serverWantsWords = false
    private var serverAsleep = false
    private var announced = false
    private var wasAsleepBeforeSpeech = false

    init(audio: Audio, stt: SttClient, speaker: Speaker, settings: AppSettings) {
        self.audio = audio
        self.stt = stt
        self.speaker = speaker
        self.settings = settings

        stt.onPartial = { [weak self] words in self?.heardPartial(words) }
        stt.onFinal = { [weak self] words in self?.heardFinal(words) }
        stt.onClosed = { [weak self] why in self?.streamClosed(why) }
        speaker.onFinished = { [weak self] id, done in self?.spoke(id, done) }
    }

    var isOn: Bool { mode != .off }

    /// What happens with each piece of microphone audio. It runs on the audio
    /// thread, so it is made outside the main actor.
    private nonisolated static func feeder(_ gate: PcmGate, _ stt: SttClient) -> (Data) -> Void {
        { pcm in
            switch gate.mode {
            case .open: stt.feed(pcm)
            case .silence: stt.feed(Data(count: pcm.count))
            case .closed: break
            }
        }
    }

    // MARK: A walk starts and ends

    /// The headset link is up: start as asleep, then wake.
    func begin() {
        guard mode == .off else { return }
        audio.onPCM = Self.feeder(gate, stt)
        retries = 0
        problem = nil
        serverAsleep = false
        setMode(.asleep)
        wake("the walk started", chime: false)
    }

    func end() {
        quietTimer?.cancel()
        tail?.cancel()
        retry?.cancel()
        gate.mode = .closed
        audio.onPCM = nil
        stt.stop()
        speaker.stop()
        partial = ""
        announced = false
        setMode(.off)
    }

    // MARK: Waking and sleeping

    /// Opens the microphone (a pinch, the Talk button, a card that expects words).
    func wake(_ why: String, chime: Bool = true) {
        guard mode != .off else { return }
        serverAsleep = false
        if mode == .asleep {
            Log.say("voice: awake (\(why))")
            if chime { audio.earcon("wake") }
            openStream()
            setMode(speaker.speaking ? .speaking : .listening)
        }
        gate.mode = speaker.speaking && !settings.bargeIn ? .silence : .open
        restartQuietTimer()
    }

    /// Closes the microphone until a pinch.
    func sleep(_ why: String, chime: Bool = true) {
        guard mode == .listening || mode == .speaking else { return }
        Log.say("voice: asleep (\(why))")
        quietTimer?.cancel()
        retry?.cancel()
        gate.mode = .closed
        stt.stop()
        partial = ""
        announced = false
        if chime { audio.earcon("sleep") }
        setMode(.asleep)
    }

    /// What MailPilot's state says about listening.
    func follow(_ state: LensState) {
        guard mode != .off else { return }
        let wants = state.wantsWords
        let changed = wants != serverWantsWords
        serverWantsWords = wants
        if state.isAsleep {
            // "Sleep" was said: close the microphone once the answer has been spoken.
            serverAsleep = true
            if !speaker.speaking { sleep("you said sleep") }
            return
        }
        serverAsleep = false
        if wants, changed {
            wake("the card expects words", chime: mode == .asleep)
        } else if changed {
            restartQuietTimer()
        }
    }

    /// Quiet for long enough: sleep. Longer while a card expects words.
    private func restartQuietTimer() {
        quietTimer?.cancel()
        guard mode == .listening || mode == .speaking else { return }
        let seconds = serverWantsWords ? max(10, settings.quietSeconds) : min(15, max(10, settings.quietSeconds))
        quietTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.speaker.speaking || !self.partial.isEmpty {
                self.restartQuietTimer()
            } else {
                self.sleep("quiet for \(seconds) s")
            }
        }
    }

    // MARK: Speech out

    /// Something MailPilot wants heard: a sound, words, or just "stop talking".
    func say(_ message: LensSpeak) {
        guard mode != .off else { return }
        let parts = message.parts ?? []
        if message.interrupt ?? true { speaker.stop() }
        if let earcon = message.earcon { audio.earcon(earcon) }
        guard !parts.isEmpty else { return }
        beginSpeech()
        speaker.speak(id: message.id, parts: parts, lead: message.earcon == nil ? 0 : 0.3)
    }

    /// A line the phone says by itself (offline, the lens is gone).
    func sayLocal(_ text: String, earcon: String? = nil) {
        guard mode != .off else { return }
        if let earcon { audio.earcon(earcon) }
        beginSpeech()
        speaker.speak(id: "local-\(UUID().uuidString.prefix(6))", parts: [LensSay(text: text, lang: settings.spokenLanguage)], lead: earcon == nil ? 0 : 0.3)
    }

    func stopSpeaking() {
        speaker.stop()
    }

    private func beginSpeech() {
        tail?.cancel()
        speaker.rate = settings.speechRate
        speaker.language = settings.spokenLanguage
        if mode != .speaking { wasAsleepBeforeSpeech = mode == .asleep }
        if mode == .listening {
            gate.mode = settings.bargeIn ? .open : .silence
        }
        setMode(.speaking)
    }

    private func spoke(_ id: String, _ done: Bool) {
        if !id.hasPrefix("local-") { onSpoke?(id, done) }
        guard mode == .speaking, !speaker.speaking else { return }
        // A short tail, so the last word's echo isn't taken for an answer.
        tail?.cancel()
        tail = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, !Task.isCancelled, self.mode == .speaking, !self.speaker.speaking else { return }
            self.afterSpeech()
        }
    }

    /// It has spoken: the microphone opens by itself, unless you said "sleep".
    private func afterSpeech() {
        if serverAsleep {
            setMode(.listening)
            sleep("you said sleep")
            return
        }
        if wasAsleepBeforeSpeech {
            wasAsleepBeforeSpeech = false
            setMode(.asleep)
            wake("it spoke")
            return
        }
        gate.mode = .open
        setMode(.listening)
        restartQuietTimer()
    }

    // MARK: Speech in

    private func openStream() {
        guard !stt.isOn else { return }
        guard let server = speechServer() else {
            problem = "No speech server. Set one in MailPilot (Settings, Speech), then pair again or reconnect."
            return
        }
        stt.start(base: server.url, key: server.key)
    }

    private func heardPartial(_ words: String) {
        guard mode == .listening || mode == .speaking else { return }
        partial = words
        guard !words.isEmpty else { return }
        if problem != nil { problem = nil }
        retries = 0
        if !announced {
            announced = true
            onSpeakingStarted?()
        }
        // Talking over it stops it (only with "talk over it" on: otherwise it hears silence while it speaks).
        if mode == .speaking, settings.bargeIn, words.split(separator: " ").count >= 2 {
            speaker.stop()
        }
        restartQuietTimer()
    }

    private func heardFinal(_ words: String) {
        announced = false
        partial = ""
        guard mode == .listening || mode == .speaking else { return }
        lastHeard = words
        Log.say("heard: “\(words.prefix(80))”")
        onHeard?(words, mode == .speaking)
        restartQuietTimer()
    }

    /// The stream to the speech server dropped: three quick tries, then a slow one.
    private func streamClosed(_ why: String) {
        guard mode == .listening || mode == .speaking else { return }
        retries += 1
        problem = "The speech server dropped (\(why)). Trying again."
        let wait: Double = retries <= 3 ? Double(retries) : 10
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self, !Task.isCancelled, self.mode == .listening || self.mode == .speaking else { return }
            self.openStream()
        }
    }

    private func setMode(_ next: Mode) {
        guard mode != next else { return }
        mode = next
        onModeChanged?()
    }
}
