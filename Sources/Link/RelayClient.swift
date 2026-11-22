import Foundation

/// A connection to the relay between this phone and MailPilot: Azure Web
/// PubSub, subprotocol json.webpubsub.azure.v1, the same few frames MailPilot's
/// own `LensRelay` uses.
///
/// It reads its groups, writes to a group, and reconnects by itself with a
/// growing pause. Delivery is best effort on purpose: MailPilot sends the whole
/// state after every change, and a phone that reconnects says hello and gets
/// the current one. Everything that passes here is sealed already.
@MainActor
final class RelayClient {
    private static let subprotocol = "json.webpubsub.azure.v1"

    private(set) var connected = false
    /// Why it isn't connected, in a sentence; nil while it is, or before it tried.
    private(set) var problem: String?

    var onStatus: (() -> Void)?
    /// A message arrived: the group it was sent to, and the sealed object.
    var onMessage: ((String, [String: Any]) -> Void)?

    private let name: String
    private let groups: [String]
    private let address: () -> URL?
    private let session = URLSession(configuration: .default)
    private var socket: URLSessionWebSocketTask?
    private var generation = 0
    private var running = false
    private var attempt = 0
    private var ackId = 0
    private var waitingAcks: Set<Int> = []
    /// Sends that wait to hear whether the relay took them.
    private var sendAcks: [Int: (Bool) -> Void] = [:]
    private var retry: Task<Void, Never>?
    private var setupLimit: Task<Void, Never>?
    private var keepAlive: Task<Void, Never>?

    /// - Parameter address: asked again on every (re)connect: MailPilot renews it.
    init(name: String, groups: [String], address: @escaping () -> URL?) {
        self.name = name
        self.groups = groups
        self.address = address
    }

    func start() {
        guard !running else { return }
        running = true
        attempt = 0
        connect()
    }

    func stop() {
        running = false
        generation += 1
        retry?.cancel()
        setupLimit?.cancel()
        keepAlive?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        setStatus(false, nil)
    }

    /// Drops the connection and connects again right away.
    func reconnect(_ why: String) {
        guard running else { return }
        attempt = 0
        dropped(generation, why, soon: true)
    }

    /// Sends a sealed message to a group. False when not connected: the message is gone.
    func send(group: String, data: [String: Any]) -> Bool {
        guard connected else { return false }
        return write(["type": "sendToGroup", "group": group, "dataType": "json", "noEcho": true, "data": data], generation)
    }

    /// Sends and waits for the relay to say it took the message: true when it did, false when it refused (no
    /// right to that group, or an address that ran out), nil when it didn't answer within 10 seconds.
    func sendAcked(group: String, data: [String: Any]) async -> Bool? {
        guard connected else { return false }
        ackId += 1
        let id = ackId
        let gen = generation
        return await withCheckedContinuation { (done: CheckedContinuation<Bool?, Never>) in
            let once = Once()
            sendAcks[id] = { ok in if once.claim() { done.resume(returning: ok) } }
            guard write(["type": "sendToGroup", "group": group, "dataType": "json", "noEcho": true, "ackId": id, "data": data], gen) else {
                sendAcks[id] = nil
                if once.claim() { done.resume(returning: false) }
                return
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                self?.sendAcks[id] = nil
                if once.claim() { done.resume(returning: nil) }
            }
        }
    }

    // MARK: Connecting

