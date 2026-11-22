import Combine
import Foundation
import UIKit

/// This phone's side of the link with MailPilot, the same thing MailPilot's
/// own `LensDeviceClient` does: connect to the relay with the phone's address,
/// read its "down" group, send to its "up" group, everything sealed with the
/// phone's key, and say hello after every connect.
@MainActor
final class Link: ObservableObject {
    enum Status: Equatable {
        /// No pairing code was scanned yet.
        case unpaired
        case connecting
        case online
        /// The relay is reached, but MailPilot doesn't answer.
        case silent
        case offline(String)

        var label: String {
            switch self {
            case .unpaired: return "not paired"
            case .connecting: return "connecting"
            case .online: return "connected"
            case .silent: return "no answer"
            case .offline: return "offline"
            }
        }

        var detail: String? {
            switch self {
            case .unpaired: return "Open the Glasses page in MailPilot, choose Pair a phone and scan the code with the iPhone camera."
            case .silent: return "The relay is reached, but MailPilot doesn't answer. Is it running? Was this phone removed there?"
            case .offline(let why): return why
            default: return nil
            }
        }
    }

    @Published private(set) var status: Status = .unpaired
    /// What MailPilot last said the lens shows.
    @Published private(set) var state: LensState?
    /// The PC this phone is paired with, as it calls itself.
    @Published private(set) var host: String?
    @Published private(set) var pairingNote: String?
    @Published private(set) var pairingBusy = false
    @Published private(set) var roundTripMs: Int?
    @Published private(set) var lastHeardFrom: Date?
    @Published private(set) var warning: String?

    var onState: ((LensState) -> Void)?
    var onSpeak: ((LensSpeak) -> Void)?
    var onStatusChanged: (() -> Void)?
    /// The language to tell MailPilot ("en", "nl"); nil leaves it to MailPilot.
    var language: () -> String? = { nil }

    private var device: String?
    private var envelope: LensEnvelope?
    private var relay: RelayClient?
    private let incoming = LensClock()
    private let outgoing = LensClock()
    private var freshWanted = false
    private var pinger: Task<Void, Never>?
    private var silentTimer: Task<Void, Never>?
    private var pairingTask: Task<Void, Never>?
    private var pingNumber = 0
    private var pingSentAt: [Int: Date] = [:]
    private var unanswered = 0

    private static let keys = ["device", "key", "relay", "host", "speechUrl", "speechKey"]

    init() {
        host = Keychain.read("host")
        if let id = Keychain.read("device"),
           let key = Keychain.read("key").flatMap({ Data(base64Encoded: $0) }),
           let made = LensEnvelope(device: id, key: key) {
            device = id
            envelope = made
            status = .connecting
        }
    }

    var paired: Bool { device != nil }
    var deviceId: String? { device }
    var online: Bool { status == .online }

    /// The speech-to-text server MailPilot told this phone to use.
    var speech: (url: String, key: String)? {
        guard let url = Keychain.read("speechUrl"), !url.isEmpty, let key = Keychain.read("speechKey"), !key.isEmpty else { return nil }
        return (url, key)
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    // MARK: Connecting

    func start() {
        if paired, relay == nil { connect() }
    }

    /// The app came to the front: don't wait out a retry pause.
    func wake() {
        guard paired, let relay, !relay.connected else { return }
        relay.reconnect("The app is in front again; connecting.")
    }

    private func connect() {
        relay?.stop()
        guard let device else { return }
        let client = RelayClient(name: "phone", groups: [LensGroups.down(device)]) {
            Keychain.read("relay").flatMap { URL(string: $0) }
        }
        client.onStatus = { [weak self, weak client] in
            guard let self, let client, client === self.relay else { return }
            self.relayChanged(client)
        }
        client.onMessage = { [weak self] group, sealed in self?.received(group, sealed) }
        relay = client
        setStatus(.connecting)
        client.start()
    }

    private func relayChanged(_ client: RelayClient) {
        if client.connected {
            unanswered = 0
            pingSentAt = [:]
            setStatus(.connecting)
            sayHello()
            // MailPilot answers a hello with the state. When nothing comes it
            // isn't running, or this phone was removed there.
            silentTimer?.cancel()
            silentTimer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self, !Task.isCancelled, self.status == .connecting else { return }
                self.setStatus(.silent)
            }
            startPinging()
        } else {
            pinger?.cancel()
            silentTimer?.cancel()
            setStatus(.offline(client.problem ?? "Not connected."))
        }
    }

    private func setStatus(_ next: Status) {
        guard status != next else { return }
        status = next
        Log.say("link: \(next.label)")
        onStatusChanged?()
    }

    // MARK: Sending

    /// Tells MailPilot this phone is here; it answers with the current state.
    /// `fresh`: a walk starts, so it begins at the home card and says the brief.
    func sayHello(fresh: Bool = false) {
        guard let device else { return }
        if fresh { freshWanted = true }
        if send(.hello(device: device, app: Self.appVersion, language: language(), fresh: freshWanted)) {
            freshWanted = false
        }
    }

    /// Sends a message to MailPilot, sealed. False when not connected: the message is gone.
    @discardableResult
    func send(_ message: LensUp) -> Bool {
        guard let device, let envelope, let relay, relay.connected,
              let sealed = envelope.seal(.up, message.json(), at: outgoing.next()) else { return false }
        return relay.send(group: LensGroups.up(device), data: sealed)
    }

    // MARK: Receiving

