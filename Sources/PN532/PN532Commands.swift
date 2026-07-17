import Foundation

// MARK: - PN532 Command Codes
struct PN532Command {
    // System commands
    static let diagnose             = UInt8(0x00)
    static let getFirmwareVersion   = UInt8(0x02)
    static let readRegister         = UInt8(0x04)
    static let writeRegister        = UInt8(0x06)
    static let readGPIO             = UInt8(0x0C)
    static let writeGPIO            = UInt8(0x0E)
    static let setSerialBaudRate    = UInt8(0x10)
    static let setParameters        = UInt8(0x12)
    static let rfConfiguration      = UInt8(0x14)
    static let rfRegulationTest     = UInt8(0x58)
    static let inRelease            = UInt8(0x18)
    static let inJetPD              = UInt8(0x1A)
    
    // Initiator commands
    static let inListPassiveTarget  = UInt8(0x4A)
    static let inDataExchange       = UInt8(0x40)
    static let inCommunicateThru    = UInt8(0x42)
    static let inAutoPoll           = UInt8(0x54)
    static let inSelect             = UInt8(0x50)
    static let inDeselect           = UInt8(0x44)
    static let inJumpForDEP         = UInt8(0x46)
    static let inATR                = UInt8(0x50)
    
    // Target commands
    static let tgInitAsTarget       = UInt8(0x2E)
    static let tgGetData            = UInt8(0x32)
    static let tgSetData            = UInt8(0x34)
    static let tgSetGeneralBytes    = UInt8(0x30)
    static let tgGetInitiatorCmd    = UInt8(0x38)
    static let tgResponseToInit     = UInt8(0x3A)
}

// MARK: - MIFARE Classic Commands
struct MifareCommand {
    static let read                 = UInt8(0x30)
    static let write                = UInt8(0xA0)
    static let authKeyA             = UInt8(0x60)
    static let authKeyB             = UInt8(0x61)
    static let halt                 = UInt8(0x50)
    static let getATS               = UInt8(0x40)
}

// MARK: - PN532 Command Builder
struct PN532CommandBuilder {
    
    // MARK: - System Commands
    
    /// Get firmware version
    static func getFirmwareVersion() -> PN532Frame {
        PN532Frame(tfi: .hostToPN532, data: [PN532Command.getFirmwareVersion])
    }
    
    /// Read PN532 register
    static func readRegister(_ address: UInt8) -> PN532Frame {
        PN532Frame(tfi: .hostToPN532, data: [PN532Command.readRegister, address])
    }
    
    /// Write PN532 register
    static func writeRegister(_ address: UInt8, value: UInt8) -> PN532Frame {
        PN532Frame(tfi: .hostToPN532, data: [PN532Command.writeRegister, address, value])
    }
    
    /// Set PN532 parameters
    static func setParameters(_ params: [UInt8]) -> PN532Frame {
        PN532Frame(tfi: .hostToPN532, data: [PN532Command.setParameters] + params)
    }
    
    /// Configure RF
    static func rfConfiguration(_ cfgType: UInt8, data: [UInt8]) -> PN532Frame {
        PN532Frame(tfi: .hostToPN532, data: [PN532Command.rfConfiguration, cfgType] + data)
    }
    
    // MARK: - Card Detection
    
    /// Auto poll for cards (returns first detected)
    static func autoPoll(maxCards: UInt8 = 1, period: UInt8 = 1) -> PN532Frame {
        // InAutoPoll: 0x54, maxCards, period, [pollType...]
        // Poll types: 0x00=ISO14443A, 0x01=ISO14443B, 0x02=ISO18092
        let pollTypes: [UInt8] = [0x00, 0x01, 0x02]
        return PN532Frame(tfi: .hostToPN532,
                         data: [PN532Command.inAutoPoll, maxCards, period] + pollTypes)
    }
    
    /// List passive targets (ISO14443A)
    static func listPassiveTarget(maxTargets: UInt8 = 1, baudRate: UInt8 = 0x00) -> PN532Frame {
        // baudRate: 0x00=106kbps (MIFARE), 0x01=212kbps, 0x02=424kbps
        PN532Frame(tfi: .hostToPN532,
                  data: [PN532Command.inListPassiveTarget, maxTargets, baudRate])
    }
    
    /// Release target
    static func inRelease() -> PN532Frame {
        PN532Frame(tfi: .hostToPN532, data: [PN532Command.inRelease])
    }
    
    // MARK: - Data Exchange
    
    /// Exchange data with selected card (hardware handles auth)
    /// - Parameters:
    ///   - target: target number (usually 0x01 for first card)
    ///   - mifareCmd: MIFARE command byte
    ///   - data: command data
    static func inDataExchange(target: UInt8 = 0x01, mifareCmd: UInt8, data: [UInt8]) -> PN532Frame {
        PN532Frame(tfi: .hostToPN532,
                  data: [PN532Command.inDataExchange, target, mifareCmd] + data)
    }
    
