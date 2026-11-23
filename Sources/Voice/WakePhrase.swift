import Foundation

// Only Foundation here: the build also compiles this file into a small check
// that runs the phrases below through it (tools/wake).

/// The words that wake it while it sleeps: "hey pilot", "MailPilot", and what a
/// speech server makes of them ("Hey, Pilots.", "hé pilote", "пилот").
///
/// It is matched on the phone, on the text the speech server gave back. A wake
/// only opens the microphone, so a near miss may count when a greeting comes
/// first; without a greeting the word has to be right, and the sentence short.
enum WakePhrase {
    enum Heard: Equatable {
        /// The phrase, and what was said after it in the same breath ("hey pilot, triage": "triage").
        case woke(rest: String)
        /// Close, but not taken: worth a line in the log.
        case near
        case no
    }

    /// How the phrase reads on the phone's own screens.
    static let spoken = "hey pilot"

    // Each list goes through `plain` too, so a word here and the same word heard always compare equal.
    private static let greetings = folded([
        "hey", "he", "hei", "hej", "hay", "heh", "hi", "ey", "ay", "eh", "yo",
        "ok", "okay", "oke", "okee", "hallo", "hello", "halo", "hela",
        "хей", "хэй", "эй", "ок", "окей",
    ])
    /// "Mail pilot" heard as two words.
    private static let mails = folded(["mail", "male", "mel", "meel", "email", "мейл", "мэйл"])
    private static let pilots = folded(["pilot", "pilots", "pilote", "pilotes", "piloot", "piloten", "piloto", "пилот", "пайлот"])
    private static let names = folded(["mailpilot", "mailpilots", "mailpilote", "mailpiloot", "mailpiloto"])

    private static func folded(_ words: [String]) -> Set<String> {
        Set(words.map { WakePhrase.plain($0) })
    }

    static func match(_ text: String) -> Heard {
        let raw = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        // Every word as it sounds: no capitals, accents or punctuation ("Hé," is "he", "mail-pilot" is "mailpilot").
        let words = raw.map(plain)
        guard !words.isEmpty else { return .no }

        var at = 0
        var greeted = false
        while at < words.count, at < 3, words[at].isEmpty || greetings.contains(words[at]) {
            if !words[at].isEmpty { greeted = true }
            at += 1
        }
        guard at < words.count else { return greeted && words.count <= 3 ? .near : .no }

        // How many words the name takes from here, or nil when it isn't there.
        var taken: Int?
        var sure = false
        let first = words[at]
        let second = at + 1 < words.count ? words[at + 1] : ""
        if names.contains(first) {
            taken = 1
            sure = true
        } else if mails.contains(first), pilots.contains(second) || distance(second, "pilot") <= 1 {
            taken = 2
            sure = true
        } else if pilots.contains(first) {
            taken = 1
        } else if greeted {
            // After a greeting a near miss counts: "hey pilat", "hey pie lot", "hey male pilot".
            if distance(first, "pilot") <= 1 || distance(first, "mailpilot") <= 2 {
                taken = 1
            } else if !second.isEmpty, distance(first + second, "pilot") <= 1 || distance(first + second, "mailpilot") <= 2 {
                taken = 2
            }
        }

        guard let taken else {
            let close = words.prefix(4).contains { distance($0, "pilot") <= 2 || distance($0, "mailpilot") <= 3 }
            return words.count <= 6 && (close || (greeted && words.count <= 3)) ? .near : .no
        }

        let after = Array(raw[(at + taken)...])
        let said = after.map(plain).filter { !$0.isEmpty }
        // "Pilot" alone can start an ordinary sentence: without a greeting, only a short command may follow.
        if !greeted, !sure, said.count > 4 { return .near }
        let rest = said.isEmpty ? "" : after.joined(separator: " ").trimmingCharacters(in: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: ".?!")))
        return .woke(rest: rest)
    }

    /// A word without capitals, accents and anything that isn't a letter or a digit.
    static func plain(_ word: String) -> String {
        let folded = word.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    /// How many letters to change, add or drop to get from one word to the other.
    static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                current[j] = min(min(current[j - 1] + 1, previous[j] + 1), previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }
}
