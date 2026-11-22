import Combine
import Foundation

/// What can be chosen in Settings. Nothing secret here: keys live in the Keychain.
@MainActor
final class AppSettings: ObservableObject {
    private let store = UserDefaults.standard

    /// "auto" (the iPhone's language), "en" or "nl".
    @Published var language: String { didSet { store.set(language, forKey: "language") } }
    /// How fast it talks: 1 is the iPhone's normal speed.
    @Published var speechRate: Double { didSet { store.set(speechRate, forKey: "speechRate") } }
    /// Show cards on the glasses. Off: the phone alone, voice and its own screen.
    @Published var useLens: Bool { didSet { store.set(useLens, forKey: "useLens") } }
    /// Keep listening while it speaks, so you can talk over it. Only when the
    /// microphone doesn't pick up the glasses' own speakers.
    @Published var bargeIn: Bool { didSet { store.set(bargeIn, forKey: "bargeIn") } }
    /// How long the microphone stays open without anything being said.
    @Published var quietSeconds: Int { didSet { store.set(quietSeconds, forKey: "quietSeconds") } }
    /// A card older than this is shown on a new glasses session, in case the
    /// app was closed on the glasses meanwhile. 0: never.
    @Published var staleSeconds: Int { didSet { store.set(staleSeconds, forKey: "staleSeconds") } }
    /// A tap on the glasses' frame (a media button) opens the microphone.
    @Published var tapWakes: Bool { didSet { store.set(tapWakes, forKey: "tapWakes") } }
    /// The day plan goes to the lens as a drawn timeline instead of lines of text.
    @Published var drawPictures: Bool { didSet { store.set(drawPictures, forKey: "drawPictures") } }

    init() {
        language = store.string(forKey: "language") ?? "auto"
        speechRate = store.object(forKey: "speechRate") as? Double ?? 1.0
        useLens = store.object(forKey: "useLens") as? Bool ?? true
        bargeIn = store.object(forKey: "bargeIn") as? Bool ?? false
        quietSeconds = store.object(forKey: "quietSeconds") as? Int ?? 45
        staleSeconds = store.object(forKey: "staleSeconds") as? Int ?? 45
        tapWakes = store.object(forKey: "tapWakes") as? Bool ?? false
        drawPictures = store.object(forKey: "drawPictures") as? Bool ?? true
    }

    /// "en" or "nl": the chosen language, or the iPhone's when it is one of the two.
    var spokenLanguage: String {
        if language == "en" || language == "nl" { return language }
        let phone = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return phone.hasPrefix("nl") ? "nl" : "en"
    }
}
