import MWDATCore
import SwiftUI

@main
struct LensApp: App {
    @StateObject private var walk: Walk

    init() {
        // The toolkit must be configured once, before anything else uses it.
        do { try Wearables.configure() } catch { print("Wearables.configure failed: \(error)") }
        _walk = StateObject(wrappedValue: Walk())
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(walk)
                .environmentObject(walk.settings)
                .environmentObject(walk.link)
                .environmentObject(walk.audio)
                .environmentObject(walk.stt)
                .environmentObject(walk.voice)
                .environmentObject(walk.glasses)
                .environmentObject(walk.glasses.display)
                .onOpenURL { url in walk.open(url) }
                .preferredColorScheme(.dark)
        }
    }
}
