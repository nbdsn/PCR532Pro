import Foundation
import CoreBluetooth

// MARK: - BLE Service & Characteristic UUIDs
struct PCR532BLE {
    /// Standard SPP-over-BLE service UUID (HM-10 / HC-08 compatible)
    static let serviceUUID = CBUUID(string: "00001101-0000-1000-8000-00805F9B34FB")
    
    /// Nordic UART Service (alternative, some devices use this)
    static let nordicUARTServiceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    
    /// TX Characteristic (device → phone)
    static let txCharacteristicUUID = CBUUID(string: "00001102-0000-1000-8000-00805F9B34FB")
    static let nordicTXCharUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    
    /// RX Characteristic (phone → device)
    static let rxCharacteristicUUID = CBUUID(string: "00001103-0000-1000-8000-00805F9B34FB")
    static let nordicRXCharUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    
    /// Common name filters for device discovery
    static let nameFilters = ["PCR532", "PCR5", "HC-", "BLE", "UART", "BT05", "JDY"]
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
        if rssi >= -50 { return "📶 强" }
        if rssi >= -70 { return "📶 中" }
        if rssi >= -85 { return "📶 弱" }
        return "📶 极弱"
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
    
    enum ConnectionState: String {
        case disconnected = "未连接"
        case connecting = "连接中..."
        case discovering = "发现服务..."
        case ready = "已就绪"
    }
    
    weak var delegate: BLEManagerDelegate?
    
    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var txCharacteristic: CBCharacteristic?
    private var rxCharacteristic: CBCharacteristic?
    private var responseBuffer = PN532ResponseBuffer()
    
    // Async callbacks
    private var onFrameReceived: ((Result<PN532Frame, Error>) -> Void)?
    private var pendingAckCallback: (() -> Void)?
    private var ackTimer: DispatchSourceTimer?
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }
    
    // MARK: - Public API
    
    func startScan() {
        guard centralManager.state == .poweredOn else {
            delegate?.bleDidEncounterError(PN532Error.communicationError("蓝牙未开启"))
            return
        }
        
        discoveredDevices.removeAll()
        isScanning = true
        
        // Scan for SPP service and Nordic UART service
        centralManager.scanForPeripherals(withServices: [
            PCR532BLE.serviceUUID,
            PCR532BLE.nordicUARTServiceUUID
        ], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }
    
    func startScanAll() {
        // Scan all peripherals (for devices that don't advertise the UART service)
        guard centralManager.state == .poweredOn else { return }
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
        centralManager.connect(device.peripheral, options: nil)
        connectedPeripheral = device.peripheral
        connectedPeripheral?.delegate = self
    }
    
    func disconnect() {
        guard let peripheral = connectedPeripheral else { return }
        cancelAckTimer()
        centralManager.cancelPeripheralConnection(peripheral)
    }
    
    /// Send a PN532 frame and wait for the response
    func sendFrame(_ frame: PN532Frame) async throws -> PN532Frame {
        guard let peripheral = connectedPeripheral, isConnected else {
            throw PN532Error.notConnected
        }
        guard let txChar = txCharacteristic else {
            throw PN532Error.communicationError("TX 特征未找到")
        }
        
        let rawData = frame.encode()
        
        // Send data
        peripheral.writeValue(Data(rawData), for: txChar, type: .withResponse)
        
        // Wait for response
        return try await withCheckedThrowingContinuation { continuation in
            self.onFrameReceived = { result in
                continuation.resume(with: result)
            }
            
            // Timeout after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                if let callback = self?.onFrameReceived {
                    self?.onFrameReceived = nil
                    callback(.failure(PN532Error.timeout))
                }
            }
        }
    }
    
    /// Send raw bytes (for debugging)
    func sendRaw(_ data: [UInt8]) {
        guard let peripheral = connectedPeripheral, isConnected else { return }
        guard let txChar = txCharacteristic else { return }
        peripheral.writeValue(Data(data), for: txChar, type: .withResponse)
    }
    
    // MARK: - Internal
    
    private func setupAckTimer() {
        cancelAckTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 3.0, repeating: .never)
        timer.setEventHandler { [weak self] in
            self?.pendingAckCallback = nil
            self?.notifyFrame(.failure(PN532Error.timeout))
        }
        timer.resume()
        ackTimer = timer
    }
    
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
                    break // Need more data
                }
            } catch {
                notifyFrame(.failure(error))
                break
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
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "未知设备"
        let rssiValue = RSSI.intValue
        
        // Filter out unnamed or irrelevant devices
        guard !name.isEmpty else { return }
        
        let device = BLEDevice(id: peripheral.identifier, name: name, rssi: rssiValue, peripheral: peripheral)
        
        // Avoid duplicates
        if let index = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
            discoveredDevices[index] = device
        } else {
            discoveredDevices.append(device)
        }
        
        delegate?.bleDidDiscoverDevice(device)
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionState = .discovering
        isConnected = true
        connectedDeviceName = peripheral.name ?? "PCR532"
        delegate?.bleDidConnect(
            BLEDevice(id: peripheral.identifier, name: peripheral.name ?? "", rssi: 0, peripheral: peripheral)
        )
        
        peripheral.discoverServices([PCR532BLE.serviceUUID, PCR532BLE.nordicUARTServiceUUID])
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionState = .disconnected
        isConnected = false
        delegate?.bleDidEncounterError(error ?? PN532Error.communicationError("连接失败"))
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectionState = .disconnected
        isConnected = false
        connectedDeviceName = ""
        txCharacteristic = nil
        rxCharacteristic = nil
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
        guard let services = peripheral.services else { return }
        
        for service in services {
            let characteristicUUIDs: [CBUUID]
            if service.uuid == PCR532BLE.serviceUUID {
                characteristicUUIDs = [PCR532BLE.rxCharacteristicUUID, PCR532BLE.txCharacteristicUUID]
            } else {
                characteristicUUIDs = [PCR532BLE.nordicRXCharUUID, PCR532BLE.nordicTXCharUUID]
            }
            peripheral.discoverCharacteristics(characteristicUUIDs, for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        
        for characteristic in characteristics {
            // Determine if this is TX (notify) or RX (write) characteristic
            let isTX = characteristic.uuid == PCR532BLE.txCharacteristicUUID ||
                       characteristic.uuid == PCR532BLE.nordicTXCharUUID
            let isRX = characteristic.uuid == PCR532BLE.rxCharacteristicUUID ||
                       characteristic.uuid == PCR532BLE.nordicRXCharUUID
            
            if isTX {
                txCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            } else if isRX {
                rxCharacteristic = characteristic
            }
        }
        
        // Check if we have both characteristics
        if txCharacteristic != nil && rxCharacteristic != nil {
            connectionState = .ready
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        let bytes = [UInt8](value)
        processReceivedData(bytes)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            delegate?.bleDidEncounterError(error)
            notifyFrame(.failure(error))
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            delegate?.bleDidEncounterError(error)
        }
    }
}