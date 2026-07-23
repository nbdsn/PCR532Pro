import Foundation
import CoreBluetooth

// MARK: - BLE Service & Characteristic UUIDs
struct PCR532BLE {
    /// Standard SPP-over-BLE service UUID (HM-10 / HC-08 compatible)
    static let serviceUUID = CBUUID(string: "00001101-0000-1000-8000-00805F9B34FB")
    
    /// Nordic UART Service
    static let nordicUARTServiceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    
    /// Common transparent UART (JDY / HM-10 style FFE0/FFE1)
    static let ffeServiceUUID = CBUUID(string: "0000FFE0-0000-1000-8000-00805F9B34FB")
    static let ffeCharUUID = CBUUID(string: "0000FFE1-0000-1000-8000-00805F9B34FB")
    
    /// Another common pair (FFF0)
    static let fffServiceUUID = CBUUID(string: "0000FFF0-0000-1000-8000-00805F9B34FB")
    static let fffCharUUID = CBUUID(string: "0000FFF1-0000-1000-8000-00805F9B34FB")
    
    /// Custom SPP TX/RX (legacy)
    static let customTxUUID = CBUUID(string: "00001102-0000-1000-8000-00805F9B34FB")
    static let customRxUUID = CBUUID(string: "00001103-0000-1000-8000-00805F9B34FB")
    
    /// Nordic NUS: phone writes RX (002), device notifies TX (003)
    static let nordicRXCharUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    static let nordicTXCharUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    
    static let nameFilters = ["PCR532", "PCR5", "HC-", "BLE", "UART", "BT05", "JDY", "BT-", "MLT", "SPP"]
    
    static let knownServiceUUIDs: [CBUUID] = [
        serviceUUID, nordicUARTServiceUUID, ffeServiceUUID, fffServiceUUID
    ]
}

// MARK: - BLE Manager Delegate
protocol BLEManagerDelegate: AnyObject {
    func bleDidUpdateState(_ isPoweredOn: Bool)
    func bleDidDiscoverDevice(_ device: BLEDevice)
    func bleDidConnect(_ device: BLEDevice)
    func bleDidDisconnect(_ device: BLEDevice, error: Error?)
    func bleDidReceiveData(_ data: [UInt8])
    func bleDidEncounterError(_ error: Error)
}

// MARK: - BLE Device Model
struct BLEDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
    let peripheral: CBPeripheral
    
    static func == (lhs: BLEDevice, rhs: BLEDevice) -> Bool {
        lhs.id == rhs.id
    }
    
    var signalStrength: String {
        if rssi >= -50 { return "信号强" }
        if rssi >= -70 { return "信号中" }
        if rssi >= -85 { return "信号弱" }
        return "信号极弱"
    }
    
    var signalBars: Int {
        if rssi >= -50 { return 4 }
        if rssi >= -65 { return 3 }
        if rssi >= -80 { return 2 }
        if rssi >= -90 { return 1 }
        return 0
    }
}

// MARK: - BLE Manager
class BLEManager: NSObject, ObservableObject {
    @Published var isScanning = false
    @Published var isConnected = false
    @Published var connectedDeviceName = ""
    @Published var discoveredDevices = [BLEDevice]()
    @Published var connectionState: ConnectionState = .disconnected
    @Published var lastErrorMessage: String?
    
    enum ConnectionState: String {
        case disconnected = "未连接"
        case connecting = "连接中..."
        case discovering = "发现服务..."
        case ready = "已就绪"
    }
    
    weak var delegate: BLEManagerDelegate?
    
    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var responseBuffer = PN532ResponseBuffer()
    
