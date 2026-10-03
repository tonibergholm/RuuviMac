import Foundation
import CoreBluetooth
import RuuviCore

/// A short-lived connection for log reads only; all callbacks run on main.
final class TagLogReader: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let identity: String
    private var accumulator = TagLogAccumulator(now: Date())
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var timer: DispatchWorkItem?
    private var deadline: DispatchWorkItem?
    private var finishing = false
    private var delivered = false
    private var issue: String?
    var onProgress: ((String) -> Void)?
    var onResult: (([Reading], String?) -> Void)?
    private let service = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private let rx = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    private let tx = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    private var writeCharacteristic: CBCharacteristic?
    init(identity: String) { self.identity = identity; super.init() }
    func start() {
        onProgress?("Finding the tag over Bluetooth…")
        central = CBCentralManager(delegate: self, queue: .main)
        arm(20, "Tag not found. Bring it closer and enable connectable firmware.")
        let task = DispatchWorkItem { [weak self] in self?.finish("History transfer timed out. Retry the download.") }
        deadline = task; DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: task)
    }
    func cancel() { finish("Download cancelled.") }
    private func arm(_ seconds: Double, _ error: String) {
        timer?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.finish(error) }
        timer = task; DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: task)
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !finishing else { return }
        switch central.state {
        case .poweredOn: central.scanForPeripherals(withServices: nil)
        case .unauthorized: finish("Allow Bluetooth for RuuviMac in System Settings → Privacy & Security.")
        case .poweredOff: finish("Turn on Bluetooth to download tag history.")
        case .unsupported: finish("Bluetooth LE is unavailable on this Mac.")
        default: break
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !finishing, self.peripheral == nil,
              let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let decoded = AdvertisementDecoder.decode(data, peripheralID: peripheral.identifier.uuidString, rssi: RSSI.intValue),
              (decoded.mac ?? peripheral.identifier.uuidString) == identity else { return }
        central.stopScan(); self.peripheral = peripheral; peripheral.delegate = self
        onProgress?("Connecting to tag…")
        arm(20, "Could not connect. Bring the tag closer, enable connectable firmware, and close other tag connections.")
        central.connect(peripheral)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard !finishing else { central.cancelPeripheralConnection(peripheral); return }
        peripheral.discoverServices([service])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finish("Tag connection failed: " + (error?.localizedDescription ?? "try again"))
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if finishing { deliver() } else { finish("Tag disconnected. Bring it closer and retry.") }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard !finishing else { return }
        guard error == nil, let s = peripheral.services?.first(where: { $0.uuid == service }) else {
            finish("Tag has no history service. Check that its firmware supports logging."); return
        }
        peripheral.discoverCharacteristics([rx,tx], for: s)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard !finishing else { return }
        guard error == nil, let read = service.characteristics?.first(where: { $0.uuid == tx }),
              let write = service.characteristics?.first(where: { $0.uuid == rx }),
              read.properties.contains(.notify), write.properties.contains(.write) else {
            finish("Tag history characteristics are unavailable."); return
        }
        writeCharacteristic = write; peripheral.setNotifyValue(true, for: read)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard !finishing else { return }
        guard error == nil, characteristic.isNotifying, let write = writeCharacteristic else {
            finish("Could not subscribe to tag history."); return
        }
        onProgress?("Downloading tag history…")
        arm(30, "Tag stopped sending history. Close other tag connections and retry.")
        accumulator = TagLogAccumulator(now: Date())
        peripheral.writeValue(accumulator.request, for: write, type: .withResponse)
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error, !finishing { finish("Log request failed: " + error.localizedDescription) }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard !finishing, characteristic.uuid == tx else { return }
        guard error == nil, let data = characteristic.value else { finish("Could not read tag history."); return }
        do { try accumulator.feed(data) } catch { finish(error.localizedDescription); return }
        if data.count >= 3, data[data.startIndex] == 0x3A {
            arm(30, "Tag stopped sending history. Bring it closer and retry.")
            onProgress?("Downloading tag history · \(accumulator.count) samples")
        }
        if accumulator.complete { finish(nil) }
    }
    private func finish(_ error: String?) {
        guard !finishing else { return }
        finishing = true; issue = error; timer?.cancel(); deadline?.cancel(); central?.stopScan()
        if let peripheral, peripheral.state != .disconnected {
            central.cancelPeripheralConnection(peripheral)
            let task = DispatchWorkItem { [weak self] in self?.deliver() }
            timer = task; DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: task)
        } else { deliver() }
    }
    private func deliver() {
        guard !delivered else { return }; delivered = true; timer?.cancel()
        onResult?(accumulator.readings, issue)
    }
}
