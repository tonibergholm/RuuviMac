import Foundation
import CoreBluetooth
import Combine
import RuuviCore
import RuuviMQTT

final class SensorStore: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published var sensors: [Sensor] = []
    @Published var status = "Starting Bluetooth…"
    @Published var scanning = false
    @Published var error: String?
    @Published var usingMQTT = false
    @Published var downloadingTag: String?
    @Published var logStatus = ""
    private var logReader: TagLogReader?
    private var mqtt: MQTTInput?
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
        guard !usingMQTT else { return }
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
    func useMQTT(_ config: MQTTSettings) {
        mqtt?.stop(); usingMQTT = true; wantsScanning = false; central.stopScan(); scanning = false
        let input = MQTTInput(settings: config)
        input.onReading = { [weak self] sample in self?.receive(id: sample.identity, reading: sample.reading, rssi: sample.rssi) }
        input.onStatus = { [weak self] message in self?.status = message }
        mqtt = input; input.start()
    }
    func useBluetooth() {
        mqtt?.stop(); mqtt = nil; usingMQTT = false; wantsScanning = true
        centralManagerDidUpdateState(central)
    }
    func toggleScanning() {
        if usingMQTT { useBluetooth(); return }
        wantsScanning.toggle()
        if wantsScanning { start() } else { central.stopScan(); scanning = false; status = "Scanning paused" }
    }
    private func start() {
        guard downloadingTag == nil, central.state == .poweredOn else { return }
        // RuuviTags need no pairing and do not require a advertised service filter.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        scanning = true; status = "Scanning for nearby RuuviTags"
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !usingMQTT, let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let decoded = AdvertisementDecoder.decode(data, peripheralID: peripheral.identifier.uuidString, rssi: RSSI.intValue) else { return }
        let id = decoded.mac ?? peripheral.identifier.uuidString
        receive(id: id, reading: decoded.reading, rssi: RSSI.intValue)
    }
    func receive(id: String, reading: Reading, rssi: Int) {
        if let index = sensors.firstIndex(where: { $0.id == id }) {
            guard reading.date > sensors[index].lastSeen else { return }
            sensors[index].receive(reading, rssi: rssi)
        } else {
            var sensor = Sensor(id: id, date: reading.date, rssi: rssi, reading: reading)
            sensor.receive(reading, rssi: rssi); sensors.append(sensor)
        }
        scheduleSave()
    }
    func downloadHistory(_ id: String) {
        guard downloadingTag == nil else { logReader?.cancel(); return }
        downloadingTag = id; central.stopScan(); scanning = false
        let reader = TagLogReader(identity: id); logReader = reader
        reader.onProgress = { [weak self] message in self?.logStatus = message }
        reader.onResult = { [weak self] readings, issue in
            guard let self else { return }
            var added = 0
            if let i = self.sensors.firstIndex(where: { $0.id == id }) {
                added = self.sensors[i].mergeHistory(readings, now: Date()); self.persist()
            }
            self.logStatus = (issue.map { $0 + " " } ?? "Download complete. ") + "Imported \(added) new samples (\(readings.count) received)."
            self.downloadingTag = nil; self.logReader = nil
            if !self.usingMQTT && self.wantsScanning { self.start() }
        }
        reader.start()
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
