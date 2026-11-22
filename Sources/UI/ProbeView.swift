import SwiftUI

/// Test cards for what only the glasses can answer: how much text fits on the
/// lens, whether a drawn picture is quick and readable, how long a card stays
/// reachable, and whether the microphone hears the glasses' own speakers.
/// Write what you find in docs/device-findings.md.
struct ProbeView: View {
    @EnvironmentObject private var walk: Walk
    @EnvironmentObject private var glasses: Glasses
    @EnvironmentObject private var band: NeuralBand

    @State private var headings = 1
    @State private var bodies = 3
    @State private var metas = 1
    @State private var buttons = 3

    var body: some View {
        Form {
            Section {
                Stepper("Heading lines: \(headings)", value: $headings, in: 0...4)
                Stepper("Body lines: \(bodies)", value: $bodies, in: 0...10)
                Stepper("Meta lines: \(metas)", value: $metas, in: 0...6)
                Stepper("Buttons: \(buttons)", value: $buttons, in: 1...6)
                Button("Show this card on the lens") {
                    walk.probeCapacity(headings: headings, bodies: bodies, metas: metas, buttons: buttons)
                }
            } header: {
                Text("How much fits")
            } footer: {
                Text("Add lines until the buttons leave the lens or the text gets cut. The largest card that still reads well is the answer.")
            }

            Section {
                Button("Show a drawn picture") { walk.probeImage() }
            } header: {
                Text("A picture")
            } footer: {
                Text("A made-up day as a timeline. Is it sharp, and how long did it take to appear?")
            }

            Section {
                Text("Show any test card, wait 5, 15 or 60 minutes with the lens dark, then pinch a button. The time until the pinch is logged; no pinch arriving means the card was gone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Does a card survive")
            }

            Section {
                Button("Look for the Neural Band") { band.lookNow() }
                if !band.note.isEmpty { Text(band.note).font(.footnote) }
                if let name = band.name { LabeledContent("Band", value: name + (band.battery.map { " · \($0)%" } ?? "")) }
                ForEach(band.devices, id: \.self) { device in
                    Text(device).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Neural Band")
            } footer: {
                Text("Meta's toolkit doesn't report the band. This lists the Bluetooth devices connected to the phone and reads the band's battery if it shares it. Write down what it lists: the band may talk to the glasses only.")
            }

            Section {
                Button("Run the echo test") { walk.probeEcho() }
            } header: {
                Text("Echo")
            } footer: {
                Text("Needs a walk (the headset link). Stay quiet: it measures the microphone in silence and while the glasses speak. A level many times higher while speaking means the microphone hears the speakers, and \"Talk over it\" should stay off.")
            }

            Section {
                if !walk.probeNote.isEmpty { Text(walk.probeNote).font(.footnote) }
                if !glasses.status.isEmpty { Text(glasses.status).font(.footnote).foregroundStyle(.secondary) }
                if let busy = glasses.busy { Text("Busy: \(busy)").font(.footnote).foregroundStyle(.secondary) }
            } header: {
                Text("Result")
            }
        }
        .navigationTitle("Try the glasses")
        .navigationBarTitleDisplayMode(.inline)
    }
}
