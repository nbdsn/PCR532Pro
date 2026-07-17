import Foundation
import CoreBluetooth

// MARK: - PN532 Error
enum PN532Error: LocalizedError {
    case invalidResponse
    case ackFailed
    case nackReceived
    case timeout
    case notConnected
    case noCardPresent
    case authFailed
    case invalidFrame
    case communicationError(String)
    case hardwareError(UInt8)
    case cardRemoved
    case unknownError
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "无效响应"
        case .ackFailed: return "ACK 确认失败"
        case .nackReceived: return "NACK 拒绝"
        case .timeout: return "通信超时"
        case .notConnected: return "设备未连接"
        case .noCardPresent: return "未检测到卡片"
        case .authFailed: return "认证失败"
        case .invalidFrame: return "无效数据帧"
        case .communicationError(let s): return "通信错误: \(s)"
        case .hardwareError(let c): return "硬件错误码: 0x\(String(format: "%02X", c))"
        case .cardRemoved: return "卡片已移除"
        case .unknownError: return "未知错误"
        }
    }
}

// MARK: - PN532 Frame
struct PN532Frame {
    /// TFI (Transport Frame Identifier)
    enum TFI: UInt8 {
        case hostToPN532 = 0xD4   // 主机 → PN532
        case pn532ToHost = 0xD5   // PN532 → 主机
    }
    
    /// ACK frame bytes
    static let ack: [UInt8] = [0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00]
    
    /// NACK frame bytes
    static let nack: [UInt8] = [0x00, 0x00, 0xFF, 0x01, 0xFE, 0x00]
    
    /// Error response TFI
    static let errorTFI: UInt8 = 0x7F
    
    let tfi: TFI
    let data: [UInt8]
    
    /// Encode frame to raw bytes for BLE transmission
    func encode() -> [UInt8] {
        var frame = [UInt8]()
        let payload = [tfi.rawValue] + data
        let len = payload.count
        
        // Extended frame if data > 254 bytes
        if len > 254 {
            // Extended length (3 bytes: 0xFF, 0xFF, extended len)
            let extLen = UInt16(len)
            let lcsHigh = UInt16(0xFFFF) &- extLen
            let sum = payload.reduce(0) { UInt16($0) + UInt16($1) }
            let dcs = UInt8((0x0100 - (sum & 0xFF)) & 0xFF)
            
            frame.append(contentsOf: [0x00, 0x00, 0xFF])  // Preamble + Start
            frame.append(0xFF); frame.append(0xFF)          // Extended length marker
            frame.append(UInt8((extLen >> 8) & 0xFF))       // Extended len high
            frame.append(UInt8(extLen & 0xFF))              // Extended len low
            frame.append(UInt8((lcsHigh >> 8) & 0xFF))      // LCS high
            frame.append(UInt8(lcsHigh & 0xFF))             // LCS low
            frame.append(contentsOf: payload)               // TFI + Data
            frame.append(dcs)                                // DCS
            frame.append(0x00)                               // Postamble
        } else {
            let lcs = (0x0100 - UInt16(len)) & 0xFF
            let sum = payload.reduce(0) { $0 &+ $1 }
            let dcs = (0x0100 - UInt16(sum)) & 0xFF
            
            frame.append(contentsOf: [0x00, 0x00, 0xFF])  // Preamble + Start
            frame.append(UInt8(len))                       // Length
            frame.append(UInt8(lcs))                       // LCS
            frame.append(contentsOf: payload)              // TFI + Data
            frame.append(UInt8(dcs))                       // DCS
            frame.append(0x00)                             // Postamble
        }
        
        return frame
    }
    
    /// Parse raw bytes into a frame, returning the frame and remaining bytes
    static func parse(_ bytes: [UInt8]) throws -> (frame: PN532Frame, consumed: Int) {
        guard bytes.count >= 6 else { throw PN532Error.invalidFrame }
        
        var offset = 0
        
        // Check for ACK
        if bytes.starts(with: ack) {
            return (PN532Frame(tfi: .hostToPN532, data: []), ack.count)
        }
        
        // Check for NACK
        if bytes.starts(with: nack) {
            throw PN532Error.nackReceived
        }
        
        // Skip preamble (multiple 0x00)
        while offset < bytes.count && bytes[offset] == 0x00 {
            offset += 1
        }
        
        // Need at least start bytes
        guard offset + 2 < bytes.count else { throw PN532Error.invalidFrame }
        guard bytes[offset] == 0x00 && bytes[offset + 1] == 0xFF else {
            throw PN532Error.invalidFrame
        }
        offset += 2
        
        // Read length
        let len = bytes[offset]
        offset += 1
        
        var payloadLength: Int
        var dcsIndex: Int
        
        if len == 0xFF {
            // Extended frame
            guard offset + 1 < bytes.count else { throw PN532Error.invalidFrame }
            let extLenHigh = bytes[offset]
            let extLenLow = bytes[offset + 1]
            let extLen = (UInt16(extLenHigh) << 8) | UInt16(extLenLow)
            offset += 2
            
            // Extended LCS
            guard offset + 1 < bytes.count else { throw PN532Error.invalidFrame }
            offset += 2 // Skip extended LCS
            
            payloadLength = Int(extLen)
            dcsIndex = offset + payloadLength
        } else {
            // Normal frame: read LCS
            guard offset < bytes.count else { throw PN532Error.invalidFrame }
            let lcs = bytes[offset]
            let expectedLcs = (0x0100 - UInt16(len)) & 0xFF
            guard UInt8(expectedLcs) == lcs else {
                throw PN532Error.invalidFrame
            }
            offset += 1
            
            payloadLength = Int(len)
            dcsIndex = offset + payloadLength
        }
        
        // Read payload
        guard dcsIndex <= bytes.count else { throw PN532Error.invalidFrame }
        let payload = Array(bytes[offset..<dcsIndex])
        
        // Verify DCS
        guard dcsIndex < bytes.count else { throw PN532Error.invalidFrame }
        let dcs = bytes[dcsIndex]
        let sum = payload.reduce(0) { $0 &+ $1 }
        let expectedDcs = (0x0100 - UInt16(sum)) & 0xFF
        guard UInt8(expectedDcs) == dcs else {
            throw PN532Error.invalidFrame
        }
        
        // Check for error TFI
        if payload.first == errorTFI {
            let errorCode = payload.count > 1 ? payload[1] : 0
            throw PN532Error.hardwareError(errorCode)
        }
        
        // Determine TFI
        guard let firstByte = payload.first else { throw PN532Error.invalidFrame }
        let tfi: TFI
        if firstByte == TFI.hostToPN532.rawValue {
            tfi = .hostToPN532
        } else if firstByte == TFI.pn532ToHost.rawValue {
            tfi = .pn532ToHost
        } else {
            throw PN532Error.invalidFrame
        }
        
        let frameData = Array(payload.dropFirst())
        return (PN532Frame(tfi: tfi, data: frameData), dcsIndex + 1)
    }
}

