import Combine
import Foundation
import UIKit

/// A walk, from "Start walk" to "End walk": the one place that decides the
/// order things happen in, because the glasses are strict about it.
///
/// Starting (with the app in front, which the microphone permission needs):
///  1. the headset link comes up, with no glasses session open;
///  2. a short wait for the Bluetooth route to settle;
///  3. speech to text and the conversation loop;
///  4. hello to MailPilot, which answers with the brief;
///  5. a glasses session and the first card.
/// Ending goes the other way round: the session closes first, the headset link
/// last. In between the headset link is never touched.
///
/// The phone holds no mail logic. It draws the card MailPilot sends, says what
/// MailPilot wants said, and sends back what was heard and what was pinched.
@MainActor
final class Walk: ObservableObject {
    enum Stage: Equatable {
        case idle, starting, on, ending
    }

    @Published private(set) var stage: Stage = .idle
    /// What it is doing while it starts or ends.
    @Published private(set) var step = ""
    /// The lens, in a word or two, for the status strip.
    @Published private(set) var lens = "off"
    @Published private(set) var banner: String?
    @Published private(set) var startedAt: Date?
    /// What the last probe found.
    @Published private(set) var probeNote = ""

    let settings = AppSettings()
    let link = Link()
    let audio = Audio()
    let stt = SttClient()
    let speaker = Speaker()
    let glasses = Glasses()
    let band = NeuralBand()
    let voice: VoiceLoop

    private var lensWanted = false
    /// The lens didn't come up twice: stop trying until it is asked for.
    private var lensBlocked = false
    private var lensFailures = 0
    private var forceReopen = false
    private var shownFace: LensFace?
    private var lastShownAt = Date.distantPast
    private var lastPinchAt = Date.distantPast
    private var offlineTimer: Task<Void, Never>?
    private var offlineSince: Date?
    private var offlineShown = false
    private var pausedSaid = false
    private var lastStatus = ""
    private var endedByMailPilot = false
    private var sawLiveState = false
    private var probeSentAt = Date()
    private var observers: [NSObjectProtocol] = []

    init() {
        voice = VoiceLoop(audio: audio, stt: stt, speaker: speaker, settings: settings)
        wire()
        Log.say("MailPilot Lens \(Link.appVersion) on iOS \(UIDevice.current.systemVersion)")
        link.start()
    }

