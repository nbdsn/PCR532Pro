import Foundation
import CoreBluetooth

// MARK: - BLE Service & Characteristic UUIDs
struct PCR532BLE {
    static let serviceUUID = CBUUID(string: "00001101-0000-1000-8000-00805F9B34FB")
    static let nordicUARTServiceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let ffeServiceUUID = CBUUID(string: "0000FFE0-0000-1000-8000-00805F9B34FB")
    static let ffeCharUUID = CBUUID(string: "0000FFE1-0000-1000-8000-00805F9B34FB")
    static let fffServiceUUID = CBUUID(string: "0000FFF0-0000-1000-8000-00805F9B34FB")
    static let fffCharUUID = CBUUID(string: "0000FFF1-0000-1000-8000-00805F9B34FB")
    static let customTxUUID = CBUUID(string: "00001102-0000-1000-8000-00805F9B34FB")
    static let customRxUUID = CBUUID(string: "00001103-0000-1000-8000-00805F9B34FB")
    /// Nordic NUS: write to 002 (RX), notify from 003 (TX)
    static let nordicRXCharUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    static let nordicTXCharUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    
    static let nameFilters = ["PCR532", "PCR5", "HC-", "BLE", "UART", "BT05", "JDY", "BT-", "MLT", "SPP"]
    
    static let knownServiceUUIDs: [CBUUID] = [
        serviceUUID, nordicUARTServiceUUID, ffeServiceUUID, fffServiceUUID
    ]
}

protocol BLEManagerDelegate: AnyObject {
    func bleDidUpdateState(_ isPoweredOn: Bool)
    func bleDidDiscoverDevice(_ device: BLEDevice)
    func bleDidConnect(_ device: BLEDevice)
    func bleDidDisconnect(_ device: BLEDevice, error: Error?)
    func bleDidReceiveData(_ data: [UInt8])
    func bleDidEncounterError(_ error: Error)
}

struct BLEDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
    let peripheral: CBPeripheral
    
    static func == (lhs: BLEDevice, rhs: BLEDevice) -> Bool {
        lhs.id == rhs.id
    }
    
    var signalBars: Int {
        if rssi >= -50 { return 4 }
        if rssi >= -65 { return 3 }
        if rssi >= -80 { return 2 }
        if rssi >= -90 { return 1 }
        return 0
    }
}

class BLEManager: NSObject, ObservableObject {
    @Published var isScanning = false
    @Published var isConnected = false
    @Published var connectedDeviceName = ""
    @Published var discoveredDevices = [BLEDevice]()
    @Published var connectionState: ConnectionState = .disconnected
    @Published var lastErrorMessage: String?
    @Published var lastDebugLog: String = ""
    
    enum ConnectionState: String {
        case disconnected = "Not connected"
        case connecting = "Connecting..."
        case discovering = "Discovering..."
        case ready = "Ready"
    }
    
    weak var delegate: BLEManagerDelegate?
    
    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var responseBuffer = PN532ResponseBuffer()
    