    private func received(_ group: String, _ sealed: [String: Any]) {
        // Not for this phone, not sealed with its key, or played again: ignored.
        guard let device, group == LensGroups.down(device), let envelope,
              let opened = envelope.open(.down, sealed) else { return }
        guard incoming.accept(opened.at) else {
            let apart = abs(Int64(Date().timeIntervalSince1970 * 1000) - opened.at)
            if apart > LensClock.windowMs {
                warning = "This phone's clock and the PC's differ by \(apart / 60_000) minutes. Set both to automatic time."
                Log.say("link: a message was refused, the clocks are \(apart / 1000) s apart")
            }
            return
        }
        guard let message = LensDown.read(opened.message) else {
            Log.say("link: a message this version doesn't know")
            return
        }
        lastHeardFrom = Date()
        unanswered = 0
        warning = nil
        silentTimer?.cancel()
        setStatus(.online)

        switch message {
        case .state(let next):
            state = next
            onState?(next)
        case .speak(let speak):
            onSpeak?(speak)
        case .pong(let n):
            if let at = pingSentAt[n] { roundTripMs = Int(Date().timeIntervalSince(at) * 1000) }
            pingSentAt = [:]
        case .config(let config):
            // A fresh address for the next connect, and the speech server.
            if let address = config.relay, !address.isEmpty { Keychain.write("relay", address) }
            if let url = config.speechUrl { Keychain.write("speechUrl", url) }
            if let key = config.speechKey { Keychain.write("speechKey", key) }
        case .paired:
            break
        }
    }

    // MARK: Is MailPilot still there

    private func startPinging() {
        pinger?.cancel()
        pinger = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.ping()
            }
        }
    }

    private func ping() {
        guard let relay, relay.connected else { return }
        if unanswered >= 2 {
            // Two in a row without an answer: MailPilot is gone, or the
            // connection died without saying so. One new connection finds out.
            unanswered = 0
            setStatus(.silent)
            relay.reconnect("MailPilot stopped answering; connecting again.")
            return
        }
        pingNumber += 1
        pingSentAt[pingNumber] = Date()
        unanswered += 1
        send(.ping(pingNumber))
    }

    // MARK: Pairing

    /// A link the app was opened with. True when it was a pairing code.
    func open(_ url: URL) -> Bool {
        guard url.scheme == "mailpilotlens", url.host == "pair" else { return false }
        pair(url.absoluteString)
        return true
    }

    /// Pairs with the code MailPilot shows (scanned, or pasted as text).
    func pair(_ link: String) {
        guard let invite = LensInvite.parse(link) else {
            pairingNote = "That isn't a MailPilot pairing code."
            return
        }
        guard !pairingBusy else { return }
        pairingTask?.cancel()
        pairingTask = Task { [weak self] in await self?.runPairing(invite) }
    }

    /// Asks over the pairing's own two groups, sealed with the code's secret
    /// (which proves this phone saw the code), and waits for its id, key and
    /// address.
    private func runPairing(_ invite: LensInvite) async {
        guard let seal = LensEnvelope(device: "pair-" + invite.pairing, key: invite.secret) else {
            pairingNote = "That pairing code can't be read."
            return
        }
        pairingBusy = true
        pairingNote = "Pairing…"
        defer { pairingBusy = false }
        Log.say("pairing: started")

        let answers = LensClock()
        var answer: LensPaired?
        let client = RelayClient(name: "pairing", groups: [LensGroups.pairDown(invite.pairing)]) { invite.relay }
        client.onMessage = { group, sealed in
            guard group == LensGroups.pairDown(invite.pairing), let opened = seal.open(.down, sealed), answers.accept(opened.at),
                  case .paired(let paired)? = LensDown.read(opened.message) else { return }
            answer = paired
        }
        client.start()
        defer { client.stop() }

        guard await waitUntil(15, { client.connected }) else {
            pairingNote = (client.problem ?? "The relay can't be reached.") + " The code may have run out: show a new one in MailPilot."
            Log.say("pairing: the relay wasn't reached")
            return
        }
        let ask = LensUp.pair(name: UIDevice.current.name, app: Self.appVersion)
        guard let sealed = seal.seal(.up, ask.json(), at: LensClock().next()) else {
            pairingNote = "The request couldn't be sealed. Try again."
            return
        }
        switch await client.sendAcked(group: LensGroups.pairUp(invite.pairing), data: sealed) {
        case true?:
            Log.say("pairing: the relay took the request")
        case false?:
            pairingNote = "The relay refused the request: this code's address has run out. Make a new code in MailPilot."
            Log.say("pairing: the relay refused the request")
            return
        case nil:
            Log.say("pairing: the relay didn't confirm the request; waiting anyway")
        }
        guard await waitUntil(15, { answer != nil }), let paired = answer,
              let key = Data(base64Encoded: paired.key), let made = LensEnvelope(device: paired.device, key: key) else {
            pairingNote = "MailPilot got the request but didn't pair. Its Glasses page says why (most often: the code ran out). Make a new code and scan it."
            Log.say("pairing: no answer from MailPilot")
            return
        }

        relay?.stop()
        relay = nil
        Keychain.write("device", paired.device)
        Keychain.write("key", paired.key)
        Keychain.write("relay", paired.relay)
        Keychain.write("host", paired.host ?? "")
        if let url = paired.speechUrl { Keychain.write("speechUrl", url) }
        if let speechKey = paired.speechKey { Keychain.write("speechKey", speechKey) }
        device = paired.device
        envelope = made
        host = paired.host
        state = nil
        pairingNote = nil
        Log.say("pairing: done")
        connect()
    }

    /// Forgets the pairing. MailPilot keeps the phone in its list until it is removed there.
    func unpair() {
        pairingTask?.cancel()
        pinger?.cancel()
        silentTimer?.cancel()
        relay?.stop()
        relay = nil
        for name in Self.keys { Keychain.delete(name) }
        device = nil
        envelope = nil
        host = nil
        state = nil
        roundTripMs = nil
        setStatus(.unpaired)
    }
}