    private func wire() {
        link.language = { [weak self] in self?.settings.spokenLanguage }
        link.onState = { [weak self] state in self?.stateChanged(state) }
        link.onSpeak = { [weak self] message in self?.voice.say(message) }
        link.onStatusChanged = { [weak self] in self?.linkChanged() }

        voice.speechServer = { [weak self] in self?.link.speech }
        voice.onHeard = { [weak self] words, during in self?.heard(words, during) }
        voice.onSpeakingStarted = { [weak self] in _ = self?.link.send(.speaking) }
        voice.onSpoke = { [weak self] id, done in _ = self?.link.send(.spoke(id: id, done: done)) }
        voice.onModeChanged = { [weak self] in self?.refreshLens() }

        glasses.onChanged = { [weak self] in self?.glassesChanged() }
        glasses.onSessionEnded = { [weak self] in self?.sessionEnded() }
        band.onChanged = { [weak self] in self?.reportStatus() }

        audio.onRouteChanged = { [weak self] in self?.reportStatus() }
        audio.onMediaKey = { [weak self] name in self?.mediaKey(name) }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                Log.say("app in front")
                self?.link.wake()
                self?.glasses.refreshDevice()
            }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Log.say("app in the background (nothing is closed: a walk goes on)")
        })
        observers.append(center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdownNow() }
        })
    }

    /// A link the app was opened with: a pairing code, or the Meta AI app's answer.
    func open(_ url: URL) {
        if !link.open(url) { glasses.handle(url) }
    }

    // MARK: Start

    func start() {
        guard stage == .idle else { return }
        guard link.paired else {
            banner = "Pair this phone with MailPilot first: Settings, Pair."
            return
        }
        banner = nil
        stage = .starting
        step = "Opening the microphone"
        lensWanted = settings.useLens
        lensBlocked = false
        lensFailures = 0
        forceReopen = true
        shownFace = nil
        offlineShown = false
        offlineSince = nil
        pausedSaid = false
        endedByMailPilot = false
        sawLiveState = false
        glasses.keepSessionOpen = true
        glasses.run("starting the walk", timeout: 90) { [weak self] in await self?.begin() }
    }

    private func begin() async {
        // The headset link comes up before any glasses session: switching it
        // with a session open ends that session.
        if glasses.hasSession {
            await glasses.closeSession("the headset microphone comes on first", quiet: true)
            await rest(2)
        }
        guard await audio.startAsync() else {
            fail("The microphone couldn't be opened. Allow it in the iPhone's Settings, under MailPilot Lens.")
            return
        }
        await rest(1.5)  // let the Bluetooth route settle before a session opens
        guard stage == .starting else { return }

        voice.begin()
        band.start()
        startedAt = Date()
        stage = .on
        step = ""
        Log.say("walk: started, microphone \(audio.input), lens \(lensWanted ? "wanted" : "off")")
        link.sayHello(fresh: true)
        reportStatus(force: true)
        if !link.online {
            voice.sayLocal(words.offlineAtStart, earcon: "error")
        }
        if lensWanted {
            if glasses.registered && glasses.connected {
                await render()
            } else {
                lens = glasses.registered ? "glasses not connected" : "not registered"
            }
        } else {
            lens = "off"
        }
    }

    private func fail(_ why: String) {
        banner = why
        Log.say("walk: \(why)")
        voice.end()
        audio.stop()
        glasses.keepSessionOpen = false
        step = ""
        stage = .idle
    }

    // MARK: End

    func end() {
        guard stage == .on || stage == .starting else { return }
        let askForSummary = stage == .on && !endedByMailPilot
        stage = .ending
        step = "Ending the walk"
        glasses.run("ending the walk", timeout: 60, preempt: true) { [weak self] in
            await self?.finish(askForSummary: askForSummary)
        }
    }

    private func finish(askForSummary: Bool) async {
        // The summary is MailPilot's to say: "9 deleted, 3 tasks, 2 drafts saved".
        if askForSummary {
            _ = link.send(.heard(text: "end walk", duringSpeech: false))
        }
        if link.online || speaker.speaking {
            _ = await waitUntil(4) { self.speaker.speaking }
            _ = await waitUntil(25) { !self.speaker.speaking }
        }
        voice.end()
        band.stop()
        // The session first, the headset link last.
        await glasses.closeEverything()
        await rest(0.5)
        audio.stop()
        glasses.keepSessionOpen = false
        offlineTimer?.cancel()
        offlineTimer = nil
        shownFace = nil
        startedAt = nil
        lens = "off"
        step = ""
        stage = .idle
        Log.say("walk: ended")
    }

    /// The app is being closed: let go of the glasses and the headset link at once.
    private func shutdownNow() {
        Log.say("app closing: releasing the glasses")
        voice.end()
        glasses.shutdownNow()
        audio.stop()
    }

    // MARK: What MailPilot says

    private func stateChanged(_ state: LensState) {
        guard stage == .on else { return }
        voice.follow(state)
        if !state.hasEnded {
            sawLiveState = true
        } else if sawLiveState, !endedByMailPilot {
            // "End walk" was said: MailPilot speaks the summary, then the phone lets go.
            endedByMailPilot = true
            Log.say("walk: MailPilot says the walk is over")
            end()
            return
        }
        refreshLens()
    }

    private func linkChanged() {
        guard stage == .on else { return }
        if link.online {
            offlineTimer?.cancel()
            offlineTimer = nil
            offlineSince = nil
            if offlineShown {
                offlineShown = false
                audio.earcon("done")
            }
            reportStatus(force: true)
            refreshLens()
            return
        }
        guard link.status != .connecting else { return }
        if offlineSince == nil { offlineSince = Date() }
        // A blip is not worth a word: only after six seconds without MailPilot.
        guard offlineTimer == nil, !offlineShown else { return }
        offlineTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.offlineTimer = nil
            guard self.stage == .on, !self.link.online else { return }
            self.offlineShown = true
            self.voice.sayLocal(self.words.offline, earcon: "error")
            self.refreshLens()
        }
    }

    // MARK: What the user does

    private func heard(_ text: String, _ duringSpeech: Bool) {
        if lensWord(text) {
            reopenLens()
            return
        }
        guard link.send(.heard(text: text, duringSpeech: duringSpeech)) else {
            // Nothing is decided on old data: without MailPilot the words go nowhere.
            audio.earcon("error")
            return
        }
    }

    /// A command typed on the phone, as if it was said.
    func typed(_ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        if !link.send(.heard(text: words, duringSpeech: false)) {
            banner = "Not connected to MailPilot: nothing was sent."
        }
    }

    /// A button: pinched on the lens, or tapped on the phone's copy of the card.
    func act(cardId: String, action: String) {
        if action.hasPrefix(LocalAction.prefix) {
            if action == LocalAction.close { closeLens() }
            return
        }
        if stage == .on { voice.wake("a button") }
        if !link.send(.act(cardId: cardId, action: action, rev: link.state?.rev ?? 0)) {
            if stage == .on { audio.earcon("error") } else { banner = "Not connected to MailPilot: nothing was sent." }
        }
    }

    /// The phone's own Talk button: open the microphone.
    func talk() {
        guard stage == .on else { return }
        voice.wake("the Talk button", interrupt: true)
    }

    private func pinched(cardId: String, action: String) {
        lastPinchAt = Date()
        Log.say("lens: pinched \(action)")
        act(cardId: cardId, action: action)
    }

    /// A tap on the glasses' frame arrives as a media button. It also pauses
    /// the glasses session (tap again to resume), so it is off unless chosen.
    private func mediaKey(_ name: String) {
        guard stage == .on, settings.tapWakes else { return }
        if speaker.speaking {
            voice.stopSpeaking()
        } else {
            voice.wake("a tap on the frame")
        }
    }

    // MARK: The lens

    /// What belongs on the lens right now.
    private var face: LensFace? {
        if offlineShown {
            var line = words.offlineLine
            if let since = offlineSince {
                let clock = DateFormatter()
                clock.dateFormat = "HH:mm"
                line += " " + clock.string(from: since)
            }
            return LensFace(card: LensCard(id: "local-offline", template: "status", icon: "bell", title: words.offlineTitle, lines: [line],
                                           actions: [LensAction(id: LocalAction.close, label: words.close, style: "secondary")]))
        }
        guard let state = link.state, let card = state.card else { return nil }
        var footer: String?
        if state.isWorking, let doing = state.activity, !doing.isEmpty {
            footer = doing + "…"
        } else if let note = state.note, !note.isEmpty {
            footer = (state.alert == true ? "! " : "") + note
        } else if let said = state.heard, !said.isEmpty {
            footer = "“\(said)”"
        }
        if voice.mode == .asleep, state.wantsWords {
            footer = [footer, words.micAsleep].compactMap { $0 }.joined(separator: " · ")
        }
        return LensFace(card: card, footer: footer)
    }

    private func refreshLens() {
        guard stage == .on, lensWanted, !lensBlocked else { return }
        guard face != shownFace || forceReopen else { return }
        glasses.run("showing a card", timeout: 45) { [weak self] in await self?.render() }
    }

    /// Shows the newest card, if it isn't the one on the lens already. Several
    /// of these can wait in a row; all but the first find nothing to do.
    private func render() async {
        guard stage == .on, lensWanted, !lensBlocked, let wanted = face, wanted != shownFace || forceReopen else { return }
        guard glasses.registered, glasses.connected else {
            lens = glasses.registered ? "glasses not connected" : "not registered"
            return
        }
        if glasses.sessionPhase == .paused {
            lens = "paused"
            return
        }
        // A card that has been up for a while may be gone: after the back
        // gesture the app is closed on the glasses without a word to the phone,
        // and only a new session brings a card back. A pinch proves it is there.
        let quiet = min(Date().timeIntervalSince(lastShownAt), Date().timeIntervalSince(lastPinchAt))
        let stale = settings.staleSeconds > 0 && glasses.display.isOpen && quiet > Double(settings.staleSeconds)
        let reopen = forceReopen || stale
        forceReopen = false
        let cardId = wanted.card.id
        let shown = await glasses.show(wanted, reopen: reopen, pictures: settings.drawPictures) { [weak self] action in
            Task { @MainActor in self?.pinched(cardId: cardId, action: action) }
        }
        guard stage == .on else { return }
        if shown {
            shownFace = wanted
            lastShownAt = Date()
            lensFailures = 0
            lens = "on"
            reportStatus()
            return
        }
        lensFailures += 1
        lens = "not answering"
        if glasses.sessionPhase == .paused {
            lens = "paused"
        } else if glasses.refusing || lensFailures >= 2 {
            // No reopen loop: it waits until it is asked for ("lens", or Reset on the phone).
            lensBlocked = true
            voice.sayLocal(words.lensGone)
        }
    }

    private func sessionEnded() {
        guard stage == .on else { return }
        shownFace = nil
        lens = "closed on the glasses"
    }

    private func glassesChanged() {
        reportStatus()
        guard stage == .on, lensWanted else { return }
        if glasses.sessionPhase == .paused {
            lens = "paused"
            if !pausedSaid {
                pausedSaid = true
                voice.sayLocal(words.paused)
            }
        } else if glasses.sessionPhase == .on, lens == "paused" {
            pausedSaid = false
            lens = "on"
            refreshLens()
        }
    }

    /// Takes the card off the lens until it is asked for again.
    private func closeLens() {
        lensWanted = false
        shownFace = nil
        lens = "closed"
        glasses.run("closing the card") { [weak self] in await self?.glasses.closeCard() }
    }

    /// Brings the lens back on a new session: "lens", or Reset on the phone.
    func reopenLens() {
        guard stage == .on else { return }
        Log.say("lens: reopening")
        lensWanted = true
        lensBlocked = false
        lensFailures = 0
        forceReopen = true
        glasses.clearStatus()
        glasses.run("reopening the lens", timeout: 45) { [weak self] in await self?.render() }
    }

    /// Words the phone answers itself, because they are about the glasses and not about mail.
    private func lensWord(_ text: String) -> Bool {
        let said = text.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        return ["lens", "the lens", "show lens", "show the lens", "open lens", "open the lens", "reopen lens", "lens on",
                "de lens", "toon lens", "toon de lens", "open de lens", "lens aan"].contains(said)
    }

    // MARK: Telling MailPilot how the phone and glasses are doing

    private func reportStatus(force: Bool = false) {
        guard stage == .on || stage == .starting else { return }
        let mic = audio.running ? audio.input : nil
        let showing = glasses.display.isOpen
        let bandSeen: Bool? = band.seen == .unknown ? nil : band.seen == .connected
        let now = "\(glasses.connected)|\(glasses.worn)|\(glasses.battery ?? -1)|\(mic ?? "")|\(showing)|\(String(describing: bandSeen))|\(band.battery ?? -1)"
        guard force || now != lastStatus else { return }
        if link.send(.status(glasses: glasses.connected, worn: glasses.worn, battery: glasses.battery, mic: mic, display: showing,
                             band: bandSeen, bandBattery: band.battery)) {
            lastStatus = now
        }
    }

    // MARK: Reset

    /// Closes the glasses session and opens a new one for the current card.
    func resetGlasses() {
        Log.say("reset: the glasses connection")
        lensBlocked = false
        lensFailures = 0
        forceReopen = true
        shownFace = nil
        glasses.run("resetting the glasses connection", timeout: 60, preempt: true) { [weak self] in
            guard let self else { return }
            await self.glasses.closeEverything()
            self.glasses.clearStatus()
            await rest(2)
            if self.stage == .on, self.lensWanted { await self.render() }
        }
    }

    // MARK: Probes (what only the glasses can answer)

    func probeCapacity(headings: Int, bodies: Int, metas: Int, buttons: Int) {
        probeNote = "Sending…"
        glasses.run("showing a test card", timeout: 45) { [weak self] in
            guard let self else { return }
            let ok = await self.glasses.probeCapacity(headings: headings, bodies: bodies, metas: metas, buttons: buttons) { [weak self] label in
                Task { @MainActor in self?.probePicked(label) }
            }
            self.probeSent(ok, "\(headings) heading, \(bodies) body, \(metas) meta lines, \(buttons) buttons")
        }
    }

    func probeImage() {
        probeNote = "Sending…"
        glasses.run("showing a test picture", timeout: 45) { [weak self] in
            guard let self else { return }
            let ok = await self.glasses.probeImage { [weak self] label in
                Task { @MainActor in self?.probePicked(label) }
            }
            self.probeSent(ok, "a 600×420 picture")
        }
    }

    private func probeSent(_ ok: Bool, _ what: String) {
        probeSentAt = Date()
        shownFace = nil  // the walk's card is no longer what the lens shows
        probeNote = ok ? "Sent \(what) in \(glasses.display.sendMs ?? 0) ms. Pinch a button on the lens: the time until then is logged."
            : "Not shown: \(glasses.status)"
        Log.say("probe: \(probeNote)")
    }

    private func probePicked(_ label: String) {
        let after = Int(Date().timeIntervalSince(probeSentAt))
        probeNote = "“\(label)” pinched \(after) s after the card was sent."
        Log.say("probe: \(probeNote)")
        lastPinchAt = Date()
        if label == "Close" {
            if stage == .on, lensWanted {
                refreshLens()
            } else {
                glasses.run("closing the test card") { [weak self] in await self?.glasses.closeCard() }
            }
        }
    }

    /// Does the microphone hear the glasses' own speakers? Needs a walk (the headset link).
    func probeEcho() {
        guard stage == .on else {
            probeNote = "Start a walk first: this needs the headset link."
            return
        }
        probeNote = "Listening to silence, then to its own voice…"
        Task { [weak self] in
            guard let self else { return }
            self.voice.stopSpeaking()
            await rest(1.0)
            self.audio.resetPeak()
            await rest(2.0)
            let quiet = self.audio.currentPeak
            self.audio.resetPeak()
            self.voice.sayLocal("This is a test of the echo. One, two, three, four, five, six.")
            _ = await waitUntil(2) { self.speaker.speaking }
            _ = await waitUntil(15) { !self.speaker.speaking }
            let loud = self.audio.currentPeak
            let ratio = quiet > 0 ? loud / quiet : 0
            self.probeNote = String(format: "Echo: level %.4f in silence, %.4f while it spoke (%.1f times). Stay quiet during this test.", quiet, loud, ratio)
            Log.say("probe: \(self.probeNote)")
        }
    }

    // MARK: The few lines the phone says by itself

    private struct Words {
        var offlineAtStart: String
        var offline: String
        var offlineTitle: String
        var offlineLine: String
        var close: String
        var micAsleep: String
        var lensGone: String
        var paused: String
    }

    private var words: Words {
        if settings.spokenLanguage == "nl" {
            return Words(
                offlineAtStart: "Geen verbinding met MailPilot. Ik probeer het opnieuw.",
                offline: "Geen verbinding. Ik ben terug zodra er bereik is.",
                offlineTitle: "Offline",
                offlineLine: "Geen verbinding sinds",
                close: "Sluiten",
                micAsleep: "Microfoon uit",
                lensGone: "De lens antwoordt niet. Praten werkt nog. Zet de bril uit en aan, en zeg dan: lens.",
                paused: "De bril staat op pauze. Tik één keer op de zijkant.")
        }
        return Words(
            offlineAtStart: "No connection to MailPilot. I keep trying.",
            offline: "No connection. I'll be back when there is coverage.",
            offlineTitle: "Offline",
            offlineLine: "No connection since",
            close: "Close",
            micAsleep: "Mic asleep",
            lensGone: "The lens isn't answering. Voice still works. Switch the glasses off and on, then say: lens.",
            paused: "The glasses are paused. Tap the side once.")
    }
}
