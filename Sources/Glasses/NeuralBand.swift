import Combine
import CoreBluetooth
import Foundation

/// The Meta Neural Band, as far as the phone can see it.
///
/// Meta's toolkit (1.0.1 and 1.1.0) says nothing about the band: no battery,
/// no connection, only its pinches as an input source. Meta pairs the band
/// through the Meta AI app, and it shows up in the iPhone's Bluetooth list, so
/// it may be a Bluetooth device the phone itself is connected to. If it is, and
/// it offers the standard battery service, any app may read its level. Whether
/// it does is not known yet: the band may talk to the glasses only, or keep its
/// battery to itself. This finds out, and says "can't tell" rather than guess.
///
/// It looks only at Bluetooth devices that are connected to the phone already
/// (it never scans or pairs), and only after a walk starts or the probe asks,
/// because the first look asks for Bluetooth permission.
final class NeuralBand: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    enum Seen: Equatable {
        /// Not looked yet, or Bluetooth is off or not allowed.
        case unknown
        /// Connected to the phone.
        case connected
        /// The phone sees no band among its connected devices: it may talk to the glasses only.
        case notSeen
    }

    @Published private(set) var seen: Seen = .unknown
    @Published private(set) var battery: Int?
    @Published private(set) var name: String?
    /// Every connected Bluetooth device the phone listed, for the probe: name, and battery when it has one.
    @Published private(set) var devices: [String] = []
    @Published private(set) var note = ""

    /// Something changed that MailPilot should hear about.
    var onChanged: (() -> Void)?

    private static let batteryService = CBUUID(string: "180F")
    private static let batteryLevel = CBUUID(string: "2A19")
    private static let deviceInfo = CBUUID(string: "180A")
    private static let humanInterface = CBUUID(string: "1812")

    private var central: CBCentralManager?
    private var band: CBPeripheral?
    private var others: [UUID: CBPeripheral] = [:]
    private var levels: [UUID: Int] = [:]
    private var timer: Timer?

    /// Looks now, and again every minute until `stop()`.
    func start() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        } else {
            look()
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.look() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Looks once (the probe's button).
    func lookNow() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        } else {
            look()
        }
    }

    // MARK: Looking

    private func look() {
        guard let central else { return }
        guard central.state == .poweredOn else {
            set(.unknown, note: central.state == .unauthorized ? "Bluetooth isn't allowed for MailPilot Lens (iPhone Settings)." : "Bluetooth is off.")
            return
        }
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.batteryService, Self.deviceInfo, Self.humanInterface])
        var list: [String] = []
        var found: CBPeripheral?
        for peripheral in connected {
            let label = peripheral.name ?? "(no name)"
            list.append(label + (levels[peripheral.identifier].map { " · \($0)%" } ?? ""))
            others[peripheral.identifier] = peripheral
            if found == nil, Self.looksLikeBand(label) { found = peripheral }
        }
        devices = list
        Log.say("band: connected Bluetooth devices: \(list.isEmpty ? "none" : list.joined(separator: ", "))")

        guard let found else {
            band = nil
            battery = nil
            name = nil
            set(.notSeen, note: "The phone sees no Neural Band among its Bluetooth devices. It may talk to the glasses only.")
            return
        }
        band = found
        name = found.name
        set(.connected, note: "")
        // Reading the battery needs a connection of this app's own (the system's stays as it is).
        found.delegate = self
        if found.state == .connected, found.services != nil {
            readBattery(found)
        } else {
            central.connect(found, options: nil)
        }
    }

    /// The band's name isn't documented; these are the words it is likely to carry.
    static func looksLikeBand(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("neural") || lower.contains("band") || lower.contains("wrist") || lower.contains("emg")
    }

    private func readBattery(_ peripheral: CBPeripheral) {
        if let service = peripheral.services?.first(where: { $0.uuid == Self.batteryService }) {
            if let level = service.characteristics?.first(where: { $0.uuid == Self.batteryLevel }) {
                peripheral.readValue(for: level)
            } else {
                peripheral.discoverCharacteristics([Self.batteryLevel], for: service)
            }
        } else {
            peripheral.discoverServices([Self.batteryService])
        }
    }

    private func set(_ next: Seen, note text: String) {
        note = text
        guard seen != next else { return }
        seen = next
        Log.say("band: \(next == .connected ? "connected to the phone" : next == .notSeen ? "not seen by the phone" : "can't tell") \(text)")
        onChanged?()
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        look()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([Self.batteryService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Log.say("band: couldn't open its battery (\(error?.localizedDescription ?? "no reason given"))")
        if peripheral === band { note = "Connected, but its battery can't be read." }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.batteryService }) else {
            if peripheral === band {
                note = "Connected, but it doesn't share its battery."
                Log.say("band: no battery service")
            }
            return
        }
        peripheral.discoverCharacteristics([Self.batteryLevel], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let level = service.characteristics?.first(where: { $0.uuid == Self.batteryLevel }) else { return }
        peripheral.readValue(for: level)
        if level.properties.contains(.notify) { peripheral.setNotifyValue(true, for: level) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.batteryLevel else { return }
        guard error == nil, let value = characteristic.value?.first else {
            Log.say("band: its battery can't be read (\(error?.localizedDescription ?? "empty"))")
            if peripheral === band { note = "Connected, but its battery can't be read." }
            return
        }
        let level = Int(value)
        levels[peripheral.identifier] = level
        guard peripheral === band, level != battery else { return }
        battery = level
        Log.say("band: battery \(level)%")
        onChanged?()
    }
}
