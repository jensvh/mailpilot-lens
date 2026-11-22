import SwiftUI

/// Pairing, the glasses' registration, how it listens and talks, and the log.
struct SettingsView: View {
    @EnvironmentObject private var walk: Walk
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var link: Link
    @EnvironmentObject private var glasses: Glasses
    @Environment(\.dismiss) private var dismiss

    @State private var pasted = ""
    @State private var speechCheck = ""
    @State private var confirmUnpair = false

    var body: some View {
        NavigationStack {
            Form {
                pairing
                glassesSection
                voiceSection
                lensSection
                diagnostics
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: MailPilot

    private var pairing: some View {
        Section {
            LabeledContent("Status", value: link.status.label)
            if link.paired {
                if let host = link.host, !host.isEmpty { LabeledContent("Paired with", value: host) }
                if let id = link.deviceId { LabeledContent("This phone", value: String(id.prefix(8))) }
                Button("Forget this pairing", role: .destructive) { confirmUnpair = true }
                    .confirmationDialog("Forget the pairing with MailPilot?", isPresented: $confirmUnpair, titleVisibility: .visible) {
                        Button("Forget", role: .destructive) {
                            if walk.stage != .idle { walk.end() }
                            link.unpair()
                        }
                    } message: {
                        Text("Remove this phone in MailPilot too (Glasses, Phones).")
                    }
            }
            if let note = link.pairingNote {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
            TextField("Or paste the pairing link", text: $pasted)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !pasted.isEmpty {
                Button(link.pairingBusy ? "Pairing…" : "Pair with this link") {
                    link.pair(pasted)
                    pasted = ""
                }
                .disabled(link.pairingBusy)
            }
        } header: {
            Text("MailPilot")
        } footer: {
            Text("In MailPilot, open Glasses and choose Pair a phone. Scan the code with the iPhone camera: it opens this app. The code works once and for 10 minutes. Everything between this phone and MailPilot is encrypted with a key only the two of them have.")
        }
    }

    // MARK: Glasses

    private var glassesSection: some View {
        Section {
            LabeledContent("Meta AI app", value: glasses.registered ? "registered" : glasses.registration)
            Text(glasses.deviceInfo).font(.footnote).foregroundStyle(.secondary)
            if glasses.registered {
                Button("Unregister", role: .destructive) { glasses.unregister() }
            } else {
                Button("Register with the Meta AI app") { glasses.register() }
            }
            if !glasses.status.isEmpty {
                Text(glasses.status).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Glasses")
        } footer: {
            Text("Registering opens the Meta AI app once, to allow this app. It needs Developer Mode there: Settings, App Info, tap the version number five times.")
        }
    }

    // MARK: Voice

    private var voiceSection: some View {
        Section {
            Picker("Language", selection: $settings.language) {
                Text("The iPhone's").tag("auto")
                Text("English").tag("en")
                Text("Nederlands").tag("nl")
            }
            VStack(alignment: .leading) {
                Text("Speaking speed")
                Slider(value: $settings.speechRate, in: 0.7...1.5, step: 0.05)
            }
            Picker("Stays listening for", selection: $settings.quietSeconds) {
                Text("20 seconds").tag(20)
                Text("45 seconds").tag(45)
                Text("2 minutes").tag(120)
                Text("5 minutes").tag(300)
            }
            Toggle("Talk over it", isOn: $settings.bargeIn)
            Toggle("A tap on the frame wakes it", isOn: $settings.tapWakes)
            if let speech = link.speech {
                LabeledContent("Speech server", value: URL(string: speech.url)?.host ?? speech.url)
                Button("Test the speech server") {
                    speechCheck = "Asking…"
                    SttClient.health(base: speech.url, key: speech.key) { text, _ in speechCheck = text }
                }
                if !speechCheck.isEmpty { Text(speechCheck).font(.footnote).foregroundStyle(.secondary) }
            } else {
                Text("No speech server yet: MailPilot sends its address when the phone is paired and on every connect.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Voice")
        } footer: {
            Text("The microphone opens on a pinch and after MailPilot has spoken, and closes when it stays quiet. \"Talk over it\" keeps listening while it speaks: only useful when the microphone doesn't pick up the glasses' own speakers (the echo test tells). A tap on the frame also pauses the glasses' session, so that switch is off until it has been tried.")
        }
    }

    // MARK: Lens

    private var lensSection: some View {
        Section {
            Toggle("Show cards on the glasses", isOn: $settings.useLens)
            Picker("Open the lens anew after", selection: $settings.staleSeconds) {
                Text("10 seconds").tag(10)
                Text("45 seconds").tag(45)
                Text("2 minutes").tag(120)
                Text("Never").tag(0)
            }
            Toggle("Draw the day as a picture", isOn: $settings.drawPictures)
        } header: {
            Text("Lens")
        } footer: {
            Text("The back gesture closes the app on the glasses without telling the phone. So a card that has been up for longer than this, with no pinch in between, is shown on a new glasses session, which takes a few seconds. \"Never\" is faster, and after a back gesture you say \"lens\" to bring it back.\n\nThe day plan (\"my day\") is drawn as a timeline. If the glasses don't take the picture it comes as text by itself; switch it off if the picture is slow or hard to read.")
        }
    }

    // MARK: Diagnostics

    private var diagnostics: some View {
        Section {
            NavigationLink("Try the glasses") { ProbeView() }
            NavigationLink("Log") { LogView() }
            ShareLink("Share the log", item: Log.shared.file)
            LabeledContent("Version", value: Link.appVersion)
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("The log holds what the app did and the words it heard. It holds no mail text and no keys.")
        }
    }
}

struct LogView: View {
    @ObservedObject private var log = Log.shared

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
                ForEach(Array(log.lines.enumerated().reversed()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
        }
        .navigationTitle("Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { ShareLink(item: Log.shared.file) }
        }
    }
}
