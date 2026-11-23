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
/// - Asleep with the wake phrase on (Settings): the microphone still goes to
///   your speech server, and nothing of what it hears goes to MailPilot. The
///   phone only looks for "hey pilot" in it, and that wakes it.
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
    /// Asleep, and waiting for the wake phrase: the speech stream is open, and only the phrase counts.
    @Published private(set) var dozing = false

    /// A finished utterance, and whether it was heard while the glasses spoke.
    var onHeard: ((String, Bool) -> Void)?
    /// The wake phrase was said while it slept, with what was said after it in the same breath ("" when nothing).
    var onWakePhrase: ((String) -> Void)?
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
    private var watchdog: Task<Void, Never>?
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
        watchdog?.cancel()
        retry?.cancel()
        gate.mode = .closed
        audio.onPCM = nil
        stt.stop()
        speaker.stop()
        partial = ""
        announced = false
        dozing = false
        setMode(.off)
    }

    // MARK: Waking and sleeping

    /// Opens the microphone (a pinch, the Talk button, a card that expects words). `interrupt`: you asked to
    /// talk, so what is being said stops and it listens at once.
    func wake(_ why: String, chime: Bool = true, interrupt: Bool = false) {
        guard mode != .off else { return }
        serverAsleep = false
        // Awake from here on: what is heard goes to MailPilot again.
        if dozing { dozing = false }
        if interrupt, mode == .speaking {
            Log.say("voice: listening (\(why), it stopped talking)")
            tail?.cancel()
            watchdog?.cancel()
            wasAsleepBeforeSpeech = false
            setMode(.listening)
            speaker.stop()
            gate.mode = .open
            restartQuietTimer()
            return
        }
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
        quietTimer?.cancel()
        retry?.cancel()
        partial = ""
        announced = false
        if settings.wakePhrase {
            // The stream stays open, but from here on only the wake phrase is looked for.
            Log.say("voice: asleep (\(why)), waiting for “\(WakePhrase.spoken)”")
            dozing = true
            gate.mode = .open
            openStream()
        } else {
            Log.say("voice: asleep (\(why))")
            dozing = false
            gate.mode = .closed
            stt.stop()
        }
        if chime { audio.earcon("sleep") }
        setMode(.asleep)
    }

    /// The wake phrase was switched on or off in Settings while it sleeps.
    func wakePhraseChanged(_ on: Bool) {
        guard mode == .asleep, on != dozing else { return }
        dozing = on
        if on {
            Log.say("voice: waiting for “\(WakePhrase.spoken)”")
            retries = 0
            gate.mode = .open
            openStream()
        } else {
            Log.say("voice: no longer waiting for the wake phrase")
            retry?.cancel()
            gate.mode = .closed
            stt.stop()
        }
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
        let parts = (message.parts ?? []).filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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
        } else if mode == .asleep, dozing {
            // It speaks while it waits for the wake phrase: it mustn't wake itself with its own words.
            gate.mode = .silence
        }
        setMode(.speaking)
        watchSpeech()
    }

    /// While it speaks, the microphone hears silence. So "speaking" must end when the voice does, even if the
    /// voice never says it finished: every half second it checks, and after a second and a half of a quiet voice
    /// it goes on as if the speech ended.
    private func watchSpeech() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            var quiet = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, !Task.isCancelled, self.mode == .speaking else { return }
                quiet = self.speaker.busy ? 0 : quiet + 1
                guard quiet >= 3 else { continue }
                self.speaker.settle()
                if self.mode == .speaking, !self.speaker.speaking {
                    Log.say("voice: the speech ended without a word from the voice; listening again")
                    self.tail?.cancel()
                    self.afterSpeech()
                }
                return
            }
        }
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
        watchdog?.cancel()
        guard mode == .speaking else { return }
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
        if dozing {
            // Asleep: nothing is shown and MailPilot isn't told that someone talks.
            if !words.isEmpty { retries = 0 }
            return
        }
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
        if dozing {
            heardAsleep(words)
            return
        }
        guard mode == .listening || mode == .speaking else { return }
        var said = words
        // The phrase said while it is awake already: it isn't part of the command.
        if settings.wakePhrase, mode == .listening, case .woke(let rest) = WakePhrase.match(words) {
            Log.say("wake phrase while awake: “\(words.prefix(80))”")
            restartQuietTimer()
            guard !rest.isEmpty else {
                audio.earcon("wake")
                return
            }
            said = rest
        }
        lastHeard = said
        Log.say("heard: “\(said.prefix(80))”")
        onHeard?(said, mode == .speaking)
        restartQuietTimer()
    }

    /// Something was said while it sleeps with the wake phrase on. Nothing of it goes to MailPilot; the phrase
    /// wakes it. While it speaks nothing counts, so it can't wake itself.
    private func heardAsleep(_ words: String) {
        guard mode == .asleep, !speaker.speaking else { return }
        switch WakePhrase.match(words) {
        case .woke(let rest):
            Log.say("wake phrase: “\(words.prefix(80))”")
            lastHeard = words
            onWakePhrase?(rest)
        case .near:
            Log.say("wake phrase: not taken, “\(words.prefix(80))”")
        case .no:
            break
        }
    }

    /// The stream to the speech server dropped: three quick tries, then a slow one.
    private func streamClosed(_ why: String) {
        guard mode == .listening || mode == .speaking || dozing else { return }
        retries += 1
        if !dozing { problem = "The speech server dropped (\(why)). Trying again." }
        let wait: Double = retries <= 3 ? Double(retries) : (dozing ? 30 : 10)
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self, !Task.isCancelled, self.mode == .listening || self.mode == .speaking || self.dozing else { return }
            self.openStream()
        }
    }

    private func setMode(_ next: Mode) {
        guard mode != next else { return }
        mode = next
        onModeChanged?()
    }
}
