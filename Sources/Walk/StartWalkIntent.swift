import AppIntents
import UIKit

/// "Start walk" for Siri, the Shortcuts app and the Action button. It opens
/// the app first: iOS only lets an app open the microphone while it is in
/// front. After that it does what the Start walk button does.
struct StartWalkIntent: AppIntent {
    static var title: LocalizedStringResource = "Start walk"
    static var description = IntentDescription("Opens MailPilot Lens and starts a walk: the microphone opens and you hear the brief.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Just launched: wait until the app is there and in front.
        _ = await waitUntil(6, step: 0.2) { Walk.current != nil && UIApplication.shared.applicationState == .active }
        guard let walk = Walk.current else {
            return .result(dialog: "MailPilot Lens didn't open.")
        }
        if UIApplication.shared.applicationState != .active {
            Log.say("shortcut: the app isn't in front; the microphone may be refused")
        }
        let said = walk.startFromShortcut()
        return .result(dialog: IntentDialog(stringLiteral: said))
    }
}

/// The phrases Siri knows without any setting up. Each has to name the app.
struct LensShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartWalkIntent(),
            phrases: [
                "Start a walk with \(.applicationName)",
                "Start a \(.applicationName) walk",
                "Start walk in \(.applicationName)",
            ],
            shortTitle: "Start walk",
            systemImageName: "figure.walk")
    }
}