    private func connect() {
        guard running else { return }
        generation += 1
        let gen = generation
        guard let url = address() else {
            running = false
            setStatus(false, "No relay address. Pair this phone again.")
            return
        }
        let opened = session.webSocketTask(with: url, protocols: [Self.subprotocol])
        socket = opened
        opened.resume()
        receive(opened, gen)

        // Connected once every group is joined: a message for a group it isn't in yet would be lost.
        waitingAcks = []
        for group in groups {
            ackId += 1
            waitingAcks.insert(ackId)
            _ = write(["type": "joinGroup", "group": group, "ackId": ackId], gen)
        }
        if groups.isEmpty { opened.sendPing { _ in } }
        setupLimit?.cancel()
        setupLimit = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, !Task.isCancelled, gen == self.generation, !self.connected else { return }
            self.dropped(gen, "The relay didn't answer in time.")
        }
    }

    private func write(_ frame: [String: Any], _ gen: Int) -> Bool {
        guard let target = socket, let data = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: data, encoding: .utf8) else { return false }
        target.send(.string(text)) { [weak self] error in
            guard let error else { return }
            let why = RelayClient.explain(error, nil)
            Task { @MainActor in self?.dropped(gen, why) }
        }
        return true
    }

    private func receive(_ from: URLSessionWebSocketTask, _ gen: Int) {
        from.receive { [weak self] result in
            let text: String?
            let failure: String?
            switch result {
            case .failure(let error):
                text = nil
                failure = RelayClient.explain(error, from.response)
            case .success(let message):
                failure = nil
                switch message {
                case .string(let value): text = value
                case .data(let value): text = String(data: value, encoding: .utf8)
                @unknown default: text = nil
                }
            }
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                if let failure {
                    self.dropped(gen, failure)
                    return
                }
                if let text { self.take(text) }
                self.receive(from, gen)
            }
        }
    }

    private func take(_ text: String) {
        guard let frame = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let type = frame["type"] as? String else { return }
        switch type {
        case "message":
            guard frame["from"] as? String == "group", let group = frame["group"] as? String else { return }
            if let data = frame["data"] as? [String: Any] {
                onMessage?(group, data)
            } else if let inner = frame["data"] as? String,
                      let data = (try? JSONSerialization.jsonObject(with: Data(inner.utf8))) as? [String: Any] {
                onMessage?(group, data)
            }
        case "ack":
            guard let id = (frame["ackId"] as? NSNumber)?.intValue else { return }
            // "Duplicate" means the relay had it already: as good as done.
            let ok = (frame["success"] as? Bool) == true
                || ((frame["error"] as? [String: Any])?["name"] as? String) == "Duplicate"
            if let answer = sendAcks.removeValue(forKey: id) {
                if !ok {
                    let why = ((frame["error"] as? [String: Any])?["message"] as? String) ?? "no reason given"
                    Log.say("relay (\(name)): a message was refused: \(why)")
                }
                answer(ok)
                return
            }
            guard waitingAcks.contains(id) else { return }
            guard ok else {
                dropped(generation, "The relay refused this phone. Pair it again in MailPilot.")
                return
            }
            waitingAcks.remove(id)
            if waitingAcks.isEmpty, !connected {
                attempt = 0
                setupLimit?.cancel()
                setStatus(true, nil)
                startKeepAlive(generation)
            }
        case "system":
            if frame["event"] as? String == "disconnected" {
                Log.say("relay (\(name)): the relay ended the connection: \(frame["message"] as? String ?? "no reason given")")
            }
        default:
            break
        }
    }

    /// A ping every 20 seconds keeps the connection from going idle, and notices a dead one.
    private func startKeepAlive(_ gen: Int) {
        keepAlive?.cancel()
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self, !Task.isCancelled, gen == self.generation, let target = self.socket else { return }
                target.sendPing { [weak self] error in
                    guard let error else { return }
                    let why = RelayClient.explain(error, nil)
                    Task { @MainActor in self?.dropped(gen, why) }
                }
            }
        }
    }

    private func dropped(_ gen: Int, _ why: String, soon: Bool = false) {
        guard gen == generation else { return }
        generation += 1
        setupLimit?.cancel()
        keepAlive?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        let waiting = sendAcks
        sendAcks = [:]
        for answer in waiting.values { answer(false) }
        setStatus(false, why)
        guard running else { return }
        // Half a second, doubling to ten, with some spread so two ends don't knock in step.
        let wait = min(10.0, 0.5 * pow(2.0, Double(min(attempt, 5))))
        attempt += 1
        let delay = soon ? 0.2 : wait / 2 + Double.random(in: 0...(wait / 2))
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.connect()
        }
    }

    private func setStatus(_ nowConnected: Bool, _ why: String?) {
        guard connected != nowConnected || problem != why else { return }
        connected = nowConnected
        problem = why
        Log.say("relay (\(name)): \(nowConnected ? "connected" : (why ?? "stopped"))")
        onStatus?()
    }

    /// Why the relay can't be reached, as a sentence.
    nonisolated static func explain(_ error: Error, _ response: URLResponse?) -> String {
        if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            return "The relay refused this phone's address. Pair it again in MailPilot."
        }
        guard let code = (error as? URLError)?.code else {
            return "The connection dropped (\(error.localizedDescription))."
        }
        switch code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return "No internet connection."
        case .timedOut:
            return "The relay didn't answer in time."
        case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed:
            return "The relay can't be reached."
        case .badServerResponse, .userAuthenticationRequired:
            return "The relay refused the connection. If this stays, pair the phone again in MailPilot."
        default:
            return "The connection dropped (\(error.localizedDescription))."
        }
    }
}
