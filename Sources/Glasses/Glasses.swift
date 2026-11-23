// No SwiftUI in this file: MWDATDisplay has its own Text, Button and Image.
import Combine
import Foundation
import MWDATCore
import MWDATDisplay
import UIKit

/// The state of one part of the glasses link, as shown in the status strip.
enum Phase: Equatable {
    case off, starting, on, paused, stopping
    case failed(String)

    var label: String {
        switch self {
        case .off: return "off"
        case .starting: return "starting"
        case .on: return "on"
        case .paused: return "paused"
        case .stopping: return "stopping"
        case .failed(let why): return "failed: \(why)"
        }
    }
}

/// Everything that goes through Meta's Device Access Toolkit, coordinated so
/// that it can't get stuck (taken from Stride Lab, where it was tried on the
/// glasses; the camera is left out, which also leaves out the LED and the
/// muted-sound rules):
/// - one action at a time (`run`), each with a time limit;
/// - each session and display has a generation number, and callbacks from an
///   older one are ignored;
/// - closing is confirmed: display first, then the session;
/// - one session, at least 2 s between sessions, one retry, no reopen loop.
///
/// Rules of the glasses this follows (Meta's developer forum): the back gesture
/// ends the app on the glasses and can't be caught (ios#349); one tap pauses a
/// session, a second tap resumes (ios#312); the device is picked by hand,
/// because the automatic selector is still empty at the moment of a tap.
@MainActor
final class Glasses: ObservableObject {
    // Registration and device
    @Published private(set) var registration = "unknown"
    @Published private(set) var registered = false
    @Published private(set) var devices = 0
    @Published private(set) var deviceInfo = "no glasses listed"
    @Published private(set) var connected = false
    @Published private(set) var worn = false
    @Published private(set) var battery: Int?
    @Published private(set) var banner: String?

    // What is open, what is running
    @Published private(set) var sessionPhase: Phase = .off
    @Published private(set) var status = ""
    @Published private(set) var busy: String?

    let display = GlassesDisplay()
    /// The glasses' own buttons and gestures; asked for only when `frameInputsWanted`.
    let frame = FrameInputs()
    var frameInputsWanted = false

    /// Something about the glasses changed: connected, worn, battery, the session.
    var onChanged: (() -> Void)?
    /// The glasses ended the session themselves.
    var onSessionEnded: (() -> Void)?
    /// A walk keeps its session between cards.
    var keepSessionOpen = false
    /// The glasses didn't take a drawn card: text only until the app starts again.
    private(set) var picturesFailed = false

    private let wearables = Wearables.shared
    private var deviceTokens: [any AnyListenerToken] = []
    private var wasConnected = false

    private var session: DeviceSession?
    private var sessionGen = 0
    private var sessionTasks: [Task<Void, Never>] = []
    private var closingSession = false
    private var lastSessionEnd = Date.distantPast
    private var pauseTimer: Task<Void, Never>?
    private var idleTimer: Task<Void, Never>?
    private var sessionRefusals = 0

    private var lastWork: Task<Void, Never>?
    private var currentWorker: Task<Void, Never>?
    private var queueGen = 0
    private var busyID = UUID()

    init() {
        display.onLog = { text in Log.say(text) }
        Task { [weak self] in
            guard let self else { return }
            for await state in self.wearables.registrationStateStream() {
                self.registration = String(describing: state)
                let was = self.registered
                self.registered = state == .registered
                Log.say("registration: \(state)")
                if was && !self.registered && self.session != nil {
                    self.run("registration lost") { await self.closeSession("the registration was lost") }
                }
                self.updateBanner()
                self.onChanged?()
            }
        }
        Task { [weak self] in
            guard let self else { return }
            for await list in self.wearables.devicesStream() {
                self.devices = list.count
                Log.say("glasses listed: \(list.count)")
                self.watchDevices(list)
            }
        }
    }

