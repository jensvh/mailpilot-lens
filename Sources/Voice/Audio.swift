import AVFoundation
import Combine
import MediaPlayer
import UIKit

/// Microphone and sound through the glasses' Bluetooth headset link (or, with
/// no glasses, the iPhone's own microphone and speaker). One engine gives the
/// level meter, 16 kHz PCM for the speech server, and the short sounds.
///
/// `running` means the headset link (HFP) is up. It is never switched as a side
/// effect: on these glasses, bringing it up while a toolkit session is open
/// ends that session (Meta, ios#342), and switching it on and off a few times
/// can make the glasses refuse sessions (ios#375). `Walk` brings it up once,
/// before any session, and takes it down once, after the last one.
final class Audio: NSObject, ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var level: Double = 0
    @Published private(set) var input = "—"
    @Published private(set) var output = "—"
    @Published private(set) var viaGlasses = false

    /// Called on the audio thread with 16 kHz, 16-bit mono PCM.
    var onPCM: ((Data) -> Void)?
    var onRouteChanged: (() -> Void)?
    /// A media button: a tap on the glasses' frame arrives as play/pause.
    var onMediaKey: ((String) -> Void)?
    /// A call or another app took the sound (true), or gave it back (false).
    var onInterrupted: ((Bool) -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private let toneFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var lastLevelAt = Date.distantPast
    private var remoteReady = false
    private var peak: Float = 0
    private let lock = NSLock()

    override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.refreshRoute()
            Log.say("audio route: in \(self.input), out \(self.output)")
            self.onRouteChanged?()
        }
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            guard let self, (note.object as? AVAudioEngine) === self.engine, self.running else { return }
            Log.say("audio configuration changed: restarting the engine")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.running else { return }
                Log.say(self.startEngine() ? "audio engine restarted: in \(self.input)" : "audio engine did not restart")
            }
        }
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            let began = AVAudioSession.InterruptionType(rawValue: raw) == .began
            Log.say(began ? "audio interrupted (a call or another app)" : "audio interruption ended")
            if !began, self.running {
                try? self.session.setActive(true)
                _ = self.startEngine()
            }
            self.onInterrupted?(began)
        }
        // The audio system restarted (rare): rebuild everything.
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.running else { return }
            Log.say("the iPhone's audio system restarted")
            self.running = false
            Log.say(self.begin() ? "audio rebuilt" : "audio could not be rebuilt")
        }
    }

    // MARK: Start and stop

    /// Asks for the microphone (only possible with the app in front) and starts.
    func startAsync() async -> Bool {
        await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            start { done.resume(returning: $0) }
        }
    }

    func start(completion: @escaping (Bool) -> Void = { _ in }) {
        if running { completion(true); return }
        AVAudioApplication.requestRecordPermission { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self else { return }
                guard allowed else {
                    Log.say("microphone permission denied: allow it in Settings → MailPilot Lens")
                    completion(false)
                    return
                }
                completion(self.begin())
            }
        }
    }

    private func begin() -> Bool {
        do {
            // playAndRecord + hands-free profile = iOS offers the glasses' microphone.
            // Without a headset the sound goes to the loudspeaker, not the earpiece.
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            Log.say("audio session failed: \(error.localizedDescription)")
            return false
        }
        if let glasses = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
            try? session.setPreferredInput(glasses)
        }
        refreshRoute()
        guard startEngine() else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            return false
        }
        setUpMediaKeys()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: "MailPilot Lens", MPMediaItemPropertyArtist: "On a walk"]
        running = true
        Log.say("audio on: in \(input), out \(output)")
        return true
    }

    func stop() {
        guard running else { return }
        running = false
        player.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Give the glasses' media buttons and sound back to other apps.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Log.say("audio: releasing the audio session failed: \(error.localizedDescription)")
        }
        level = 0
        Log.say("audio off (headset link released)")
    }

    /// A fresh engine each time: after a route change an old one can keep the
    /// previous microphone's format.
    private func startEngine() -> Bool {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        let mic = engine.inputNode
        let format = mic.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            Log.say("no usable microphone (\(format.sampleRate) Hz)")
            return false
        }
        converter = AVAudioConverter(from: format, to: pcmFormat)
        mic.installTap(onBus: 0, bufferSize: 1600, format: format) { [weak self] buffer, _ in
            self?.received(buffer)
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: toneFormat)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            Log.say("audio engine failed: \(error.localizedDescription)")
            return false
        }
        return true
    }

    /// Audio thread.
    private func received(_ buffer: AVAudioPCMBuffer) {
        var rms: Float = 0
        if let samples = buffer.floatChannelData?[0] {
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += samples[i] * samples[i] }
            if n > 0 { rms = (sum / Float(n)).squareRoot() }
        }
        lock.lock()
        peak = max(peak, rms)
        lock.unlock()

        if let onPCM, let converter {
            let ratio = pcmFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            if let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: capacity) {
                var fed = false
                var error: NSError?
                converter.convert(to: out, error: &error) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true
                    status.pointee = .haveData
                    return buffer
                }
                if error == nil, out.frameLength > 0, let data = out.int16ChannelData?[0] {
                    onPCM(Data(bytes: data, count: Int(out.frameLength) * 2))
                }
            }
        }

        let now = Date()
        if now.timeIntervalSince(lastLevelAt) > 0.1 {
            lastLevelAt = now
            let value = Double(min(1, rms * 6))
            DispatchQueue.main.async { self.level = value }
        }
    }

    /// The loudest the microphone has been since `resetPeak()`.
    var currentPeak: Float {
        lock.lock(); defer { lock.unlock() }
        return peak
    }

    func resetPeak() {
        lock.lock(); peak = 0; lock.unlock()
    }

    // MARK: Short sounds

    /// The sound that goes with something: the microphone opened or closed,
    /// done, a problem, a question, something new.
    func earcon(_ name: String) {
        switch name {
        case "wake": tones([(660, 0.07), (990, 0.09)])
        case "sleep": tones([(660, 0.07), (440, 0.1)])
        case "done": tones([(880, 0.09)])
        case "error": tones([(220, 0.12), (0, 0.05), (220, 0.14)])
        case "ask": tones([(740, 0.08), (988, 0.12)])
        case "push": tones([(988, 0.07), (0, 0.04), (1319, 0.1)])
        default: break
        }
    }

    /// Plays tones one after the other; a frequency of 0 is a pause.
    private func tones(_ parts: [(Double, Double)]) {
        guard running, engine.isRunning else { return }
        let rate = toneFormat.sampleRate
        let total = AVAudioFrameCount(parts.reduce(0) { $0 + $1.1 } * rate)
        guard total > 0, let buffer = AVAudioPCMBuffer(pcmFormat: toneFormat, frameCapacity: total),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = total
        var at = 0
        for (frequency, seconds) in parts {
            let count = min(Int(seconds * rate), Int(total) - at)
            if count <= 0 { continue }
            for i in 0..<count {
                let t = Double(i) / rate
                let fade = min(1.0, min(t, seconds - t) / 0.008)
                samples[at + i] = frequency > 0 ? Float(sin(2.0 * Double.pi * frequency * t) * 0.28 * fade) : 0
            }
            at += count
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    // MARK: Route

    private func refreshRoute() {
        let route = session.currentRoute
        let mic = route.inputs.first
        input = mic.map { "\($0.portName) (\(kind($0.portType)))" } ?? "none"
        output = route.outputs.map { "\($0.portName) (\(kind($0.portType)))" }.joined(separator: ", ")
        if output.isEmpty { output = "none" }
        viaGlasses = mic?.portType == .bluetoothHFP || mic?.portType == .bluetoothLE
    }

    private func kind(_ type: AVAudioSession.Port) -> String {
        switch type {
        case .bluetoothHFP: return "Bluetooth headset"
        case .bluetoothA2DP: return "Bluetooth audio"
        case .bluetoothLE: return "Bluetooth LE"
        case .builtInMic: return "iPhone mic"
        case .builtInSpeaker: return "iPhone speaker"
        case .builtInReceiver: return "iPhone earpiece"
        default: return type.rawValue
        }
    }

    // MARK: Media buttons (taps on the glasses)

    private func setUpMediaKeys() {
        guard !remoteReady else { return }
        remoteReady = true
        let center = MPRemoteCommandCenter.shared()
        let commands: [(String, MPRemoteCommand)] = [
            ("play", center.playCommand), ("pause", center.pauseCommand),
            ("play/pause", center.togglePlayPauseCommand), ("next", center.nextTrackCommand),
            ("previous", center.previousTrackCommand), ("stop", center.stopCommand),
        ]
        for (name, command) in commands {
            command.isEnabled = true
            _ = command.addTarget { [weak self] _ in
                DispatchQueue.main.async {
                    Log.say("media button: \(name)")
                    self?.onMediaKey?(name)
                }
                return .success
            }
        }
    }
}
