import SwiftUI

/// The one screen you need: Start walk, what is connected, and the phone's
/// copy of the card. After Start the phone goes in a pocket, locked.
struct HomeView: View {
    @EnvironmentObject private var walk: Walk
    @EnvironmentObject private var link: Link
    @EnvironmentObject private var glasses: Glasses
    @EnvironmentObject private var voice: VoiceLoop
    @EnvironmentObject private var audio: Audio
    @EnvironmentObject private var stt: SttClient

    @State private var typed = ""
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    notices
                    walkButton
                    statusStrip
                    card
                    typeBox
                }
                .padding(16)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("MailPilot Lens")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { resetMenu }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    // MARK: Notices

    @ViewBuilder
    private var notices: some View {
        if let text = walk.banner { notice(text, .orange) }
        if !link.paired {
            notice("Not paired yet. In MailPilot, open Glasses, choose Pair a phone and scan the code with the iPhone camera.", .blue)
        } else if let detail = link.status.detail {
            notice(detail, .orange)
        }
        if let text = link.warning { notice(text, .orange) }
        if let text = link.pairingNote { notice(text, .blue) }
        if walk.settings.useLens, link.paired, let text = glasses.banner { notice(text, .orange) }
        if walk.stage == .on, let text = voice.problem { notice(text, .orange) }
    }

    private func notice(_ text: String, _ colour: Color) -> some View {
        Text(text)
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(colour.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Start and end

    private var walkButton: some View {
        VStack(spacing: 8) {
            Button {
                if walk.stage == .idle { walk.start() } else { walk.end() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: walk.stage == .idle ? "figure.walk" : "stop.fill")
                    Text(walkLabel)
                }
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(walk.stage == .idle ? Color.black : Color.white)
            .background(walk.stage == .idle ? Color.white : Color(white: 0.2), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .disabled(walk.stage == .ending || !link.paired)
            .opacity(link.paired ? 1 : 0.4)

            if walk.stage == .on {
                HStack(spacing: 10) {
                    Button { walk.talk() } label: {
                        Label(voiceLabel, systemImage: voice.mode == .asleep ? "mic.slash" : "mic")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    LevelBar(level: audio.level, live: voice.mode == .listening)
                        .frame(width: 70, height: 10)
                }
                if !voice.partial.isEmpty {
                    Text(voice.partial).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                } else if !voice.lastHeard.isEmpty {
                    Text("“\(voice.lastHeard)”").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if !walk.step.isEmpty {
                Text(walk.step).font(.footnote).foregroundStyle(.secondary)
            } else if walk.stage == .idle, link.paired {
                Text("Start with the app open, then lock the phone and put it away.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var walkLabel: String {
        switch walk.stage {
        case .idle: return "Start walk"
        case .starting: return "Starting…"
        case .on: return "End walk"
        case .ending: return "Ending…"
        }
    }

    private var voiceLabel: String {
        switch voice.mode {
        case .off: return "Microphone off"
        case .asleep: return "Asleep · tap to talk"
        case .listening: return "Listening"
        case .speaking: return "Speaking"
        }
    }

    // MARK: What is connected

    private var statusStrip: some View {
        VStack(spacing: 0) {
            statusRow("desktopcomputer", "MailPilot", linkText, linkColour)
            statusRow("eyeglasses", "Glasses", glassesText, glasses.connected ? .green : .gray)
            statusRow("square.dashed", "Lens", walk.settings.useLens ? walk.lens : "off in Settings", walk.lens == "on" ? .green : .gray)
            statusRow("mic", "Microphone", audio.running ? audio.input : "off", audio.running ? (audio.viaGlasses ? .green : .yellow) : .gray)
            statusRow("waveform", "Speech server", stt.state.label, sttColour)
            if let busy = glasses.busy {
                statusRow("hourglass", "Busy", busy, .yellow)
            }
        }
        .background(Color(white: 0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func statusRow(_ symbol: String, _ name: String, _ value: String, _ colour: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(.secondary)
            Text(name).font(.subheadline)
            Spacer(minLength: 8)
            Text(value).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Circle().fill(colour).frame(width: 9, height: 9)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var linkText: String {
        var text = link.status.label
        if link.online, let host = link.host, !host.isEmpty { text = host }
        if link.online, let ms = link.roundTripMs { text += " · \(ms) ms" }
        return text
    }

    private var linkColour: Color {
        switch link.status {
        case .online: return .green
        case .connecting: return .yellow
        case .unpaired: return .gray
        case .silent, .offline: return .orange
        }
    }

    private var glassesText: String {
        if !glasses.registered { return "not registered" }
        if !glasses.connected { return glasses.devices == 0 ? "none listed" : "not connected" }
        var text = glasses.worn ? "worn" : "connected"
        if let battery = glasses.battery { text += " · \(battery)%" }
        return text
    }

    private var sttColour: Color {
        switch stt.state {
        case .streaming: return .green
        case .connecting: return .yellow
        case .failed: return .orange
        case .off: return .gray
        }
    }

    // MARK: The card

    @ViewBuilder
    private var card: some View {
        if let state = link.state, let shown = state.card {
            CardView(card: shown, footer: footer(state)) { action in
                walk.act(cardId: shown.id, action: action)
            }
        } else if link.paired {
            Text(link.online ? "Waiting for MailPilot's first card…" : "The card appears here once MailPilot answers.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
                .background(Color(white: 0.07), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    private func footer(_ state: LensState) -> String? {
        if state.isWorking, let doing = state.activity, !doing.isEmpty { return doing + "…" }
        if let note = state.note, !note.isEmpty { return note }
        if let heard = state.heard, !heard.isEmpty { return "“\(heard)”" }
        return nil
    }

    // MARK: Typing instead of talking

    private var typeBox: some View {
        HStack(spacing: 8) {
            TextField("Type what you would say", text: $typed)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
        }
        .opacity(link.paired ? 1 : 0.4)
    }

    private func send() {
        walk.typed(typed)
        typed = ""
    }

    // MARK: Reset

    private var resetMenu: some View {
        Menu {
            Button("Reopen the lens") { walk.reopenLens() }
            Button("Reset the glasses connection") { walk.resetGlasses() }
            Button("End the walk", role: .destructive) { walk.end() }
        } label: {
            Image(systemName: "arrow.counterclockwise")
        }
    }
}

/// The microphone's level: lit while what it hears goes to the speech server.
struct LevelBar: View {
    let level: Double
    let live: Bool

    var body: some View {
        GeometryReader { box in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(white: 0.15))
                Capsule().fill(live ? Color.green : Color.gray).frame(width: max(4, box.size.width * min(1, max(0, level))))
            }
        }
    }
}
