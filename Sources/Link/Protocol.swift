import Foundation

// What MailPilot and this app say to each other, version 1. MailPilot owns all
// state: after every change it sends the whole LensState, and what must be
// heard once goes as a `speak`. The phone sends what the user did.
//
// Only Foundation here: the build also compiles this file into a small check
// that opens messages sealed by MailPilot's own code (tools/interop).

enum LensWire {
    static let version = 1
}

// MARK: - MailPilot -> phone

/// Everything needed to draw the lens right now.
struct LensState: Decodable, Equatable {
    var rev: Int
    var sid: String
    /// "idle", "working" or "asking".
    var phase: String?
    var card: LensCard?
    var deck: String?
    /// What it did last, in a few words.
    var note: String?
    /// The note says something didn't work.
    var alert: Bool?
    /// What it heard last, so a mishearing shows.
    var heard: String?
    var activity: String?
    /// The card expects words: the microphone may open by itself.
    var listen: Bool?
    /// The user said "sleep": the microphone stays closed until a pinch.
    var asleep: Bool?
    /// The walk is over: once the summary is said, the phone lets go of the glasses.
    var ended: Bool?
    var canUndo: Bool?
    var counts: LensCounts?

    var isWorking: Bool { phase == "working" }
    var isAsking: Bool { phase == "asking" }
    var wantsWords: Bool { listen ?? false }
    var isAsleep: Bool { asleep ?? false }
    var hasEnded: Bool { ended ?? false }
}

struct LensCounts: Decodable, Equatable {
    var needYou: Int?
    var results: Int?
    var today: Int?
    var waiting: Int?
}

/// One card. The server fills and clamps every field; the phone only draws.
/// `template` stays a string, so a card kind this build doesn't know still draws.
struct LensCard: Decodable, Equatable {
    var id: String
    var template: String
    var icon: String?
    var meta: String?
    var title: String?
    var lines: [String]?
    var chips: [LensChip]?
    var tiles: [LensTile]?
    var rows: [LensRow]?
    var blocks: [LensBlock]?
    var actions: [LensAction]?
    var position: String?
    var page: String?
    var danger: Bool?
    var hint: String?
}

struct LensAction: Decodable, Equatable {
    var id: String
    var label: String
    /// "primary", "secondary" or "danger".
    var style: String?
    var icon: String?
}

struct LensChip: Decodable, Equatable {
    var text: String
    /// "plain", "accent", "good", "warn" or "bad".
    var tone: String?
    var icon: String?
}

struct LensTile: Decodable, Equatable {
    var value: String
    var label: String
    var icon: String?
}

struct LensRow: Decodable, Equatable {
    var title: String
    var meta: String?
    var icon: String?
    var done: Bool?
    /// Set when the row can be picked: the action a pinch on it sends.
    var id: String?
}

struct LensBlock: Decodable, Equatable {
    var start: String
    var title: String
    var minutes: Int?
    var kind: String?
    var done: Bool?
}

/// A piece of speech, with its language when MailPilot knows it ("en", "nl", "fr").
struct LensSay: Decodable, Equatable {
    var text: String
    var lang: String?
}

struct LensSpeak: Decodable, Equatable {
    var id: String
    var parts: [LensSay]?
    /// Stop what is being said first.
    var interrupt: Bool?
    /// A short sound before the words: "done", "error", "ask", "push".
    var earcon: String?
}

struct LensPaired: Decodable, Equatable {
    var device: String
    var key: String
    var relay: String
    var speechUrl: String?
    var speechKey: String?
    var host: String?
}

struct LensConfig: Decodable, Equatable {
    var relay: String?
    var speechUrl: String?
    var speechKey: String?
}

enum LensDown: Equatable {
    case state(LensState)
    case speak(LensSpeak)
    case pong(Int)
    case paired(LensPaired)
    case config(LensConfig)

    private struct Head: Decodable {
        var t: String
        var v: Int?
    }

    private struct StateBody: Decodable { var state: LensState }
    private struct PongBody: Decodable { var n: Int }

