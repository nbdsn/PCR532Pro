import Foundation

// MARK: - PN532 Command Codes
struct PN532Command {
    static let diagnose             = UInt8(0x00)
    static let getFirmwareVersion   = UInt8(0x02)
    static let readRegister         = UInt8(0x04)
    static let writeRegister        = UInt8(0x06)
    static let readGPIO             = UInt8(0x0C)
    static let writeGPIO            = UInt8(0x0E)
    static let setSerialBaudRate    = UInt8(0x10)
    static let setParameters        = UInt8(0x12)
    static let samConfiguration     = UInt8(0x14) // RFConfiguration is 0x32? No:
    // Official:
    // SAMConfiguration = 0x14
    // RFConfiguration = 0x32
    static let rfConfiguration      = UInt8(0x32)
    static let inRelease            = UInt8(0x52)
    static let inListPassiveTarget  = UInt8(0x4A)
    static let inDataExchange       = UInt8(0x40)
    static let inCommunicateThru    = UInt8(0x42)
    static let inAutoPoll           = UInt8(0x60)
    static let inSelect             = UInt8(0x54)
    static let inDeselect           = UInt8(0x44)
}

// NOTE: Correct official codes:
// SAMConfiguration = 0x14
// RFConfiguration = 0x32
// InListPassiveTarget = 0x4A
// InDataExchange = 0x40
// InCommunicateThru = 0x42
// InAutoPoll = 0x60
// InRelease = 0x52

// MARK: - MIFARE Classic Commands
struct MifareCommand {
    static let read                 = UInt8(0x30)
    static let write                = UInt8(0xA0)
    static let authKeyA             = UInt8(0x60)
    static let authKeyB             = UInt8(0x61)
    static let halt                 = UInt8(0x50)
}

// MARK: - PN532 Command Builder
struct PN532CommandBuilder {
    
    static func getFirmwareVersion() -> PN532Frame {
        PN532Frame(tfi: .hostToPN532, data: [PN532Command.getFirmwareVersion])
    }
    
    /// SAMConfiguration mode=1 (normal), timeout=0x14, useIRQ=1
    static func samConfiguration(mode: UInt8 = 0x01, timeout: UInt8 = 0x14, irq: UInt8 = 0x01) -> PN532Frame {
        PN532Frame(tfi: .hostToPN532, data: [0x14, mode, timeout, irq])
    }
    
    /// RFConfiguration item 0x01 MaxRetries: MxRtyATR, MxRtyPSL, MxRtyPassiveActivation
    static func rfConfigurationMaxRetries(atr: UInt8 = 0xFF, psl: UInt8 = 0x01, passive: UInt8 = 0xFF) -> PN532Frame {
        PN532Frame(tfi: .hostToPN532, data: [0x32, 0x05, atr, psl, passive])
    }
    
    static func setParameters(_ params: UInt8) -> PN532Frame {
        PN532Frame(tfi: .hostToPN532, data: [0x12, params])
    }
    
    static func autoPoll(maxCards: UInt8 = 1, period: UInt8 = 1) -> PN532Frame {
        // InAutoPoll 0x60: maxTg, period (x150ms), type1...
        let pollTypes: [UInt8] = [0x00] // 106kbps type A
        return PN532Frame(tfi: .hostToPN532,
                         data: [0x60, maxCards, period] + pollTypes)
    }
    
    static func listPassiveTarget(maxTargets: UInt8 = 1, baudRate: UInt8 = 0x00) -> PN532Frame {
        PN532Frame(tfi: .hostToPN532,
                  data: [0x4A, maxTargets, baudRate])
    }
    
    static func inRelease(target: UInt8 = 0x00) -> PN532Frame {
        PN532Frame(tfi: .hostToPN532, data: [0x52, target])
    }
    
    static func inDataExchange(target: UInt8 = 0x01, mifareCmd: UInt8, data: [UInt8]) -> PN532Frame {
        PN532Frame(tfi: .hostToPN532,
                  data: [0x40, target, mifareCmd] + data)
    }
    
    static func inCommunicateThru(_ data: [UInt8]) -> PN532Frame {
        PN532Frame(tfi: .hostToPN532, data: [0x42] + data)
    }
    
    static func mifareAuthenticateA(target: UInt8 = 0x01, block: UInt8, key: [UInt8], uid: [UInt8]) -> PN532Frame {
        // InDataExchange auth: 0x40, Tg, 0x60, block, key[6], uid[]
        PN532Frame(tfi: .hostToPN532,
                  data: [0x40, target, 0x60, block] + key + uid)
    }
    
    static func mifareAuthenticateB(target: UInt8 = 0x01, block: UInt8, key: [UInt8], uid: [UInt8]) -> PN532Frame {
        PN532Frame(tfi: .hostToPN532,
                  data: [0x40, target, 0x61, block] + key + uid)
    }
    
    static func mifareReadBlock(target: UInt8 = 0x01, block: UInt8) -> PN532Frame {
        PN532Frame(tfi: .hostToPN532, data: [0x40, target, 0x30, block])
    }
    
    static func mifareWriteBlock(target: UInt8 = 0x01, block: UInt8, data: [UInt8]) -> PN532Frame {
        PN532Frame(tfi: .hostToPN532, data: [0x40, target, 0xA0, block] + data)
    }
    