    private var onFrameReceived: ((Result<PN532Frame, Error>) -> Void)?
    private var frameWaitContinuation: CheckedContinuation<PN532Frame, Error>?
    private var expectingAckOnly = false
    private var discoveryFallbackUsed = false
    private var didInitPN532 = false
    private var mtuChunkSize = 20
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }
    
    func startScan() {
        startScanAll()
    }
    
    func startScanFilteredByService() {
        guard centralManager.state == .poweredOn else {
            delegate?.bleDidEncounterError(PN532Error.communicationError("Bluetooth off"))
            return
        }
        discoveredDevices.removeAll()
        isScanning = true
        centralManager.scanForPeripherals(
            withServices: PCR532BLE.knownServiceUUIDs,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }
    
    func startScanAll() {
        guard centralManager.state == .poweredOn else {
            delegate?.bleDidEncounterError(PN532Error.communicationError("Bluetooth off"))
            return
        }
        discoveredDevices.removeAll()
        isScanning = true
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }
    
    func stopScan() {
        isScanning = false
        centralManager.stopScan()
    }
    
    func connect(to device: BLEDevice) {
        connectionState = .connecting
        lastErrorMessage = nil
        discoveryFallbackUsed = false
        didInitPN532 = false
        writeCharacteristic = nil
        notifyCharacteristic = nil
        responseBuffer.clear()
        stopScan()
        centralManager.connect(device.peripheral, options: nil)
        connectedPeripheral = device.peripheral
        connectedPeripheral?.delegate = self
    }
    
    func disconnect() {
        guard let peripheral = connectedPeripheral else { return }
        failPending(PN532Error.notConnected)
        centralManager.cancelPeripheralConnection(peripheral)
    }
    
    /// Send PN532 command frame: wake + data, wait ACK, then wait response (skip ACKs)
    func sendFrame(_ frame: PN532Frame, timeout: TimeInterval = 8.0) async throws -> PN532Frame {
        guard let peripheral = connectedPeripheral else {
            throw PN532Error.notConnected
        }
        guard connectionState == .ready, writeCharacteristic != nil else {
            throw PN532Error.communicationError("Write characteristic not ready")
        }
        
        // One-time init after connect
        if !didInitPN532 {
            try await initializePN532()
        }
        
        responseBuffer.clear()
        let raw = frame.encode()
        appendDebug("TX \(raw.map { String(format: "%02X", $0) }.joined(separator: " "))")
        
        try await writeBytes(raw, peripheral: peripheral)
        
        // First complete frame is usually ACK; skip empty ACKs until data response
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            do {
                let resp = try await waitForNextFrame(timeout: remaining)
                if resp.isAckPlaceholder {
                    appendDebug("RX ACK")
                    continue
                }
                if resp.tfi == .pn532ToHost {
                    appendDebug("RX \(resp.data.map { String(format: "%02X", $0) }.joined(separator: " "))")
                    return resp
                }
                // unexpected host frame - ignore
            } catch let e as PN532Error {
                if case .timeout = e { break }
                throw e
            }
        }
        throw PN532Error.timeout
    }
    
    func sendRaw(_ data: [UInt8]) {
        guard let peripheral = connectedPeripheral, connectionState == .ready else { return }
        Task { try? await writeBytes(data, peripheral: peripheral) }
    }
    
    // MARK: - PN532 init sequence
    
    private func initializePN532() async throws {
        guard let peripheral = connectedPeripheral else { throw PN532Error.notConnected }
        
        // Wake-up preamble for HSU/UART modules
        try await writeBytes(PN532Frame.wakeUp, peripheral: peripheral)
        try await Task.sleep(nanoseconds: 80_000_000)
        
        // SAMConfiguration normal mode
        responseBuffer.clear()
        let sam = PN532CommandBuilder.samConfiguration()
        try await writeBytes(sam.encode(), peripheral: peripheral)
        _ = try? await waitForAckThenResponse(timeout: 3.0) // may timeout on some firmwares
        
        // GetFirmwareVersion to verify link
        responseBuffer.clear()
        let fw = PN532CommandBuilder.getFirmwareVersion()
        try await writeBytes(fw.encode(), peripheral: peripheral)
        if let resp = try? await waitForAckThenResponse(timeout: 4.0) {
            let info = PN532ResponseParser.parseFirmware(resp.data)
            appendDebug(String(format: "FW IC=%02X ver=%d.%d", info.ic, info.ver, info.rev))
            didInitPN532 = true
            return
        }
        
        // Retry wake + firmware once
        try await writeBytes(PN532Frame.wakeUp, peripheral: peripheral)
        try await Task.sleep(nanoseconds: 100_000_000)
        responseBuffer.clear()
        try await writeBytes(fw.encode(), peripheral: peripheral)
        if let resp = try? await waitForAckThenResponse(timeout: 4.0) {
            let info = PN532ResponseParser.parseFirmware(resp.data)
            appendDebug(String(format: "FW retry IC=%02X", info.ic))
            didInitPN532 = true
            return
        }
        
        // Still mark init attempted so detect can run; some bridges auto-wake
        didInitPN532 = true
        appendDebug("Init: no firmware response (continue)")
    }
    
    private func waitForAckThenResponse(timeout: TimeInterval) async throws -> PN532Frame {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            let resp = try await waitForNextFrame(timeout: max(remaining, 0.05))
            if resp.isAckPlaceholder { continue }
            if resp.tfi == .pn532ToHost { return resp }
        }
        throw PN532Error.timeout
    }
    
    private func waitForNextFrame(timeout: TimeInterval) async throws -> PN532Frame {
        // Drain already buffered frames first
        if let frame = try responseBuffer.extractFrame() {
            return frame
        }
        
        return try await withCheckedThrowingContinuation { cont in
            self.frameWaitContinuation = cont
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self = self else { return }
                if let c = self.frameWaitContinuation {
                    self.frameWaitContinuation = nil
                    c.resume(throwing: PN532Error.timeout)
                }
            }
        }
    }
    
    private func failPending(_ error: Error) {
        if let c = frameWaitContinuation {
            frameWaitContinuation = nil
            c.resume(throwing: error)
        }
    }
    
    private func deliverBufferedFrames() {
        do {
            while let frame = try responseBuffer.extractFrame() {
                if let c = frameWaitContinuation {
                    frameWaitContinuation = nil
                    c.resume(returning: frame)
                    return
                } else {
                    // No waiter: drop ACKs, keep only if someone later... already consumed
                    break
                }
            }
        } catch {
            if let c = frameWaitContinuation {
                frameWaitContinuation = nil
                c.resume(throwing: error)
            }
        }
    }
    
    private func writeBytes(_ data: [UInt8], peripheral: CBPeripheral) async throws {
        guard let writeChar = writeCharacteristic else {
            throw PN532Error.communicationError("No write char")
        }
        let writeType: CBCharacteristicWriteType =
            writeChar.properties.contains(.writeWithoutResponse) && !writeChar.properties.contains(.write)
            ? .withoutResponse : .withResponse
        
        var offset = 0
        while offset < data.count {
            let end = min(offset + mtuChunkSize, data.count)
            let chunk = Array(data[offset..<end])
            peripheral.writeValue(Data(chunk), for: writeChar, type: writeType)
            offset = end
            if offset < data.count {
                // small gap for cheap BLE UART modules
                try await Task.sleep(nanoseconds: 15_000_000)
            }
        }
        // allow notify path to settle
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    
    private func appendDebug(_ s: String) {
        lastDebugLog = s
    }
    
    private func markReadyIfPossible() {
        if writeCharacteristic != nil {
            connectionState = .ready
            isConnected = true
            lastErrorMessage = nil
        }
    }
    
    private func assignCharacteristic(_ characteristic: CBCharacteristic, peripheral: CBPeripheral) {
        let uuid = characteristic.uuid
        let props = characteristic.properties
        let canWrite = props.contains(.write) || props.contains(.writeWithoutResponse)
        let canNotify = props.contains(.notify) || props.contains(.indicate)
        
        let preferWrite =
            uuid == PCR532BLE.nordicRXCharUUID ||
            uuid == PCR532BLE.customRxUUID ||
            uuid == PCR532BLE.ffeCharUUID ||
            uuid == PCR532BLE.fffCharUUID ||
            uuid == PCR532BLE.customTxUUID
        
        let preferNotify =
            uuid == PCR532BLE.nordicTXCharUUID ||
            uuid == PCR532BLE.customTxUUID ||
            uuid == PCR532BLE.ffeCharUUID ||
            uuid == PCR532BLE.fffCharUUID
        
        if canWrite {
            if writeCharacteristic == nil || preferWrite {
                writeCharacteristic = characteristic
            }
        }
        if canNotify {
            if notifyCharacteristic == nil || preferNotify {
                notifyCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        if canWrite && canNotify {
            if writeCharacteristic == nil { writeCharacteristic = characteristic }
            if notifyCharacteristic == nil {
                notifyCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }
}

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        delegate?.bleDidUpdateState(central.state == .poweredOn)
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                       advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advertisedName ?? ""
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let hasKnownService = serviceUUIDs.contains { PCR532BLE.knownServiceUUIDs.contains($0) }
        if name.isEmpty && !hasKnownService { return }
        
        let displayName = name.isEmpty ? "Unknown" : name
        let device = BLEDevice(id: peripheral.identifier, name: displayName, rssi: RSSI.intValue, peripheral: peripheral)
        if let index = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
            discoveredDevices[index] = device
        } else {
            discoveredDevices.append(device)
            discoveredDevices.sort { $0.rssi > $1.rssi }
        }
        delegate?.bleDidDiscoverDevice(device)
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionState = .discovering
        connectedDeviceName = peripheral.name ?? "PCR532"
        let maxLen = peripheral.maximumWriteValueLength(for: .withoutResponse)
        if maxLen > 0 {
            mtuChunkSize = max(20, min(maxLen, 180))
        }
        delegate?.bleDidConnect(BLEDevice(id: peripheral.identifier, name: peripheral.name ?? "", rssi: 0, peripheral: peripheral))
        peripheral.discoverServices(nil)
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionState = .disconnected
        isConnected = false
        lastErrorMessage = error?.localizedDescription ?? "Connect failed"
        delegate?.bleDidEncounterError(error ?? PN532Error.communicationError("Connect failed"))
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectionState = .disconnected
        isConnected = false
        connectedDeviceName = ""
        writeCharacteristic = nil
        notifyCharacteristic = nil
        didInitPN532 = false
        failPending(PN532Error.notConnected)
        delegate?.bleDidDisconnect(
            BLEDevice(id: peripheral.identifier, name: peripheral.name ?? "", rssi: 0, peripheral: peripheral),
            error: error
        )
    }
}

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            lastErrorMessage = error.localizedDescription
            delegate?.bleDidEncounterError(error)
            return
        }
        let services = peripheral.services ?? []
        if services.isEmpty {
            lastErrorMessage = "No BLE services"
            connectionState = .disconnected
            isConnected = false
            return
        }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            lastErrorMessage = error.localizedDescription
            return
        }
        for characteristic in service.characteristics ?? [] {
            assignCharacteristic(characteristic, peripheral: peripheral)
        }
        markReadyIfPossible()
        if writeCharacteristic == nil {
            let remaining = (peripheral.services ?? []).contains { $0.characteristics == nil }
            if !remaining {
                lastErrorMessage = "No writable characteristic"
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            delegate?.bleDidEncounterError(error)
            return
        }
        guard let value = characteristic.value, !value.isEmpty else { return }
        let bytes = [UInt8](value)
        appendDebug("NOTIFY \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
        responseBuffer.append(bytes)
        deliverBufferedFrames()
        delegate?.bleDidReceiveData(bytes)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            delegate?.bleDidEncounterError(error)
            failPending(error)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            lastErrorMessage = "Notify failed: \(error.localizedDescription)"
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        // rediscover
        peripheral.discoverServices(nil)
    }
}