    /// Communicate directly with card (bypasses hardware auth)
    /// Used for attacks (nested, darkside)
    static func inCommunicateThru(_ data: [UInt8]) -> PN532Frame {
        PN532Frame(tfi: .hostToPN532,
                  data: [PN532Command.inCommunicateThru] + data)
    }
    
    // MARK: - MIFARE Convenience Helpers
    
    /// Authenticate with MIFARE Classic key A
    static func mifareAuthenticateA(target: UInt8 = 0x01, block: UInt8, key: [UInt8]) -> PN532Frame {
        inDataExchange(target: target, mifareCmd: MifareCommand.authKeyA, data: key + [block])
    }
    
    /// Authenticate with MIFARE Classic key B
    static func mifareAuthenticateB(target: UInt8 = 0x01, block: UInt8, key: [UInt8]) -> PN532Frame {
        inDataExchange(target: target, mifareCmd: MifareCommand.authKeyB, data: key + [block])
    }
    
    /// Read a block (must be authenticated first)
    static func mifareReadBlock(target: UInt8 = 0x01, block: UInt8) -> PN532Frame {
        inDataExchange(target: target, mifareCmd: MifareCommand.read, data: [block])
    }
    
    /// Write a block (must be authenticated first)
    static func mifareWriteBlock(target: UInt8 = 0x01, block: UInt8, data: [UInt8]) -> PN532Frame {
        inDataExchange(target: target, mifareCmd: MifareCommand.write, data: [block] + data)
    }
    
    /// Halt card
    static func mifareHalt(target: UInt8 = 0x01) -> PN532Frame {
        inCommunicateThru([MifareCommand.halt, 0x00])
    }
    
    // MARK: - Raw MIFARE Commands (for InCommunicateThru - attacks)
    
    /// Raw auth command through InCommunicateThru
    static func rawMifareAuth(keyType: UInt8, block: UInt8, key: [UInt8]) -> [UInt8] {
        // MIFARE auth command format: keyType (0x60/0x61), block, key (6 bytes)
        [keyType, block] + key
    }
    
    /// Raw read command through InCommunicateThru
    static func rawMifareRead(block: UInt8) -> [UInt8] {
        [MifareCommand.read, block]
    }
    
    /// Raw write command through InCommunicateThru
    static func rawMifareWrite(block: UInt8, data: [UInt8]) -> [UInt8] {
        [MifareCommand.write, block] + data
    }
}

// MARK: - Response Parsing
struct PN532ResponseParser {
    
    /// Parse GetFirmwareVersion response
    static func parseFirmware(_ data: [UInt8]) -> (ic: UInt8, ver: UInt8, rev: UInt8, support: UInt8) {
        guard data.count >= 4 else { return (0, 0, 0, 0) }
        return (data[0], data[1], data[2], data[3])
    }
    
    /// Parse InListPassiveTarget response
    /// Returns array of card info
    static func parseTargetList(_ data: [UInt8]) -> [CardInfo] {
        guard data.count >= 2, data[0] > 0 else { return [] }
        
        let nbtg = data[0]
        var cards = [CardInfo]()
        var offset = 1
        
        for _ in 0..<nbtg {
            guard offset + 1 < data.count else { break }
            let tg = data[offset]; offset += 1
            _ = tg // target number
            guard offset + 2 < data.count else { break }
            
            let atqaHigh = data[offset]
            let atqaLow = data[offset + 1]
            offset += 2
            
            let sak = data[offset]; offset += 1
            
            guard offset < data.count else { break }
            let uidLen = data[offset]; offset += 1
            
            guard offset + Int(uidLen) <= data.count else { break }
            let uid = Array(data[offset..<offset + Int(uidLen)]); offset += Int(uidLen)
            
            // ATS (optional)
            var ats: [UInt8]? = nil
            if offset < data.count {
                let atsLen = data[offset]; offset += 1
                if atsLen > 0 && offset + Int(atsLen) - 1 <= data.count {
                    ats = Array(data[offset..<offset + Int(atsLen) - 1])
                    offset += Int(atsLen) - 1
                }
            }
            
            cards.append(CardInfo(
                uid: uid, sak: sak,
                atqa: (atqaHigh, atqaLow), ats: ats
            ))
        }
        
        return cards
    }
    
    /// Parse InDataExchange response
    /// Returns: (success: Bool, data: [UInt8])
    static func parseDataExchange(_ data: [UInt8]) -> (Bool, [UInt8]) {
        guard data.count >= 1 else { return (false, []) }
        let status = data[0]
        let responseData = data.count > 1 ? Array(data[1...]) : []
        return (status == 0x00, responseData)
    }
    
    /// Parse InCommunicateThru response
    static func parseCommunicateThru(_ data: [UInt8]) -> (Bool, [UInt8]) {
        guard data.count >= 1 else { return (false, []) }
        let status = data[0]
        let responseData = data.count > 1 ? Array(data[1...]) : []
        return (status == 0x00, responseData)
    }
}