    private var onFrameReceived: ((Result<PN532Frame, Error>) -> Void)?
    private var pendingAckCallback: (() -> Void)?
    private var ackTimer: DispatchSourceTimer?
    private var discoveryFallbackUsed = false
    /// When false, accept any named peripheral (needed for PCR532 modules that omit service UUIDs in ads)
    private var filterByAdvertisedService = false
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }
    
    // MARK: - Public API
    
    /// Default scan: scan ALL BLE devices. Most PCR532 clones do NOT put UART service UUID in advertising data.
    func startScan() {
        startScanAll()
    }
    
    /// Optional: only peripherals advertising known UART service UUIDs
    func startScanFilteredByService() {
        guard centralManager.state == .poweredOn else {
            delegate?.bleDidEncounterError(PN532Error.communicationError("蓝牙未开启"))
            return
        }
        filterByAdvertisedService = true
        discoveredDevices.removeAll()
        isScanning = true
        centralManager.scanForPeripherals(
            withServices: PCR532BLE.knownServiceUUIDs,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }
    
    func startScanAll() {
        guard centralManager.state == .poweredOn else {
            delegate?.bleDidEncounterError(PN532Error.communicationError("蓝牙未开启"))
            return
        }
        filterByAdvertisedService = false
        discoveredDevices.removeAll()
        isScanning = true
        // nil = discover every advertising peripheral (required for HM-10/JDY/PCR532)
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
        writeCharacteristic = nil
        notifyCharacteristic = nil
        stopScan()
        centralManager.connect(device.peripheral, options: nil)
        connectedPeripheral = device.peripheral
        connectedPeripheral?.delegate = self
    }
    
    func disconnect() {
        guard let peripheral = connectedPeripheral else { return }
        cancelAckTimer()
        centralManager.cancelPeripheralConnection(peripheral)
    }
    
    func sendFrame(_ frame: PN532Frame) async throws -> PN532Frame {
        guard let peripheral = connectedPeripheral else {
            throw PN532Error.notConnected
        }
        guard connectionState == .ready, let writeChar = writeCharacteristic else {
            throw PN532Error.communicationError("写特征未就绪（设备可能未完成服务发现）")
        }
        
        let rawData = frame.encode()
        let writeType: CBCharacteristicWriteType =
            writeChar.properties.contains(.writeWithoutResponse) && !writeChar.properties.contains(.write)
            ? .withoutResponse : .withResponse
        
        peripheral.writeValue(Data(rawData), for: writeChar, type: writeType)
        
        return try await withCheckedThrowingContinuation { continuation in
            self.onFrameReceived = { result in
                continuation.resume(with: result)
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                if let callback = self?.onFrameReceived {
                    self?.onFrameReceived = nil
                    callback(.failure(PN532Error.timeout))
                }
            }
        }
    }
    
    func sendRaw(_ data: [UInt8]) {
        guard let peripheral = connectedPeripheral, connectionState == .ready else { return }
        guard let writeChar = writeCharacteristic else { return }
        let writeType: CBCharacteristicWriteType =
            writeChar.properties.contains(.writeWithoutResponse) && !writeChar.properties.contains(.write)
            ? .withoutResponse : .withResponse
        peripheral.writeValue(Data(data), for: writeChar, type: writeType)
    }
    
    // MARK: - Internal
    
    private func cancelAckTimer() {
        ackTimer?.cancel()
        ackTimer = nil
    }
    
    private func notifyFrame(_ result: Result<PN532Frame, Error>) {
        if let callback = onFrameReceived {
            onFrameReceived = nil
            callback(result)
        }
    }
    
    private func processReceivedData(_ data: [UInt8]) {
        responseBuffer.append(data)
        
        while true {
            do {
                if let frame = try responseBuffer.extractFrame() {
                    delegate?.bleDidReceiveData(frame.data)
                    notifyFrame(.success(frame))
                } else {
                    break
                }
            } catch {
                notifyFrame(.failure(error))
                break
            }
        }
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
        
        let isKnownWrite =
            uuid == PCR532BLE.nordicRXCharUUID ||
            uuid == PCR532BLE.customRxUUID ||
            uuid == PCR532BLE.customTxUUID ||
            uuid == PCR532BLE.ffeCharUUID ||
            uuid == PCR532BLE.fffCharUUID
        
        let isKnownNotify =
            uuid == PCR532BLE.nordicTXCharUUID ||
            uuid == PCR532BLE.customTxUUID ||
            uuid == PCR532BLE.ffeCharUUID ||
            uuid == PCR532BLE.fffCharUUID
        
        let canWrite = props.contains(.write) || props.contains(.writeWithoutResponse)
        let canNotify = props.contains(.notify) || props.contains(.indicate)
        
        if canWrite && (isKnownWrite || writeCharacteristic == nil) {
            if writeCharacteristic == nil || uuid == PCR532BLE.nordicRXCharUUID {
                writeCharacteristic = characteristic
            }
        }
        
        if canNotify && (isKnownNotify || notifyCharacteristic == nil) {
            if notifyCharacteristic == nil || uuid == PCR532BLE.nordicTXCharUUID {
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

// MARK: - CBCentralManagerDelegate
extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let poweredOn = central.state == .poweredOn
        delegate?.bleDidUpdateState(poweredOn)
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                       advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advertisedName ?? ""
        let rssiValue = RSSI.intValue
        
        // Keep unnamed only if it advertises a known service (rare but possible)
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let hasKnownService = serviceUUIDs.contains { PCR532BLE.knownServiceUUIDs.contains($0) }
        
        if name.isEmpty && !hasKnownService {
            return
        }
        
        let displayName = name.isEmpty ? "未命名设备" : name
        let device = BLEDevice(
            id: peripheral.identifier,
            name: displayName,
            rssi: rssiValue,
            peripheral: peripheral
        )
        
        if let index = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
            discoveredDevices[index] = device
        } else {
            discoveredDevices.append(device)
            // Sort by signal strength
            discoveredDevices.sort { $0.rssi > $1.rssi }
        }
        
        delegate?.bleDidDiscoverDevice(device)
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionState = .discovering
        connectedDeviceName = peripheral.name ?? "PCR532"
        delegate?.bleDidConnect(
            BLEDevice(id: peripheral.identifier, name: peripheral.name ?? "", rssi: 0, peripheral: peripheral)
        )
        
        // Prefer known services first; fallback discovers all if empty
        peripheral.discoverServices(PCR532BLE.knownServiceUUIDs)
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionState = .disconnected
        isConnected = false
        lastErrorMessage = error?.localizedDescription ?? "连接失败"
        delegate?.bleDidEncounterError(error ?? PN532Error.communicationError("连接失败"))
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectionState = .disconnected
        isConnected = false
        connectedDeviceName = ""
        writeCharacteristic = nil
        notifyCharacteristic = nil
        cancelAckTimer()
        
        delegate?.bleDidDisconnect(
            BLEDevice(id: peripheral.identifier, name: peripheral.name ?? "", rssi: 0, peripheral: peripheral),
            error: error
        )
    }
}

// MARK: - CBPeripheralDelegate
extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            lastErrorMessage = error.localizedDescription
            delegate?.bleDidEncounterError(error)
            return
        }
        
        let services = peripheral.services ?? []
        
        if services.isEmpty {
            if !discoveryFallbackUsed {
                discoveryFallbackUsed = true
                peripheral.discoverServices(nil)
            } else {
                lastErrorMessage = "未发现 BLE 服务"
                connectionState = .disconnected
                isConnected = false
                delegate?.bleDidEncounterError(PN532Error.communicationError("未发现 BLE 服务"))
            }
            return
        }
        
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            lastErrorMessage = error.localizedDescription
            delegate?.bleDidEncounterError(error)
            return
        }
        
        guard let characteristics = service.characteristics else { return }
        
        for characteristic in characteristics {
            assignCharacteristic(characteristic, peripheral: peripheral)
        }
        
        markReadyIfPossible()
        
        if writeCharacteristic == nil {
            let remaining = (peripheral.services ?? []).contains { $0.characteristics == nil }
            if !remaining {
                lastErrorMessage = "未找到可写特征（请确认设备是否为 PCR532 蓝牙串口）"
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            delegate?.bleDidEncounterError(error)
            return
        }
        guard let value = characteristic.value else { return }
        processReceivedData([UInt8](value))
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            delegate?.bleDidEncounterError(error)
            notifyFrame(.failure(error))
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            lastErrorMessage = "订阅通知失败: \(error.localizedDescription)"
            delegate?.bleDidEncounterError(error)
        }
    }
}
