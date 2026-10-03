import Foundation
import CoreBluetooth
import Combine
import RuuviCore

final class SensorStore: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published var sensors: [Sensor] = []
    @Published var status = "Starting Bluetooth…"
    @Published var scanning = false
    @Published var error: String?
    private var wantsScanning = true
    private var central: CBCentralManager!
    private var saveTask: DispatchWorkItem?
    private let archive: SensorArchive

    override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        archive = SensorArchive(url: support.appendingPathComponent("RuuviMac/sensors.json"))
        super.init()
        do { sensors = try archive.load() } catch { self.error = "Could not load saved data: \(error.localizedDescription)" }
        central = CBCentralManager(delegate: self, queue: .main)
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        scanning = false
        switch central.state {
        case .poweredOn: status = "Bluetooth ready"; if wantsScanning { start() }
        case .poweredOff: status = "Turn on Bluetooth in System Settings."
        case .unauthorized: status = "Allow Bluetooth for RuuviMac in System Settings → Privacy & Security."
        case .unsupported: status = "This Mac does not support Bluetooth LE."
        case .resetting: status = "Bluetooth is resetting…"
        default: status = "Waiting for Bluetooth…"
        }
    }
    func toggleScanning() {
        wantsScanning.toggle()
        if wantsScanning { start() } else { central.stopScan(); scanning = false; status = "Scanning paused" }
    }
    private func start() {
        guard central.state == .poweredOn else { return }
        // RuuviTags need no pairing and do not require a advertised service filter.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        scanning = true; status = "Scanning for nearby RuuviTags"
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let decoded = AdvertisementDecoder.decode(data, peripheralID: peripheral.identifier.uuidString, rssi: RSSI.intValue) else { return }
        let id = decoded.mac ?? peripheral.identifier.uuidString
        if let index = sensors.firstIndex(where: { $0.id == id }) {
            sensors[index].receive(decoded.reading, rssi: RSSI.intValue)
        } else {
            var sensor = Sensor(id: id, date: decoded.reading.date, rssi: RSSI.intValue, reading: decoded.reading)
            sensor.receive(decoded.reading, rssi: RSSI.intValue); sensors.append(sensor)
        }
        scheduleSave()
    }
    func rename(_ id: String, to name: String) {
        guard let i = sensors.firstIndex(where: { $0.id == id }), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sensors[i].name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)); persist()
    }
    func favorite(_ id: String) {
        guard let i = sensors.firstIndex(where: { $0.id == id }) else { return }
        sensors[i].favorite.toggle(); persist()
    }
    private func scheduleSave() {
        guard saveTask == nil else { return }
        let task = DispatchWorkItem { [weak self] in self?.saveTask = nil; self?.persist() }
        saveTask = task; DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: task)
    }
    func persist() {
        do { try archive.save(sensors) } catch { self.error = "Could not save data: \(error.localizedDescription)" }
    }
}
