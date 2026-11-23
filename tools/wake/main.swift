import Foundation

// Runs what a speech server may give back through the wake phrase's rules. The
// build compiles it together with Sources/Voice/WakePhrase.swift and runs it on
// the Mac that builds the app, so the rules are tried before anyone walks.

var failures = 0

func check(_ text: String, _ expected: WakePhrase.Heard) {
    let got = WakePhrase.match(text)
    if got == expected {
        print("ok    “\(text)” → \(got)")
    } else {
        failures += 1
        print("FAIL  “\(text)” → \(got), expected \(expected)")
    }
}

// The phrase alone, as it is said and as it is heard.
check("Hey pilot", .woke(rest: ""))
check("Hey, Pilot.", .woke(rest: ""))
check("pilot", .woke(rest: ""))
check("Pilots.", .woke(rest: ""))
check("MailPilot", .woke(rest: ""))
check("Hey MailPilot!", .woke(rest: ""))
check("Hey Mail Pilot.", .woke(rest: ""))
check("mail-pilot", .woke(rest: ""))
check("Male pilot", .woke(rest: ""))
check("Hé pilote", .woke(rest: ""))
check("Hallo piloot", .woke(rest: ""))
check("OK pilot", .woke(rest: ""))
check("Хей пилот", .woke(rest: ""))
check("пилот", .woke(rest: ""))
check("Hey pilat", .woke(rest: ""))
check("Hey pie lot.", .woke(rest: ""))
check("Hey, mail pilots", .woke(rest: ""))

// With a command in the same breath.
check("Hey pilot, triage", .woke(rest: "triage"))
check("Hey Pilot. What's new?", .woke(rest: "What's new?"))
check("Pilot, my day", .woke(rest: "my day"))
check("MailPilot, reply that Friday is fine for me and that Tom joins", .woke(rest: "reply that Friday is fine for me and that Tom joins"))
check("Hey pilot, reply that Friday is fine for me and that Tom joins too", .woke(rest: "reply that Friday is fine for me and that Tom joins too"))
check("Hé pilote, taak voor morgen", .woke(rest: "taak voor morgen"))

// Not the phrase.
check("", .no)
check("So I told the pilot that we would be late", .no)
check("What a nice day for a walk", .no)
check("The pilot episode was better than the rest of it", .no)
check("Hello there, how are you doing today?", .no)
check("Triage", .no)

// Close: logged, not acted on.
check("Pilot episodes are usually better than the rest of them", .near)
check("Hey Pilates", .near)
check("pivot", .near)
check("Hey", .near)
check("Hey you", .near)

if failures > 0 {
    print("\(failures) wake phrase check(s) failed")
    exit(1)
}
print("the wake phrase rules hold")