    static func mifareHalt() -> PN532Frame {
        PN532Frame(tfi: .hostToPN532, data: [0x42, 0x50, 0x00])
    }
    
    static func rawMifareAuth(keyType: UInt8, block: UInt8, key: [UInt8]) -> [UInt8] {
        [keyType, block] + key
    }
    
    static func rawMifareRead(block: UInt8) -> [UInt8] {
        [0x30, block]
    }
    
    static func rawMifareWrite(block: UInt8, data: [UInt8]) -> [UInt8] {
        [0xA0, block] + data
    }
}

// MARK: - Response Parsing
struct PN532ResponseParser {
    
    /// Strip response command byte (cmd+1) if present
    static func stripResponseOpcode(_ data: [UInt8], requestCmd: UInt8) -> [UInt8] {
        guard let first = data.first else { return data }
        if first == requestCmd &+ 1 {
            return Array(data.dropFirst())
        }
        return data
    }
    
    static func parseFirmware(_ data: [UInt8]) -> (ic: UInt8, ver: UInt8, rev: UInt8, support: UInt8) {
        let d = stripResponseOpcode(data, requestCmd: 0x02)
        guard d.count >= 4 else { return (0, 0, 0, 0) }
        return (d[0], d[1], d[2], d[3])
    }
    
    /// Parse InListPassiveTarget / InAutoPoll type-A target list payload (after stripping opcode)
    static func parseTargetList(_ data: [UInt8]) -> [CardInfo] {
        // Accept both with and without response opcode 0x4B / 0x61
        var body = data
        if let first = body.first, first == 0x4B || first == 0x61 || first == 0x55 {
            body = Array(body.dropFirst())
        }
        // InAutoPoll may include type/length wrappers; try simple path first
        guard body.count >= 1 else { return [] }
        
        // For InAutoPoll 0x61 response: [nbr, type, len, ...target...]
        // For InListPassiveTarget 0x4B: [NbTg, Tg, ATQA0, ATQA1, SAK, UIDLen, UID...]
        // Heuristic: if body[0] is small (<=2) and body.count > 5 treat as NbTg list
        let nbtg = Int(body[0])
        guard nbtg > 0 else { return [] }
        
        var cards = [CardInfo]()
        var offset = 1
        
        // Detect AutoPoll envelope: after nbr comes type then len
        if body.count > 3 && nbtg == 1 && body[1] <= 0x20 && Int(body[2]) + 3 <= body.count && body[2] >= 5 {
            // AutoPoll style: skip type, use len
            let type = body[1]
            _ = type
            let len = Int(body[2])
            offset = 3
            let target = Array(body[offset..<min(offset + len, body.count)])
            if let card = parseOneISO14443A(target, hasTg: true) {
                cards.append(card)
            }
            return cards
        }
        
        for _ in 0..<nbtg {
            if let (card, consumed) = parseOneISO14443AWithConsume(Array(body[offset...]), hasTg: true) {
                cards.append(card)
                offset += consumed
            } else {
                break
            }
        }
        
        return cards
    }
    
    private static func parseOneISO14443A(_ data: [UInt8], hasTg: Bool) -> CardInfo? {
        parseOneISO14443AWithConsume(data, hasTg: hasTg)?.0
    }
    
    private static func parseOneISO14443AWithConsume(_ data: [UInt8], hasTg: Bool) -> (CardInfo, Int)? {
        var offset = 0
        if hasTg {
            guard offset < data.count else { return nil }
            offset += 1 // Tg
        }
        guard offset + 2 < data.count else { return nil }
        let atqa0 = data[offset]
        let atqa1 = data[offset + 1]
        offset += 2
        guard offset < data.count else { return nil }
        let sak = data[offset]
        offset += 1
        guard offset < data.count else { return nil }
        let uidLen = Int(data[offset])
        offset += 1
        guard offset + uidLen <= data.count else { return nil }
        let uid = Array(data[offset..<offset + uidLen])
        offset += uidLen
        var ats: [UInt8]? = nil
        if offset < data.count {
            let atsLen = Int(data[offset])
            offset += 1
            if atsLen > 0 && offset + atsLen - 1 <= data.count {
                ats = Array(data[offset..<offset + max(atsLen - 1, 0)])
                offset += max(atsLen - 1, 0)
            }
        }
        return (CardInfo(uid: uid, sak: sak, atqa: (atqa0, atqa1), ats: ats), offset)
    }
    
    static func parseDataExchange(_ data: [UInt8]) -> (Bool, [UInt8]) {
        let d = stripResponseOpcode(data, requestCmd: 0x40)
        guard d.count >= 1 else { return (false, []) }
        let status = d[0]
        let responseData = d.count > 1 ? Array(d[1...]) : []
        return (status == 0x00, responseData)
    }
    
    static func parseCommunicateThru(_ data: [UInt8]) -> (Bool, [UInt8]) {
        let d = stripResponseOpcode(data, requestCmd: 0x42)
        guard d.count >= 1 else { return (false, []) }
        let status = d[0]
        let responseData = d.count > 1 ? Array(d[1...]) : []
        return (status == 0x00, responseData)
    }
}