// MARK: - PN532 Response Buffer Manager
class PN532ResponseBuffer {
    private var buffer = [UInt8]()
    private let maxBufferSize = 4096
    
    func append(_ data: [UInt8]) {
        buffer.append(contentsOf: data)
        if buffer.count > maxBufferSize {
            buffer = Array(buffer.suffix(maxBufferSize))
        }
    }
    
    func append(_ data: Data) {
        append([UInt8](data))
    }
    
    /// Try to extract a complete frame from the buffer
    func extractFrame() throws -> PN532Frame? {
        guard buffer.count >= 6 else { return nil }
        
        // Check for ACK first
        if buffer.starts(with: PN532Frame.ack) {
            buffer.removeFirst(PN532Frame.ack.count)
            return PN532Frame(tfi: .hostToPN532, data: [])
        }
        
        // Try to parse a frame starting at current position
        // First skip any stray bytes before 0x0000FF
        var startOffset = 0
        while startOffset < buffer.count - 2 {
            if buffer[startOffset] == 0x00 && buffer[startOffset + 1] == 0x00 && buffer[startOffset + 2] == 0xFF {
                break
            }
            startOffset += 1
        }
        
        guard startOffset < buffer.count - 2 else {
            // No valid start found, clear if too much junk
            if buffer.count > 50 { buffer.removeAll() }
            return nil
        }
        
        if startOffset > 0 {
            buffer.removeFirst(startOffset)
        }
        
        do {
            let (frame, consumed) = try PN532Frame.parse(buffer)
            buffer.removeFirst(consumed)
            return frame
        } catch {
            // If parse failed and we have enough data, clear and retry
            if buffer.count > 256 {
                buffer.removeFirst(6) // Remove minimal possible frame size
            }
            throw error
        }
    }
    
    func clear() {
        buffer.removeAll()
    }
}

// MARK: - Card Type Detection
struct CardInfo {
    let uid: [UInt8]
    let sak: UInt8
    let atqa: (UInt8, UInt8)
    let ats: [UInt8]?
    
    var uidString: String {
        uid.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
    
    var typeDescription: String {
        switch sak {
        case 0x08: return "MIFARE Classic 1K"
        case 0x09: return "MIFARE Classic Mini"
        case 0x18: return "MIFARE Classic 4K"
        case 0x28: return "MIFARE Plus 2K SL1"
        case 0x38: return "MIFARE Plus 4K SL1"
        case 0x20: return "MIFARE Ultralight / NTAG"
        case 0x00: return "MIFARE Ultralight"
        case 0x44: return "MIFARE DESFire"
        case 0x34: return "MIFARE DESFire 8K"
        case 0x10..<0x20: return "MIFARE Plus"
        default:
            if uid.count == 4 { return "MIFARE Classic (4字节 UID)" }
            if uid.count == 7 { return "MIFARE Classic (7字节 UID)" }
            return "未知卡片 (SAK: 0x\(String(format: "%02X", sak)))"
        }
    }
    
    var isMifareClassic: Bool {
        [0x08, 0x09, 0x18].contains(sak) || (sak & 0x18) != 0
    }
    
    var isMagicCard: Bool {
        uid.first == 0x08 || uid.first == 0x09 || uid.first == 0x88
    }
    
    var totalSectors: Int {
        switch sak {
        case 0x08, 0x09: return 16   // 1K
        case 0x18: return 40          // 4K
        case 0x28, 0x38: return 40    // Plus
        default: return 16
        }
    }
    
    var totalBlocks: Int {
        switch sak {
        case 0x08: return 64     // 1K
        case 0x09: return 20     // Mini
        case 0x18: return 256    // 4K
        default: return 64
        }
    }
}