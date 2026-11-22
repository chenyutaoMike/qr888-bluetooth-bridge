import CoreBluetooth
import Foundation

final class BluetoothPrinter: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let serviceID = CBUUID(string: "18F0")
    private let writeID = CBUUID(string: "2AF1")
    struct Candidate {
        let identifier: UUID
        let name: String
    }

    private let preferenceKey = "SelectedPrinterIdentifier"
    private var scanCompletion: (([Candidate]) -> Void)?
    private var candidates = [UUID: Candidate]()
    private var scanDeadline: DispatchWorkItem?
    private var scanStarted = false

    var selectedID: UUID? {
        UserDefaults.standard.string(forKey: preferenceKey).flatMap { UUID(uuidString: $0) }
    }
    var selectedName: String? { UserDefaults.standard.string(forKey: "SelectedPrinterName") }
    var isBusy: Bool { completion != nil || scanCompletion != nil }

    func select(_ candidate: Candidate) {
        UserDefaults.standard.set(candidate.identifier.uuidString, forKey: preferenceKey)
        UserDefaults.standard.set(candidate.name, forKey: "SelectedPrinterName")
        report("已选择 \(candidate.name)")
    }

    func findPrinters(completion: @escaping ([Candidate]) -> Void) {
        guard !isBusy else { completion([]); return }
        scanCompletion = completion
        candidates.removeAll()
        report("正在扫描附近的 QR-888XPro…")
        scheduleScanEnd(after: 10)
        startScanWhenReady()
    }

    private func scheduleScanEnd(after seconds: Double) {
        scanDeadline?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.endScan() }
        scanDeadline = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func startScanWhenReady() {
        guard scanCompletion != nil, !scanStarted else { return }
        switch manager.state {
        case .poweredOn:
            scanStarted = true
            manager.scanForPeripherals(withServices: nil)
            scheduleScanEnd(after: 5)
        case .unauthorized, .poweredOff, .unsupported:
            endScan()
        default:
            break
        }
    }

    private func endScan() {
        guard let callback = scanCompletion else { return }
        scanCompletion = nil
        scanStarted = false
        scanDeadline?.cancel()
        scanDeadline = nil
        if manager.isScanning { manager.stopScan() }
        let found = candidates.values.sorted {
            if $0.name == $1.name { return $0.identifier.uuidString < $1.identifier.uuidString }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        callback(found)
    }

    private var manager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var completion: ((Bool) -> Void)?
    private var payload: Data?
    private var offset = 0
    private var attempted = false
    private var waitingForResponse = false
    private var generation = 0
    var report: (String) -> Void

    init(report: @escaping (String) -> Void) {
        self.report = report
        super.init()
        manager = CBCentralManager(delegate: self, queue: .main)
    }

    func run(_ data: Data? = nil, completion: @escaping (Bool) -> Void) {
        guard !isBusy else { completion(false); return }
        guard selectedID != nil else { report("请先选择蓝牙打印机"); completion(false); return }
        self.completion = completion
        payload = data
        offset = 0
        attempted = false
        waitingForResponse = false
        generation += 1
        let token = generation
        report(data == nil ? "正在检查打印机蓝牙连接" : "正在连接打印机，准备发送 \(data!.count) 字节")
        startWhenReady()
        DispatchQueue.main.asyncAfter(deadline: .now() + 18) { [weak self] in
            guard let self = self, token == self.generation, self.characteristic == nil else { return }
            self.finish(false, "未找到可用的蓝牙打印服务。请确认打印机开机且标签管家已断开。")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 145) { [weak self] in
            guard let self = self, token == self.generation else { return }
            self.finish(false, "蓝牙传输超时，请检查出纸后再重打。")
        }
    }

    private func startWhenReady() {
        guard completion != nil else { return }
        switch manager.state {
        case .poweredOn:
            if peripheral == nil && !manager.isScanning {
                manager.scanForPeripherals(withServices: nil)
            }
        case .unauthorized:
            finish(false, "请在系统设置 → 隐私与安全性 → 蓝牙中允许启锐蓝牙打印桥。")
        case .poweredOff, .unsupported, .resetting:
            finish(false, "Mac 的蓝牙暂不可用。")
        default:
            break
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        report("Mac 蓝牙状态 \(central.state.rawValue)，权限 \(CBCentralManager.authorization.rawValue)")
        startScanWhenReady()
        startWhenReady()
    }

    func centralManager(_ central: CBCentralManager, didDiscover device: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        if scanCompletion != nil {
            let names: [String] = [advertisedName, device.name].compactMap { $0 }
            if let name = names.first(where: { PrinterName.supports($0) }) {
                candidates[device.identifier] = Candidate(identifier: device.identifier, name: name)
            }
            return
        }
        guard completion != nil, peripheral == nil, device.identifier == selectedID else { return }
        central.stopScan()
        report("发现 \(selectedName ?? "QR-888XPro")，信号 \(RSSI) dBm")
        peripheral = device
        device.delegate = self
        central.connect(device)
    }

    func centralManager(_ central: CBCentralManager, didConnect device: CBPeripheral) {
        guard device === peripheral else { return }
        device.discoverServices([serviceID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect device: CBPeripheral, error: Error?) {
        guard device === peripheral else { return }
        finish(false, "打印机连接失败 \(error?.localizedDescription ?? "")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral device: CBPeripheral, error: Error?) {
        guard device === peripheral else { return }
        finish(false, attempted ? "打印过程中蓝牙断开，确认实际出纸后再重打。" : "打印机在写入前断开。")
    }

    func peripheral(_ device: CBPeripheral, didDiscoverServices error: Error?) {
        guard device === peripheral else { return }
        guard let service = device.services?.first(where: { $0.uuid == serviceID }), error == nil else {
            finish(false, "打印机未公开 18F0 打印服务。")
            return
        }
        device.discoverCharacteristics([writeID], for: service)
    }

    func peripheral(_ device: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard device === peripheral else { return }
        guard let writer = service.characteristics?.first(where: { $0.uuid == writeID }),
              error == nil, writer.properties.contains(.write) || writer.properties.contains(.writeWithoutResponse) else {
            finish(false, "打印机未公开可写入的 2AF1 接口。")
            return
        }
        characteristic = writer
        report("已验证 18F0 / 2AF1 可写接口，特征属性 \(writer.properties.rawValue)")
        if payload == nil { finish(true, "蓝牙打印服务已验证，等待打印。"); return }
        pump()
    }

    private func pump() {
        guard let device = peripheral, let writer = characteristic, let bytes = payload, !waitingForResponse else { return }
        let mode: CBCharacteristicWriteType = writer.properties.contains(.write) ? .withResponse : .withoutResponse
        guard offset < bytes.count else {
            let token = generation
            waitingForResponse = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self = self, self.generation == token else { return }
                self.finish(true, "已向蓝牙打印接口发送 \(bytes.count) 字节，出纸以实机为准。")
            }
            return
        }
        guard mode == .withResponse || device.canSendWriteWithoutResponse else { return }
        let end = min(offset + min(180, device.maximumWriteValueLength(for: mode)), bytes.count)
        guard end > offset else { finish(false, "打印机返回无效的蓝牙包长度。"); return }
        let chunk = bytes.subdata(in: offset..<end)
        offset = end
        attempted = true
        waitingForResponse = true
        device.writeValue(chunk, for: writer, type: mode)
        if mode == .withoutResponse {
            let token = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) { [weak self] in
                guard let self = self, self.generation == token else { return }
                self.waitingForResponse = false
                self.pump()
            }
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse device: CBPeripheral) {
        guard device === peripheral else { return }
        pump()
    }

    func peripheral(_ device: CBPeripheral, didWriteValueFor writer: CBCharacteristic, error: Error?) {
        guard device === peripheral, writer === characteristic else { return }
        waitingForResponse = false
        if let error = error {
            finish(false, "蓝牙写入失败 \(error.localizedDescription)。请确认出纸后再重打。")
        } else {
            pump()
        }
    }

    private func finish(_ success: Bool, _ message: String) {
        guard let callback = completion else { return }
        completion = nil
        generation += 1
        let device = peripheral
        peripheral = nil
        characteristic = nil
        payload = nil
        if manager.isScanning { manager.stopScan() }
        if let device = device { manager.cancelPeripheralConnection(device) }
        report(message)
        callback(success)
    }
}