    /// The line shown under the status strip.
    func say(_ text: String) {
        status = text
        Log.say(text)
    }

    func clearStatus() {
        status = ""
        sessionRefusals = 0
        updateBanner()
    }

    var hasSession: Bool { session != nil }
    /// The glasses refused a session twice in a row: only switching them off and on helps.
    var refusing: Bool { sessionRefusals >= 2 }

    // MARK: Action queue

    /// Runs one action at a time, in order. Each gets a time limit; when it
    /// takes longer it is abandoned with a message. `preempt` (ending the walk,
    /// the reset buttons) cancels the running action and drops the waiting ones.
    func run(_ label: String, timeout: Double = 30, preempt: Bool = false,
             _ work: @escaping @MainActor () async -> Void) {
        if preempt {
            queueGen += 1
            currentWorker?.cancel()
        }
        let gen = queueGen
        let previous = preempt ? nil : lastWork
        lastWork = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, gen == self.queueGen else { return }
            let id = UUID()
            self.busyID = id
            self.busy = label
            let worker = Task { @MainActor in await work() }
            self.currentWorker = worker
            let finished = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                let once = Once()
                Task { await worker.value; if once.claim() { done.resume(returning: true) } }
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    if once.claim() { worker.cancel(); done.resume(returning: false) }
                }
            }
            if !finished {
                self.say("“\(label)” took more than \(Int(timeout)) s and was stopped. If things stay stuck, use Reset.")
            }
            if self.busyID == id {
                self.busy = nil
                self.currentWorker = nil
            }
            self.scheduleIdleClose()
        }
    }

    // MARK: Devices

    private func watchDevices(_ ids: [DeviceIdentifier]) {
        cancel(&deviceTokens)
        for device in ids.compactMap({ wearables.deviceForIdentifier($0) }) {
            deviceTokens.append(device.addLinkStateListener { [weak self] _ in Task { @MainActor in self?.refreshDevice() } })
            deviceTokens.append(device.addCompatibilityListener { [weak self] _ in Task { @MainActor in self?.refreshDevice() } })
            deviceTokens.append(device.addDeviceStateListener { [weak self] _ in Task { @MainActor in self?.refreshDevice() } })
        }
        refreshDevice()
    }

    func refreshDevice() {
        guard let device = preferredDevice() else {
            deviceInfo = "no glasses listed"
            connected = false
            worn = false
            battery = nil
            updateBanner()
            onChanged?()
            return
        }
        connected = device.linkState == .connected
        worn = device.donState == .donned
        battery = device.batteryLevel.flatMap { $0 > 0 ? Int($0) : nil }
        let name = device.name.isEmpty ? "glasses" : device.name
        let info = "\(name): \(device.linkState), \(device.compatibility().displayString), \(device.donState)"
            + (device.supportsDisplay() ? ", has display" : ", no display")
            + (battery.map { ", battery \($0)%" } ?? "")
        if info != deviceInfo {
            deviceInfo = info
            Log.say("glasses: \(info)")
        }
        // Lost the link: whatever ran on it is gone.
        if wasConnected && !connected && session != nil {
            run("glasses disconnected") { await self.closeSession("the glasses disconnected") }
        }
        wasConnected = connected
        updateBanner()
        onChanged?()
    }

    private func updateBanner() {
        if !registered {
            banner = "Not registered with the Meta AI app: open Settings and tap Register."
        } else if devices == 0 {
            banner = "No glasses listed: check they are paired in the Meta AI app."
        } else if !connected {
            banner = "The glasses are not connected: open the Meta AI app and check they show as connected."
        } else if sessionRefusals >= 2 {
            banner = "The glasses keep refusing. Switch them off and on with the power switch, then tap Reset → Reopen the lens."
        } else {
            banner = nil
        }
    }

    /// Worn and connected first, then connected, then compatible.
    private func preferredDevice() -> Device? {
        let found = wearables.devices.compactMap { wearables.deviceForIdentifier($0) }
        func rank(_ d: Device) -> Int {
            if d.linkState == .connected && d.donState == .donned { return 0 }
            if d.linkState == .connected { return 1 }
            if d.compatibility() == .compatible { return 2 }
            return 3
        }
        return found.min { rank($0) < rank($1) }
    }

    /// Listener tokens stop their listener only when cancelled.
    private func cancel(_ tokens: inout [any AnyListenerToken]) {
        let old = tokens
        tokens = []
        Task { for token in old { await token.cancel() } }
    }

    // MARK: Registration

    func register() {
        guard !registered else {
            say("Already registered with the Meta AI app. To start over: Unregister, then Register again.")
            return
        }
        run("registering") {
            do {
                try await self.wearables.startRegistration()
                self.say("registration started: confirm in the Meta AI app")
            } catch {
                // Meta: "already registered" is a success (ios#307).
                if self.registered || (error as? RegistrationError) == .alreadyRegistered {
                    self.say("Already registered with the Meta AI app.")
                } else {
                    self.say("registration failed: \(error)")
                }
            }
        }
    }

    func unregister() {
        run("unregistering") {
            await self.closeSession("unregistering")
            do { try await self.wearables.startUnregistration() } catch { self.say("unregister failed: \(error)") }
        }
    }

    /// The Meta AI app calls back through mailpilotlens://…
    func handle(_ url: URL) {
        Task {
            do {
                let handled = try await wearables.handleUrl(url)
                Log.say(handled ? "Meta AI app answered" : "a link that isn't for the toolkit")
            } catch {
                say("callback failed: \(error)")
            }
        }
    }

    // MARK: Session

    /// The open session if it is healthy, otherwise a new one.
    func ensureSession() async -> DeviceSession? {
        if let current = session {
            switch current.state {
            case .started:
                return current
            case .paused:
                say("The session is paused on the glasses: tap the side of the glasses once to resume.")
                return nil
            case .idle, .starting:
                if await waitUntil(10, step: 0.2, { current.state == .started }) { return current }
                await closeSession("it did not start", quiet: true)
            default:
                await closeSession("it was \(current.state)", quiet: true)
            }
        }
        for attempt in 1...2 {
            let (opened, retry) = await openSession()
            if let opened {
                sessionRefusals = 0
                updateBanner()
                return opened
            }
            guard retry, attempt == 1, !Task.isCancelled else { break }
            say("trying once more…")
        }
        sessionRefusals += 1
        updateBanner()
        return nil
    }

    private func openSession() async -> (DeviceSession?, Bool) {
        guard registered else {
            say("Not registered: tap Register with the Meta AI app in Settings first.")
            return (nil, false)
        }
        if preferredDevice()?.linkState != .connected {
            _ = await waitUntil(5, step: 0.25) { self.preferredDevice()?.linkState == .connected }
        }
        guard let device = preferredDevice() else {
            say("No glasses listed. Check the glasses are paired in the Meta AI app.")
            return (nil, false)
        }
        guard device.linkState == .connected else {
            say("The glasses are not connected (\(device.linkState)). Open the Meta AI app, check they show as connected, then try again.")
            return (nil, false)
        }
        switch device.compatibility() {
        case .deviceUpdateRequired: say("The glasses need a software update (Meta AI app → glasses settings)."); return (nil, false)
        case .sdkUpdateRequired: say("These glasses need a newer toolkit version in MailPilot Lens."); return (nil, false)
        default: break
        }
        // Meta: leave at least 2 seconds between sessions.
        let gap = 2 - Date().timeIntervalSince(lastSessionEnd)
        if gap > 0 { try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000)) }
        if Task.isCancelled { return (nil, false) }

        say("opening a session on \(device.name.isEmpty ? "the glasses" : device.name)…")
        sessionGen += 1
        let gen = sessionGen
        sessionPhase = .starting
        do {
            let opened = try wearables.createSession(deviceSelector: SpecificDeviceSelector(device: device.identifier))
            session = opened
            observe(opened, gen)
            try opened.start()
            _ = await waitUntil(15, step: 0.2) { opened.state == .started || opened.state == .stopped }
            if opened.state == .started, session === opened {
                sessionPhase = .on
                say("session started")
                onChanged?()
                return (opened, false)
            }
            say("The session did not start (\(opened.state)).")
            await closeSession("it did not start", quiet: true)
            return (nil, true)
        } catch {
            if session != nil, sessionGen == gen { dropSession() }
            sessionPhase = .failed(Self.explain(error))
            lastSessionEnd = Date()
            say("session failed: \(Self.explain(error))")
            let e = error as? DeviceSessionError
            return (nil, e == .noEligibleDevice || e == .sessionAlreadyExists)
        }
    }

    private func observe(_ opened: DeviceSession, _ gen: Int) {
        sessionTasks.append(Task { [weak self] in
            for await state in opened.stateStream() {
                guard let self, self.sessionGen == gen else { return }
                self.sessionStateChanged(state)
            }
        })
        sessionTasks.append(Task { [weak self] in
            for await error in opened.errorStream() {
                guard let self, self.sessionGen == gen else { return }
                self.say("session error: \(Self.explain(error))")
            }
        })
    }

    private func sessionStateChanged(_ state: DeviceSessionState) {
        Log.say("session: \(state)")
        switch state {
        case .started:
            if sessionPhase == .paused { say("resumed on the glasses") }
            pauseTimer?.cancel()
            sessionPhase = .on
            onChanged?()
        case .paused:
            sessionPhase = .paused
            say("Paused on the glasses: tap the side of the glasses once to resume.")
            onChanged?()
            // Outside a walk a paused session is closed after 30 s; a walk waits for the tap.
            pauseTimer?.cancel()
            pauseTimer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, !Task.isCancelled, self.sessionPhase == .paused, !self.keepSessionOpen else { return }
                self.run("closing a paused session") { await self.closeSession("paused for 30 s") }
            }
        case .stopping:
            if !closingSession { sessionPhase = .stopping }
        case .stopped:
            let intended = closingSession
            let link = preferredDevice().map { "\($0.linkState)" } ?? "unknown"
            dropSession()
            if !intended {
                // The glasses give no reason. Link up: the back gesture, tap-and-hold or a call. Link down: out of reach.
                say("The glasses ended the session (link: \(link)). The next card opens a new one.")
                onSessionEnded?()
            }
            onChanged?()
        default:
            break
        }
    }

    /// The session is gone: drop everything that hung off it.
    private func dropSession() {
        sessionGen += 1
        sessionTasks.forEach { $0.cancel() }
        sessionTasks.removeAll()
        pauseTimer?.cancel()
        display.dropAll()
        frame.drop()
        session = nil
        lastSessionEnd = Date()
        sessionPhase = .off
    }

    /// Closes the display and then the session, each confirmed with a time
    /// limit. Afterwards nothing is held, whatever the glasses said.
    func closeSession(_ reason: String, quiet: Bool = false) async {
        guard let current = session else {
            if sessionPhase != .off { sessionPhase = .off }
            return
        }
        closingSession = true
        defer { closingSession = false }
        if !quiet { say("closing the session (\(reason))…") }
        sessionPhase = .stopping
        await display.closeDisplay()
        current.stop()
        let stopped = await waitUntil(3, step: 0.1) { current.state == .stopped }
        if session === current { dropSession() }
        if !quiet { say(stopped ? "session closed" : "session dropped (the glasses did not confirm)") }
        onChanged?()
    }

    /// A session nobody uses is closed after a minute (not during a walk).
    private func scheduleIdleClose() {
        idleTimer?.cancel()
        guard session != nil, !keepSessionOpen else { return }
        idleTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard let self, !Task.isCancelled, self.session != nil, !self.display.isOpen,
                  !self.keepSessionOpen, self.busy == nil else { return }
            self.run("closing the unused session") { await self.closeSession("unused for a minute") }
        }
    }

    static func explain(_ error: Error) -> String {
        guard let e = error as? DeviceSessionError else { return "\(error)" }
        switch e {
        case .noEligibleDevice: return "no eligible glasses (not connected, or not registered for this app)"
        case .sessionAlreadyExists: return "a session is already running"
        case .datAppOnTheGlassesUpdateRequired: return "the toolkit app on the glasses needs an update (Meta AI app → glasses → updates)"
        case .thermalCritical, .thermalEmergency: return "the glasses are too hot"
        case .batteryCritical: return "the glasses' battery is too low"
        case .capabilityAlreadyActive: return "the session still holds the old one"
        default: return e.description
        }
    }

    // MARK: The lens

    /// Puts a card on the lens. An open display is updated in place. `reopen`
    /// shows it on a new session instead: after the back gesture the app is
    /// closed on the glasses without a word to the phone, and only a new
    /// session brings a card back.
    ///
    /// `pictures`: a card that has a drawing (the day plan) is shown as one.
    /// Only on a display that is open already, so a picture the glasses won't
    /// take costs one failed update and nothing else: the same card then goes
    /// as text, and so does every card until the app starts again.
    @discardableResult
    func show(_ face: LensFace, reopen: Bool, pictures: Bool = false, onAction: @escaping @Sendable (String) -> Void) async -> Bool {
        if pictures, !picturesFailed, !reopen, display.isOpen, let current = session, current.state == .started,
           let picture = CardImages.picture(for: face.card) {
            if await display.show(on: current, view: CardRenderer.view(face, picture: picture, onAction: onAction), fresh: false) {
                Log.say("display: a drawn card of \(Int(picture.size.width))×\(Int(picture.size.height)), sent in \(display.sendMs ?? 0) ms")
                return true
            }
            picturesFailed = true
            Log.say("display: the picture wasn't shown (\(display.lastError)); cards are text from here on")
        }
        return await show(view: CardRenderer.view(face, onAction: onAction), reopen: reopen)
    }

    @discardableResult
    func show(view: FlexBox, reopen: Bool) async -> Bool {
        if !reopen, display.isOpen, let current = session, current.state == .started {
            if await display.show(on: current, view: view, fresh: false) { return true }
            Log.say("display: updating the card failed (\(display.lastError)); opening it again")
        }
        guard var target = await ensureSession() else { return false }
        if reopen, display.usedInSession {
            Log.say("display: reopening on a new session")
            await closeSession("reopening the lens", quiet: true)
            guard let fresh = await ensureSession() else { return false }
            target = fresh
        }
        var ok = await display.show(on: target, view: view, fresh: true)
        if !ok, display.needsNewSession {
            await closeSession("the display was stuck", quiet: true)
            if let fresh = await ensureSession() {
                ok = await display.show(on: fresh, view: view, fresh: true)
            }
        }
        if !ok { say("display: \(display.lastError)") }
        // The frame's buttons come after the card, so a refusal there can't cost the card.
        if ok, frameInputsWanted, let current = session, current.state == .started {
            frame.attach(to: current)
        }
        return ok
    }

    func closeCard() async {
        await display.closeDisplay()
    }

    // MARK: Closing

    /// Closes everything that runs on the glasses; keeps the registration.
    func closeEverything() async {
        if session != nil {
            await closeSession("stop everything")
        } else {
            dropSession()
        }
    }

    /// The app is being closed: release the glasses at once, without waiting
    /// for answers (there is no time for them).
    func shutdownNow() {
        idleTimer?.cancel()
        pauseTimer?.cancel()
        currentWorker?.cancel()
        display.shutdownNow()
        frame.drop()
        session?.stop()
        session = nil
        sessionPhase = .off
    }
}
