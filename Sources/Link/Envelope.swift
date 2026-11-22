import CryptoKit
import Foundation

/// Which way a message travels. Each way has a key of its own, so a message can't be turned around.
enum LensDirection: String {
    /// From the phone to MailPilot.
    case up
    /// From MailPilot to the phone.
    case down
}

/// Seals what the phone and MailPilot say to each other, so the relay between
/// them only ever carries ciphertext. The same scheme as MailPilot's
/// `LensEnvelope`:
///
/// - AES-256-GCM with a random 12-byte nonce; the body is base64 of nonce, ciphertext and tag.
/// - One key per direction, derived with HKDF-SHA256 (no salt) from the key the
///   phone got when it was paired: info "mailpilot-lens up" / "mailpilot-lens down".
/// - The device, the direction and the time are bound in as "lens|1|<device>|<up|down>|<time>".
///
/// What goes through the relay: {"v":1,"d":"<device>","n":<time in ms>,"b":"<base64>"}.
struct LensEnvelope {
    static let keyBytes = 32

    let device: String
    private let up: SymmetricKey
    private let down: SymmetricKey

    init?(device: String, key: Data) {
        guard key.count == Self.keyBytes else { return nil }
        self.device = device
        let secret = SymmetricKey(data: key)
        up = HKDF<SHA256>.deriveKey(inputKeyMaterial: secret, info: Data("mailpilot-lens up".utf8), outputByteCount: Self.keyBytes)
        down = HKDF<SHA256>.deriveKey(inputKeyMaterial: secret, info: Data("mailpilot-lens down".utf8), outputByteCount: Self.keyBytes)
    }

    /// The message, sealed, as the object that goes through the relay.
    func seal(_ direction: LensDirection, _ message: String, at: Int64) -> [String: Any]? {
        guard let box = try? AES.GCM.seal(Data(message.utf8), using: key(direction), nonce: AES.GCM.Nonce(), authenticating: bound(direction, at)),
              let body = box.combined else { return nil }
        return ["v": LensWire.version, "d": device, "n": NSNumber(value: at), "b": body.base64EncodedString()]
    }

    /// The message inside and when it was sealed; nil when it isn't ours, was changed, or can't be read.
    func open(_ direction: LensDirection, _ sealed: [String: Any]) -> (message: String, at: Int64)? {
        guard (sealed["v"] as? NSNumber)?.intValue == LensWire.version,
              sealed["d"] as? String == device,
              let at = (sealed["n"] as? NSNumber)?.int64Value,
              let text = sealed["b"] as? String, let body = Data(base64Encoded: text),
              let box = try? AES.GCM.SealedBox(combined: body),
              let plain = try? AES.GCM.open(box, using: key(direction), authenticating: bound(direction, at)),
              let message = String(data: plain, encoding: .utf8) else { return nil }
        return (message, at)
    }

    /// The same, from the JSON text of a sealed message.
    func open(_ direction: LensDirection, json: String) -> (message: String, at: Int64)? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        return open(direction, object)
    }

    private func key(_ direction: LensDirection) -> SymmetricKey { direction == .up ? up : down }

    private func bound(_ direction: LensDirection, _ at: Int64) -> Data {
        Data("lens|\(LensWire.version)|\(device)|\(direction.rawValue)|\(at)".utf8)
    }
}

/// The time a sender puts on its messages, and the check the receiver does on
/// it: every message is newer than the last one from that sender and not from
/// long ago, so one that was recorded can't be played again later.
final class LensClock {
    /// How far a message's time may be from now: two clocks are never quite the same.
    static let windowMs: Int64 = 5 * 60 * 1000

    private let now: () -> Int64
    private let lock = NSLock()
    private var sent: Int64 = 0
    private var seen: Int64 = 0

    init(now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.now = now
    }

    /// The time for the next message: now, or just after the last one.
    func next() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        sent = max(sent + 1, now())
        return sent
    }

    /// True for a message that is newer than the last one taken and close enough to now.
    func accept(_ at: Int64) -> Bool {
        let current = now()
        lock.lock(); defer { lock.unlock() }
        if at <= seen || abs(current - at) > Self.windowMs { return false }
        seen = at
        return true
    }
}
