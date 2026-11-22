import Foundation

// Opens messages that MailPilot's own code sealed (vectors.json, made with a
// made-up key) and reads them the way the app does. If this passes, the phone
// and MailPilot derive the same keys and agree on every field name. The build
// compiles it together with Sources/Link/Envelope.swift and Protocol.swift and
// runs it on the Mac that builds the app.

var failures = 0

func check(_ ok: Bool, _ what: String) {
    if ok {
        print("ok    \(what)")
    } else {
        failures += 1
        print("FAIL  \(what)")
    }
}

func object(_ json: String) -> NSDictionary? {
    (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? NSDictionary
}

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "tools/interop/vectors.json"
guard let file = FileManager.default.contents(atPath: path),
      let root = (try? JSONSerialization.jsonObject(with: file)) as? [String: Any],
      let device = root["device"] as? String,
      let key = (root["key"] as? String).flatMap({ Data(base64Encoded: $0) }),
      let items = root["items"] as? [[String: Any]],
      let envelope = LensEnvelope(device: device, key: key) else {
    print("FAIL  could not read \(path)")
    exit(1)
}

// The phone's own messages, as this app writes them: they must mean the same as MailPilot's.
let mine: [String: [LensUp]] = [
    "heard": [.heard(text: "reply that Friday is fine", duringSpeech: true)],
    "act": [.act(cardId: "s1-7", action: "delete", rev: 42)],
    "hello": [.hello(device: "abc123", app: "0.1.0 (1)", language: "nl", fresh: true), .hello(device: "abc123", app: nil, language: nil, fresh: false)],
    "speaking": [.speaking],
    "spoke": [.spoke(id: "s1-s3", done: false)],
    "status": [.status(glasses: true, worn: true, battery: 62, mic: "Ray-Ban Display (Bluetooth headset)", display: true),
               .status(glasses: false, worn: false, battery: nil, mic: nil, display: false)],
    "ping": [.ping(7)],
    "pair": [.pair(name: "iPhone", app: "0.1.0 (1)")],
]
var used: [String: Int] = [:]
var kinds = Set<String>()

for item in items {
    guard let way = item["direction"] as? String, let direction = LensDirection(rawValue: way),
          let plain = item["plain"] as? String, let sealedText = item["sealedText"] as? String else {
        check(false, "an item in the file is incomplete")
        continue
    }
    let kind = (object(plain)?["t"] as? String) ?? "?"
    kinds.insert("\(way) \(kind)")

    // 1. It opens with this app's keys, and says what MailPilot wrote.
    let opened = envelope.open(direction, json: sealedText)
    check(opened?.message == plain, "\(way) \(kind): opens")

    // 2. It doesn't open as a message for the other way, or for another device.
    let other: LensDirection = direction == .up ? .down : .up
    check(envelope.open(other, json: sealedText) == nil, "\(way) \(kind): does not open the other way round")
    check(LensEnvelope(device: "someone-else", key: key)?.open(direction, json: sealedText) == nil, "\(way) \(kind): does not open for another device")

    if direction == .down {
        // 3. The app reads it.
        switch LensDown.read(plain) {
        case .state(let state)?:
            let card = state.card
            check(state.rev == 42 && state.sid == "s1" && state.isAsking && state.wantsWords && state.canUndo == true && state.alert == true, "down state: the state's own fields")
            check(state.isAsleep && state.hasEnded, "down state: asleep, ended")
            check(state.deck == "triage" && state.heard == "delete" && state.activity == "Searching mail" && state.note == "Deleted · say undo", "down state: deck, heard, activity, note")
            check(state.counts == LensCounts(needYou: 4, results: 2, today: 5, waiting: 23), "down state: counts")
            check(card?.id == "s1-7" && card?.template == "mail" && card?.icon == "person" && card?.title == "Offer Q4: price by Friday?", "down state: the card's head")
            check(card?.meta == "Ann Lee · 2h · Atlas" && card?.position == "2/7" && card?.page == "1/2" && card?.danger == false && card?.hint == "Say a change, or save", "down state: the card's edges")
            check(card?.lines == ["Asks for the unit price for 200 pieces before Friday's review."], "down state: lines")
            check(card?.chips == [LensChip(text: "Needs a reply", tone: "accent", icon: "reply"), LensChip(text: "Files", tone: "plain", icon: "clip")], "down state: chips")
            check(card?.tiles == [LensTile(value: "4", label: "Need you", icon: "mail")], "down state: tiles")
            check(card?.rows == [LensRow(title: "First row", meta: "meta", icon: "mail", done: false, id: "pick:1"), LensRow(title: "A step", meta: nil, icon: nil, done: true, id: nil)], "down state: rows")
            check(card?.blocks == [LensBlock(start: "14:30", title: "Send quote", minutes: 30, kind: "task", done: false)], "down state: blocks")
            check(card?.actions == [LensAction(id: "reply", label: "Reply", style: "primary", icon: "reply"), LensAction(id: "task", label: "Task", style: "secondary", icon: nil),
                                    LensAction(id: "delete", label: "Delete", style: "danger", icon: nil)], "down state: actions")
        case .speak(let speak)?:
            check(speak.id == "s1-s3" && speak.interrupt == true && speak.earcon == "done", "down speak: id, interrupt, earcon")
            check(speak.parts == [LensSay(text: "From Ann Lee, 2 hours ago.", lang: "en"), LensSay(text: "Offer Q4: prijs tegen vrijdag?", lang: nil)], "down speak: parts")
        case .pong(let n)?:
            check(n == 9, "down pong: its number")
        case .paired(let paired)?:
            check(paired.device == "abc123" && Data(base64Encoded: paired.key) == key && paired.host == "PC", "down paired: device, key, host")
            check(paired.relay == "wss://relay.example/client/hubs/mailpilot?access_token=x" && paired.speechUrl == "https://stt.example" && paired.speechKey == "made-up-speech-key", "down paired: addresses")
        case .config(let config)?:
            check(config.relay == "wss://relay.example/client/hubs/mailpilot?access_token=y" && config.speechUrl == "https://stt.example" && config.speechKey == "made-up-speech-key", "down config: addresses")
        case nil:
            check(false, "down \(kind): the app can't read it")
        }
    } else {
        // 4. What this app would send for the same thing means the same, and survives its own seal.
        let index = used[kind, default: 0]
        used[kind] = index + 1
        guard let list = mine[kind], index < list.count else {
            check(false, "up \(kind): this check has no message of that kind")
            continue
        }
        let text = list[index].json()
        check(object(text) == object(plain), "up \(kind): the app writes the same message")
        check(text.hasPrefix("{\"t\":\"\(kind)\""), "up \(kind): its kind comes first")
        let again = envelope.seal(.up, text, at: 1_795_000_000_100).flatMap { envelope.open(.up, $0) }
        check(again?.message == text && again?.at == 1_795_000_000_100, "up \(kind): sealed and opened again")
    }
}

for expected in ["down state", "down speak", "down pong", "down paired", "down config",
                 "up heard", "up act", "up hello", "up speaking", "up spoke", "up status", "up ping", "up pair"] {
    check(kinds.contains(expected), "the file holds a \(expected)")
}

// A message that was changed on the way doesn't open.
if let first = items.first?["sealedText"] as? String, var sealed = (try? JSONSerialization.jsonObject(with: Data(first.utf8))) as? [String: Any] {
    sealed["n"] = NSNumber(value: 1_795_000_000_999 as Int64)
    check(envelope.open(.down, sealed) == nil, "a changed time doesn't open")
}

// The clock: newer than the last one, and close to now.
var time: Int64 = 1_000_000
let clock = LensClock(now: { time })
check(clock.next() == 1_000_000 && clock.next() == 1_000_001, "the clock never gives the same time twice")
check(clock.accept(1_000_010) && !clock.accept(1_000_010) && !clock.accept(1_000_005), "a message is taken once, and not an older one after it")
check(!clock.accept(1_000_000 + LensClock.windowMs + 1), "a message from too far ahead is refused")
time += 10 * 60 * 1000
check(!clock.accept(1_000_020), "a message from long ago is refused")

// The pairing code.
let relay = "wss://relay.example/client/hubs/mailpilot?access_token=abc"
func base64Url(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
let link = "mailpilotlens://pair?p=p1a2b3&s=\(base64Url(key))&r=\(base64Url(Data(relay.utf8)))"
let invite = LensInvite.parse(link)
check(invite?.pairing == "p1a2b3" && invite?.secret == key && invite?.relay.absoluteString == relay, "the pairing code is read")
check(LensInvite.parse("mailpilotlens://pair?p=p1&s=AAAA&r=\(base64Url(Data(relay.utf8)))") == nil, "a pairing code with a short secret is refused")
check(LensInvite.parse("https://example.com/pair?p=1") == nil, "another link is not a pairing code")

print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
