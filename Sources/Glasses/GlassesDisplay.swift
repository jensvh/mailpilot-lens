// No SwiftUI in this file: MWDATDisplay has its own Text, Button and Image.
import Combine
import Foundation
import MWDATCore
import MWDATDisplay

/// The lens (MWDATDisplay), taken from Stride Lab.
///
/// - The display doesn't wait for the glasses the way a camera does: asked for
///   while the glasses are still arriving, it fails once. It is retried.
/// - Closing is confirmed: clear, stop, wait for stopped.
/// - Each instance has a generation number; callbacks from an older one are
///   ignored.
@MainActor
final class GlassesDisplay: ObservableObject {
    @Published private(set) var phase: Phase = .off
    /// How long the last card took to send.
    @Published private(set) var sendMs: Int?
    private(set) var lastError = ""
    /// Set when the session refuses a new display (already active): only a new
    /// session can bring it back.
    private(set) var needsNewSession = false
    private(set) var lastSentAt: Date?
    /// A card was shown in this session (it may have been closed on the
    /// glasses since, which the toolkit doesn't report).
    private(set) var usedInSession = false

    var onLog: ((String) -> Void)?

    private var display: Display?
    private var displayGen = 0
    private var displayTokens: [any AnyListenerToken] = []
    private var closingDisplay = false

    var isOpen: Bool { display != nil }

    /// Sends a view to the lens. fresh: restart the display first (a display
    /// can report "started" while the lens shows Meta's home).
    func show(on session: DeviceSession, view: FlexBox, fresh: Bool) async -> Bool {
        guard let target = await attachDisplay(to: session, fresh: fresh) else { return false }
        do {
            let started = Date()
            try await target.send(view)
            sendMs = Int(Date().timeIntervalSince(started) * 1000)
            lastSentAt = Date()
            usedInSession = true
            onLog?("display: card sent in \(sendMs ?? 0) ms")
            return true
        } catch {
            lastError = "sending the card failed: \(error)"
            onLog?("display: \(lastError)")
            return false
        }
    }

    private func attachDisplay(to session: DeviceSession, fresh: Bool) async -> Display? {
        needsNewSession = false
        if let current = display, current.state == .started, !fresh { return current }
        if display != nil {
            onLog?("display: restarting it")
            await closeDisplay(clear: false)
        }
        phase = .starting
        var lastFailure = ""
        for attempt in 1...10 {
            if Task.isCancelled { break }
            do {
                let capability = try session.addDisplay()
                displayGen += 1
                let gen = displayGen
                display = capability
                displayTokens.append(capability.statePublisher.listen { [weak self] state in
                    Task { @MainActor in self?.displayStateChanged(state, gen: gen) }
                })
                capability.start()
                _ = await waitUntil(5, step: 0.1) { capability.state == .started }
                if capability.state == .started, displayGen == gen {
                    phase = .on
                    onLog?("display: started (attempt \(attempt))")
                    return capability
                }
                lastFailure = "the display did not start (\(capability.state))"
                await closeDisplay(clear: false)
                phase = .starting
            } catch {
                lastFailure = "\(error)"
                if (error as? DeviceSessionError) == .capabilityAlreadyActive {
                    needsNewSession = true
                    lastError = "the session still holds the old display"
                    phase = .failed(lastError)
                    onLog?("display: \(lastError), a new session is needed")
                    return nil
                }
            }
            onLog?("display: attempt \(attempt) failed: \(lastFailure)")
            try? await Task.sleep(nanoseconds: 750_000_000)
        }
        lastError = "could not open the display: \(lastFailure)"
        phase = .failed(lastFailure)
        return nil
    }

    private func displayStateChanged(_ state: DisplayState, gen: Int) {
        guard gen == displayGen else { return }
        onLog?("display: \(state)")
        if state == .stopped, !closingDisplay, display != nil {
            // Stopped by the glasses: let go of it.
            displayGen += 1
            display = nil
            cancel(&displayTokens)
            phase = .off
        }
    }

    /// Clears the lens, stops the display and waits until it has stopped.
    func closeDisplay(clear: Bool = true) async {
        guard let closing = display else {
            if phase != .off && phase != .starting { phase = .off }
            return
        }
        closingDisplay = true
        defer { closingDisplay = false }
        displayGen += 1
        display = nil
        phase = .stopping
        if clear {
            _ = await finishes(within: 2) { _ = try? await closing.clearDisplay() }
        }
        closing.stop()
        _ = await waitUntil(2, step: 0.1) { closing.state == .stopped }
        let tokens = displayTokens
        displayTokens = []
        for token in tokens { await token.cancel() }
        lastSentAt = nil
        phase = .off
    }

    /// The session ended: everything on it is gone.
    func dropAll() {
        displayGen += 1
        display = nil
        cancel(&displayTokens)
        lastSentAt = nil
        usedInSession = false
        if phase != .off { phase = .off }
    }

    /// The app is closing: no time to wait for answers.
    func shutdownNow() {
        display?.stop()
        dropAll()
    }

    private func cancel(_ tokens: inout [any AnyListenerToken]) {
        let old = tokens
        tokens = []
        Task { for token in old { await token.cancel() } }
    }
}
