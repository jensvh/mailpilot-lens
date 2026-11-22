import Combine
import Foundation

/// Live speech to text on your own server: 16 kHz PCM over the /v1/stream
/// WebSocket, partial and final text back. The key goes in the Authorization
/// header and never anywhere else. Audio goes from the phone straight to that
/// server, never through the relay.
final class SttClient: ObservableObject {
    enum State: Equatable {
        case off, connecting, streaming
        case failed(String)

        var label: String {
            switch self {
            case .off: return "off"
            case .connecting: return "connecting"
            case .streaming: return "on"
            case .failed(let why): return "failed: \(why)"
            }
        }
    }

    @Published private(set) var state: State = .off

    /// Words so far of what is being said (main thread).
    var onPartial: ((String) -> Void)?
    /// A finished utterance (main thread).
    var onFinal: ((String) -> Void)?
    /// The stream ended by itself (main thread).
    var onClosed: ((String) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var buffer = Data()
    private let lock = NSLock()
    private var openedAt = Date()

    var isOn: Bool { task != nil }

    /// GET /health with the key; reports how long it took.
    static func health(base: String, key: String, done: @escaping (String, Bool) -> Void) {
        guard let url = URL(string: base.trimmingCharacters(in: .whitespaces) + "/health") else { done("bad address", false); return }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let started = Date()
        URLSession.shared.dataTask(with: request) { _, response, error in
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text: String
            if let error { text = "unreachable: \(error.localizedDescription)" }
            else if code == 401 { text = "key refused (401)" }
            else { text = "answered \(code) in \(ms) ms" }
            DispatchQueue.main.async { done(text, code == 200) }
        }.resume()
    }

    func start(base: String, key: String) {
        stop()
        var text = base.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("https://") { text = "wss://" + text.dropFirst(8) }
        else if text.hasPrefix("http://") { text = "ws://" + text.dropFirst(7) }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text + "/v1/stream") else {
            state = .failed("bad address")
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let opened = URLSession.shared.webSocketTask(with: request)
        lock.lock(); task = opened; buffer.removeAll(); lock.unlock()
        openedAt = Date()
        state = .connecting
        opened.resume()
        receive(opened)
        // URLSessionWebSocketTask has no open callback: a ping answers once it is up.
        opened.sendPing { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.current === opened else { return }
                if let error {
                    self.closed(opened, error.localizedDescription)
                } else {
                    self.state = .streaming
                    Log.say("speech to text: stream open in \(Int(Date().timeIntervalSince(self.openedAt) * 1000)) ms")
                }
            }
        }
    }

    func stop() {
        lock.lock()
        let old = task
        task = nil
        buffer.removeAll()
        lock.unlock()
        old?.cancel(with: .normalClosure, reason: nil)
        if state != .off { state = .off }
    }

    private var current: URLSessionWebSocketTask? {
        lock.lock(); defer { lock.unlock() }
        return task
    }

    /// Audio thread: collects about 100 ms, then sends one binary frame.
    func feed(_ pcm: Data) {
        lock.lock()
        guard let target = task else { lock.unlock(); return }
        buffer.append(pcm)
        let chunk: Data?
        if buffer.count >= 3200 { chunk = buffer; buffer = Data() } else { chunk = nil }
        lock.unlock()
        guard let chunk else { return }
        target.send(.data(chunk)) { _ in }
    }

    private func receive(_ from: URLSessionWebSocketTask) {
        from.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                let why = error.localizedDescription
                DispatchQueue.main.async { self.closed(from, why) }
            case .success(let message):
                if case .string(let text) = message { self.handle(text) }
                self.receive(from)
            }
        }
    }

    /// Main thread. The stream is over and nobody asked for that.
    private func closed(_ which: URLSessionWebSocketTask, _ why: String) {
        guard current === which else { return }
        lock.lock(); task = nil; buffer.removeAll(); lock.unlock()
        which.cancel(with: .goingAway, reason: nil)
        state = .failed(why)
        Log.say("speech to text: stream closed (\(why))")
        onClosed?(why)
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let type = json["type"] as? String ?? ""
        let words = (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let problem = "\(json["error"] ?? json["message"] ?? "")"
        DispatchQueue.main.async {
            switch type {
            case "partial":
                self.onPartial?(words)
            case "final":
                self.onPartial?("")
                if !words.isEmpty { self.onFinal?(words) }
            case "error":
                Log.say("speech to text: the server reports \(problem)")
            default:
                break
            }
        }
    }
}
