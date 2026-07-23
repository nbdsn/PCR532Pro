import Foundation
import CoreBluetooth

struct PCR532BLE {
    // Classic SPP service UUID string (Android uses RFCOMM with this UUID).
    // On BLE bridges it is often reused as a service UUID.
    static let sppUUID = CBUUID(string: "00001101-0000-1000-8000-00805F9B34FB")
    static let nordicService = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let nordicWrite = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") // RX from module view = phone writes
    static let nordicNotify = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") // TX = notify
    static let ffe0 = CBUUID(string: "0000FFE0-0000-1000-8000-00805F9B34FB")
    static let ffe1 = CBUUID(string: "0000FFE1-0000-1000-8000-00805F9B34FB")
    static let fff0 = CBUUID(string: "0000FFF0-0000-1000-8000-00805F9B34FB")
    static let fff1 = CBUUID(string: "0000FFF1-0000-1000-8000-00805F9B34FB")
    static let fff2 = CBUUID(string: "0000FFF2-0000-1000-8000-00805F9B34FB")
    static let fff3 = CBUUID(string: "0000FFF3-0000-1000-8000-00805F9B34FB")
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
    static func == (lhs: BLEDevice, rhs: BLEDevice) -> Bool { lhs.id == rhs.id }
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
    private var candidateWrite: [CBCharacteristic] = []
    private var candidateNotify: [CBCharacteristic] = []
    private var responseBuffer = PN532ResponseBuffer()
    private var frameWaitContinuation: CheckedContinuation<PN532Frame, Error>?
    private var didInitPN532 = false
    private var mtuChunkSize = 20
    private var preferWithoutResponse = true
    private var charMapTried = 0
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }
    
    func startScan() { startScanAll() }
    
    func startScanFilteredByService() {
        guard centralManager.state == .poweredOn else { return }
        discoveredDevices.removeAll()
        isScanning = true
        centralManager.scanForPeripherals(withServices: [
            PCR532BLE.sppUUID, PCR532BLE.nordicService, PCR532BLE.ffe0, PCR532BLE.fff0
        ], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }
    
    func startScanAll() {
        guard centralManager.state == .poweredOn else {
            lastErrorMessage = "Bluetooth is off"
            return
        }
        discoveredDevices.removeAll()
        isScanning = true
        centralManager.scanForPeripherals(withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }
    
    func stopScan() {
        isScanning = false
        centralManager.stopScan()
    }
    
    func connect(to device: BLEDevice) {
        connectionState = .connecting
        lastErrorMessage = nil
        didInitPN532 = false
        charMapTried = 0
        writeCharacteristic = nil
        notifyCharacteristic = nil
        candidateWrite.removeAll()
        candidateNotify.removeAll()
        responseBuffer.clear()
        stopScan()
        centralManager.connect(device.peripheral, options: nil)
        connectedPeripheral = device.peripheral
        connectedPeripheral?.delegate = self
    }
    
    func disconnect() {
        guard let p = connectedPeripheral else { return }
        failPending(PN532Error.notConnected)
        centralManager.cancelPeripheralConnection(p)
    }
    
    /// Transparent UART send matching libnfc pn532_uart: stream bytes, wait ACK then response.
    func sendFrame(_ frame: PN532Frame, timeout: TimeInterval = 8.0) async throws -> PN532Frame {
        guard let peripheral = connectedPeripheral else { throw PN532Error.notConnected }
        guard connectionState == .ready, writeCharacteristic != nil else {
            throw PN532Error.communicationError("Write characteristic not ready")
        }
        
        if !didInitPN532 {
            try await initializePN532()
        }
        
        responseBuffer.clear()
        let raw = frame.encode()
        appendDebug("TX " + hex(raw))
        try await writeBytes(raw, peripheral: peripheral)
        
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let rem = deadline.timeIntervalSinceNow
            if rem <= 0 { break }
            do {
                let resp = try await waitForNextFrame(timeout: rem)
                if resp.isAckPlaceholder {
                    appendDebug("RX ACK")
                    continue
                }
                if resp.tfi == .pn532ToHost {
                    appendDebug("RX " + hex(resp.data))
                    return resp
                }
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
    
    // MARK: Init — mirror libnfc pn532_uart_wakeup + SAM + GetFirmwareVersion
    
    private func initializePN532() async throws {
        guard let peripheral = connectedPeripheral else { throw PN532Error.notConnected }
        
        // Try current mapping, then alternate write/notify pairs if firmware fails
        let maps = buildCharMaps()
        var lastErr: Error = PN532Error.timeout
        
        for (idx, map) in maps.enumerated() {
            writeCharacteristic = map.write
            notifyCharacteristic = map.notify
            if let n = notifyCharacteristic {
                peripheral.setNotifyValue(true, for: n)
            }
            try await Task.sleep(nanoseconds: 200_000_000)
            
            responseBuffer.clear()
            // libnfc wake: 0x55 0x55 + 14x 0x00
            let wake: [UInt8] = [0x55, 0x55] + [UInt8](repeating: 0x00, count: 14)
            try await writeBytes(wake, peripheral: peripheral)
            try await Task.sleep(nanoseconds: 100_000_000)
            
            // SAMConfiguration: D4 14 01 00 01  (mode normal, timeout 0, use IRQ)
            // Note: libnfc often uses 01 14 01
            responseBuffer.clear()
            let sam = PN532Frame(tfi: .hostToPN532, data: [0x14, 0x01, 0x14, 0x01])
            try await writeBytes(sam.encode(), peripheral: peripheral)
            _ = try? await waitAckThenData(timeout: 2.5)
            
            // GetFirmwareVersion: D4 02
            responseBuffer.clear()
            let fw = PN532Frame(tfi: .hostToPN532, data: [0x02])
            try await writeBytes(fw.encode(), peripheral: peripheral)
            do {
                let resp = try await waitAckThenData(timeout: 3.5)
                if resp.tfi == .pn532ToHost {
                    let d = resp.data
                    // response opcode 0x03 then IC/VER/REV/SUPPORT
                    appendDebug("FW map#\(idx) " + hex(d))
                    didInitPN532 = true
                    charMapTried = idx
                    return
                }
            } catch {
                lastErr = error
                appendDebug("FW fail map#\(idx): \(error.localizedDescription)")
            }
            
            // Diagnose 0x00 also used by libnfc check_communication
            responseBuffer.clear()
            let diag = PN532Frame(tfi: .hostToPN532, data: [0x00, 0x00])
            try await writeBytes(wake + diag.encode(), peripheral: peripheral)
            if let resp = try? await waitAckThenData(timeout: 3.0), resp.tfi == .pn532ToHost {
                appendDebug("DIAG ok map#\(idx)")
                didInitPN532 = true
                charMapTried = idx
                return
            }
        }
        
        // Continue anyway — some firmwares reply only to card cmds after field on
        didInitPN532 = true
        appendDebug("Init weak: \(lastErr.localizedDescription)")
    }
    
    private struct CharMap {
        let write: CBCharacteristic
        let notify: CBCharacteristic?
    }
    
    private func buildCharMaps() -> [CharMap] {
        var maps: [CharMap] = []
        // Prefer known pairs
        let wKnown = candidateWrite.sorted { a, b in scoreWrite(a) > scoreWrite(b) }
        let nKnown = candidateNotify.sorted { a, b in scoreNotify(a) > scoreNotify(b) }
        
        if let w = wKnown.first {
            if let n = nKnown.first {
                maps.append(CharMap(write: w, notify: n))
                if n.uuid != w.uuid {
                    // swapped
                    if candidateWrite.contains(where: { $0.uuid == n.uuid }) || n.properties.contains(.write) || n.properties.contains(.writeWithoutResponse) {
                        maps.append(CharMap(write: n, notify: w))
                    }
                }
            } else {
                maps.append(CharMap(write: w, notify: nil))
            }
        }
        
        // Every writeable as write, every notifiable as notify
        for w in candidateWrite {
            for n in candidateNotify {
                let m = CharMap(write: w, notify: n)
                if !maps.contains(where: { $0.write.uuid == m.write.uuid && $0.notify?.uuid == m.notify?.uuid }) {
                    maps.append(m)
                }
            }
        }
        
        // Single dual-role chars
        for c in candidateWrite where c.properties.contains(.notify) || c.properties.contains(.indicate) {
            let m = CharMap(write: c, notify: c)
            if !maps.contains(where: { $0.write.uuid == m.write.uuid && $0.notify?.uuid == m.notify?.uuid }) {
                maps.append(m)
            }
        }
        
        return maps
    }
    
    private func scoreWrite(_ c: CBCharacteristic) -> Int {
        var s = 0
        let u = c.uuid
        if u == PCR532BLE.nordicWrite { s += 100 }
        if u == PCR532BLE.ffe1 { s += 90 }
        if u == PCR532BLE.fff1 { s += 85 }
        if u == PCR532BLE.fff2 { s += 70 }
        if c.properties.contains(.writeWithoutResponse) { s += 10 }
        if c.properties.contains(.write) { s += 5 }
        return s
    }
    
    private func scoreNotify(_ c: CBCharacteristic) -> Int {
        var s = 0
        let u = c.uuid
        if u == PCR532BLE.nordicNotify { s += 100 }
        if u == PCR532BLE.ffe1 { s += 90 }
        if u == PCR532BLE.fff2 { s += 85 }
        if u == PCR532BLE.fff1 { s += 70 }
        if c.properties.contains(.notify) { s += 10 }
        if c.properties.contains(.indicate) { s += 5 }
        return s
    }
    
    private func waitAckThenData(timeout: TimeInterval) async throws -> PN532Frame {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let rem = max(deadline.timeIntervalSinceNow, 0.05)
            let resp = try await waitForNextFrame(timeout: rem)
            if resp.isAckPlaceholder { continue }
            return resp
        }
        throw PN532Error.timeout
    }
    
    private func waitForNextFrame(timeout: TimeInterval) async throws -> PN532Frame {
        if let frame = try responseBuffer.extractFrame() {
            return frame
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<PN532Frame, Error>) in
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
        
        let canWOR = writeChar.properties.contains(.writeWithoutResponse)
        let canW = writeChar.properties.contains(.write)
        // Prefer withResponse when available — more reliable on some modules
        let writeType: CBCharacteristicWriteType = {
            if canW && !preferWithoutResponse { return .withResponse }
            if canWOR { return .withoutResponse }
            if canW { return .withResponse }
            return .withoutResponse
        }()
        
        // Prefer single write for entire payload (critical for PN532 frame integrity)
        let maxOnce = peripheral.maximumWriteValueLength(for: writeType)
        let chunkSize = max(20, maxOnce > 0 ? maxOnce : mtuChunkSize)
        
        if data.count <= chunkSize {
            peripheral.writeValue(Data(data), for: writeChar, type: writeType)
            try await Task.sleep(nanoseconds: 50_000_000)
            return
        }
        
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            peripheral.writeValue(Data(Array(data[offset..<end])), for: writeChar, type: writeType)
            offset = end
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try await Task.sleep(nanoseconds: 40_000_000)
    }
    
    private func appendDebug(_ s: String) {
        lastDebugLog = s
        #if DEBUG
        print("[PCR532] \(s)")
        #endif
    }
    
    private func hex(_ d: [UInt8]) -> String {
        d.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
    
    private func markReadyIfPossible() {
        if writeCharacteristic != nil || !candidateWrite.isEmpty {
            if writeCharacteristic == nil {
                writeCharacteristic = candidateWrite.sorted { scoreWrite($0) > scoreWrite($1) }.first
            }
            if notifyCharacteristic == nil {
                notifyCharacteristic = candidateNotify.sorted { scoreNotify($0) > scoreNotify($1) }.first
                if let n = notifyCharacteristic, let p = connectedPeripheral {
                    p.setNotifyValue(true, for: n)
                }
            }
            connectionState = .ready
            isConnected = true
            lastErrorMessage = nil
            let w = writeCharacteristic?.uuid.uuidString ?? "?"
            let n = notifyCharacteristic?.uuid.uuidString ?? "?"
            appendDebug("Ready W=\(w) N=\(n)")
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
        if name.isEmpty { return }
        let device = BLEDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue, peripheral: peripheral)
        if let i = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
            discoveredDevices[i] = device
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
        if maxLen > 0 { mtuChunkSize = max(20, min(maxLen, 180)) }
        delegate?.bleDidConnect(BLEDevice(id: peripheral.identifier, name: peripheral.name ?? "", rssi: 0, peripheral: peripheral))
        // Discover ALL services — PCR532 BLE bridges use various custom UUIDs
        peripheral.discoverServices(nil)
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionState = .disconnected
        isConnected = false
        lastErrorMessage = error?.localizedDescription ?? "Connect failed"
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
            return
        }
        let services = peripheral.services ?? []
        if services.isEmpty {
            lastErrorMessage = "No BLE services"
            connectionState = .disconnected
            return
        }
        appendDebug("Services: \(services.map { $0.uuid.uuidString }.joined(separator: ","))")
        for s in services {
            peripheral.discoverCharacteristics(nil, for: s)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            lastErrorMessage = error.localizedDescription
            return
        }
        for c in service.characteristics ?? [] {
            let canW = c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse)
            let canN = c.properties.contains(.notify) || c.properties.contains(.indicate)
            appendDebug("Char \(c.uuid.uuidString) W=\(canW) N=\(canN)")
            if canW { candidateWrite.append(c) }
            if canN {
                candidateNotify.append(c)
                peripheral.setNotifyValue(true, for: c) // subscribe all notifiable
            }
        }
        markReadyIfPossible()
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            delegate?.bleDidEncounterError(error)
            return
        }
        guard let value = characteristic.value, !value.isEmpty else { return }
        let bytes = [UInt8](value)
        appendDebug("NOTIFY " + hex(bytes))
        responseBuffer.append(bytes)
        deliverBufferedFrames()
        delegate?.bleDidReceiveData(bytes)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            // Some modules error on withResponse; flip preference
            preferWithoutResponse = true
            appendDebug("Write err: \(error.localizedDescription)")
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            appendDebug("Notify state err: \(error.localizedDescription)")
        } else {
            appendDebug("Notify ON \(characteristic.uuid.uuidString)")
        }
    }
}