    /// A message from MailPilot; nil when it isn't one this version knows.
    static func read(_ json: String) -> LensDown? {
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        guard let head = try? decoder.decode(Head.self, from: data), (head.v ?? LensWire.version) == LensWire.version else { return nil }
        switch head.t {
        case "state": return (try? decoder.decode(StateBody.self, from: data)).map { .state($0.state) }
        case "speak": return (try? decoder.decode(LensSpeak.self, from: data)).map { .speak($0) }
        case "pong": return (try? decoder.decode(PongBody.self, from: data)).map { .pong($0.n) }
        case "paired": return (try? decoder.decode(LensPaired.self, from: data)).map { .paired($0) }
        case "config": return (try? decoder.decode(LensConfig.self, from: data)).map { .config($0) }
        default: return nil
        }
    }
}

// MARK: - phone -> MailPilot

enum LensUp {
    /// The phone connected (again). `fresh`: a walk starts, say the brief.
    case hello(device: String, app: String?, language: String?, fresh: Bool)
    /// A finished utterance. `duringSpeech`: heard while the glasses spoke, so it may be their own voice.
    case heard(text: String, duringSpeech: Bool)
    /// The user started talking.
    case speaking
    /// A button was pinched on the card with this id, drawn from the state with this rev.
    case act(cardId: String, action: String, rev: Int)
    /// A speech message was said to the end (`done`), or cut off.
    case spoke(id: String, done: Bool)
    case status(glasses: Bool, worn: Bool, battery: Int?, mic: String?, display: Bool)
    case ping(Int)
    /// Asks to be paired; sealed with the pairing code's secret.
    case pair(name: String, app: String?)

    var kind: String {
        switch self {
        case .hello: return "hello"
        case .heard: return "heard"
        case .speaking: return "speaking"
        case .act: return "act"
        case .spoke: return "spoke"
        case .status: return "status"
        case .ping: return "ping"
        case .pair: return "pair"
        }
    }

    private var fields: [String: Any] {
        var out: [String: Any] = ["v": LensWire.version]
        switch self {
        case .hello(let device, let app, let language, let fresh):
            out["device"] = device
            if let app { out["app"] = app }
            if let language { out["language"] = language }
            out["fresh"] = fresh
        case .heard(let text, let duringSpeech):
            out["text"] = text
            out["duringSpeech"] = duringSpeech
        case .speaking:
            break
        case .act(let cardId, let action, let rev):
            out["cardId"] = cardId
            out["action"] = action
            out["rev"] = rev
        case .spoke(let id, let done):
            out["id"] = id
            out["done"] = done
        case .status(let glasses, let worn, let battery, let mic, let display):
            out["glasses"] = glasses
            out["worn"] = worn
            if let battery { out["battery"] = battery }
            if let mic { out["mic"] = mic }
            out["display"] = display
        case .ping(let n):
            out["n"] = n
        case .pair(let name, let app):
            out["name"] = name
            if let app { out["app"] = app }
        }
        return out
    }

    /// The message as JSON, its kind ("t") first: older MailPilot builds read it only there.
    func json() -> String {
        let body = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data("{}".utf8)
        let text = String(data: body, encoding: .utf8) ?? "{}"
        return "{\"t\":\"\(kind)\"," + text.dropFirst()
    }
}

// MARK: - The pairing code

/// What a pairing code holds: mailpilotlens://pair?p=<pairing>&s=<secret>&r=<relay address>.
struct LensInvite: Equatable {
    var pairing: String
    var secret: Data
    var relay: URL

    static func parse(_ link: String) -> LensInvite? {
        guard let parts = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "mailpilotlens", parts.host == "pair" else { return nil }
        var values: [String: String] = [:]
        for item in parts.queryItems ?? [] { values[item.name] = item.value ?? "" }
        guard let pairing = values["p"], !pairing.isEmpty,
              let secret = values["s"].flatMap(Base64Url.decode), secret.count == LensEnvelope.keyBytes,
              let address = values["r"].flatMap(Base64Url.decode).flatMap({ String(data: $0, encoding: .utf8) }),
              let relay = URL(string: address), relay.scheme == "wss" || relay.scheme == "ws" else { return nil }
        return LensInvite(pairing: pairing, secret: secret, relay: relay)
    }
}

enum Base64Url {
    static func decode(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}

enum LensGroups {
    static func up(_ device: String) -> String { "up-" + device }
    static func down(_ device: String) -> String { "down-" + device }
    static func pairUp(_ pairing: String) -> String { "pair-up-" + pairing }
    static func pairDown(_ pairing: String) -> String { "pair-down-" + pairing }
}
