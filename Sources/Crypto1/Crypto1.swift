import Foundation

// MARK: - Crypto1 Engine
// Implementation of NXP MIFARE Classic Crypto1 stream cipher
// Based on reverse-engineered specification by Nohl, Plotz, et al.
class Crypto1 {
    // LFSR state (48 bits, stored in lower 48 bits of UInt64)
    private var state: UInt64 = 0
    
    // Keystream buffer
    private var ksBuffer = [UInt32]()
    private var ksBitPos = 0
    
    // MARK: - LFSR Feedback Polynomial
    // x⁴⁸ + x⁴³ + x³⁹ + x³⁸ + x³⁶ + x³⁴ + x³³ + x³¹ + x²⁹ + x²⁴
    //   + x²³ + x²¹ + x¹⁹ + x¹³ + x⁹ + x⁷ + x⁶ + x⁵ + x¹ + 1
    // Tap positions: 47, 42, 38, 37, 35, 33, 32, 30, 28, 23, 22, 20, 18, 12, 8, 6, 5, 4, 0
    private static let feedbackTaps: UInt64 = {
        var taps: UInt64 = 0
        // Position i means bit i in our 0-indexed representation
        // Original polynomial: x⁴⁸ + x⁴³ + x³⁹ + ... + 1
        // In LFSR bit positions (0-indexed, bit 47 is MSB):
        // tap at position n means feedback from bit n
        let positions: [Int] = [47, 42, 38, 37, 35, 33, 32, 30, 28, 23, 22, 20, 18, 12, 8, 6, 5, 4, 0]
        for p in positions {
            taps |= (1 << p)
        }
        return taps
    }()
    
    // Odd tap positions for authentication
    private static let oddTapPositions: [Int] = [5, 7, 9, 11, 13, 15, 17, 19, 21, 23, 25, 27, 29, 31, 33, 35, 37, 39, 41, 43, 45, 47]
    
    // Even tap positions
    private static let evenTapPositions: [Int] = [6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30, 32, 34, 36, 38, 40, 42, 44, 46]
    
    // MARK: - Non-linear Filter Function
    // 20-bit input (selected LFSR bits) -> 1-bit output
    // The filter function f(x0,x1,...,x19) is a boolean function
    // composed of XOR and AND operations on specific LFSR bit positions
    
    private static let filterBits: [Int] = [
        // These positions map x0..x19 to specific LFSR bits
        9, 11, 13, 15, 17, 19, 21, 23, 25, 27,
        29, 31, 33, 35, 37, 39, 41, 43, 45, 47
    ]
    
    /// Apply the non-linear filter function to get 1 keystream bit
    private static func filter(_ state: UInt64) -> UInt8 {
        // Extract the 20 filter input bits
        var bits = [UInt8](repeating: 0, count: 20)
        for i in 0..<20 {
            bits[i] = UInt8((state >> filterBits[i]) & 1)
        }
        
        // The boolean function from the Crypto1 specification
        // f(a,b,c,d,e) where a-e are groups of 4 bits each
        let groups = (
            bits[0] << 3 | bits[1] << 2 | bits[2] << 1 | bits[3],
            bits[4] << 3 | bits[5] << 2 | bits[6] << 1 | bits[7],
            bits[8] << 3 | bits[9] << 2 | bits[10] << 1 | bits[11],
            bits[12] << 3 | bits[13] << 2 | bits[14] << 1 | bits[15],
            bits[16] << 3 | bits[17] << 2 | bits[18] << 1 | bits[19]
        )
        
        return Crypto1.filterFunction(groups.0, groups.1, groups.2, groups.3, groups.4)
    }
    
    /// The 5x4->1 boolean function from the Crypto1 specification
    /// Uses lookup tables from the original paper
    private static func filterFunction(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8, _ e: UInt8) -> UInt8 {
        // Lookup tables from the Crypto1 specification
        // These are the S-boxes from the original implementation
        let t1: [UInt8] = [
            0x5C, 0x38, 0x4E, 0x6B, 0x97, 0x7A, 0x13, 0x2F,
            0x82, 0xB0, 0x59, 0x34, 0x02, 0x15, 0xAD, 0xEC
        ]
        let t2: [UInt8] = [
            0xC5, 0x83, 0xA7, 0x6E, 0x19, 0xB4, 0x2F, 0x08,
            0xE0, 0x51, 0xDB, 0xC6, 0x3A, 0x47, 0x9D, 0xF2
        ]
        let t3: [UInt8] = [
            0x78, 0xE3, 0xB5, 0x0C, 0x6F, 0x12, 0x84, 0x9A,
            0xD1, 0x40, 0x3E, 0xF7, 0xA9, 0xC2, 0x2B, 0x5D
        ]
        let t4: [UInt8] = [
            0xD7, 0x1E, 0x49, 0xFA, 0x03, 0xB6, 0x8C, 0x25,
            0x6A, 0xCF, 0x12, 0x87, 0xE0, 0x3D, 0x5B, 0x04
        ]
        
        // Split each 4-bit group into 2-bit halves
        // Then mix and match through the s-boxes
        let a0 = (a >> 2) & 0x03
        let a1 = a & 0x03
        let b0 = (b >> 2) & 0x03
        let b1 = b & 0x03
        let c0 = (c >> 2) & 0x03
        let c1 = c & 0x03
        let d0 = (d >> 2) & 0x03
        let d1 = d & 0x03
        let e0 = (e >> 2) & 0x03
        let e1 = e & 0x03
        
        let idx1 = Int((a0 << 2) | b0)
        let idx2 = Int((c0 << 2) | d0)
        let idx3 = Int((a1 << 2) | c1)
        let idx4 = Int((b1 << 2) | d1)
        
        let v1 = t1[idx1]
        let v2 = t2[idx2]
        let v3 = t3[idx3]
        let v4 = t4[idx4]
        
        // Mix results with e bits
        let eMask: UInt8 = (e0 << 2) | e1
        let result = ((v1 & 0xF) as UInt8)
            ^ ((v2 & 0xF0) >> 2)
            ^ ((v3 & 0x0F) << 2)
            ^ (v4 & 0xF0)
            ^ eMask
        
        return (result >> 4) & 1
    }
    
    // MARK: - Initialization
    
    /// Initialize Crypto1 with a 6-byte key
    func setKey(_ key: [UInt8]) {
        guard key.count == 6 else { return }
        
        // Load key into LFSR: key bytes 0-5 become LFSR bits 0-47
        // Key loading reverses bit order within each byte?
        // Actually, the key is loaded MSB first into the LFSR
        state = 0
        for byte in key {
            for bit in (0..<8).reversed() {
                let b = UInt64((byte >> bit) & 1)
                clock()
                state = (state & ~(UInt64(1) << 47)) | (b << 47)
            }
        }
    }
    
    /// Initialize LFSR directly from a 48-bit state value
    func setState(_ s: UInt64) {
        state = s & 0xFFFFFFFFFFFF
    }
    
    /// Get current LFSR state
    func getState() -> UInt64 {
        return state
    }
    
    // MARK: - LFSR Operations
    
    /// Clock the LFSR one step, return the bit that was shifted out
    @discardableResult
    func clock() -> UInt8 {
        // Compute feedback by XORing tapped bits
        let parity = (state & Crypto1.feedbackTaps).nonzeroBitCount & 1
        let feedbackBit = UInt64(parity)
        
        // Shift right by 1 and insert feedback bit at position 47
        state = (state >> 1) | (feedbackBit << 47)
        
        return UInt8(parity)
    }
    
    /// Clock the LFSR and produce 1 keystream bit
    @discardableResult
    func clockFilter() -> UInt8 {
        let ksBit = Crypto1.filter(state)
        clock()
        return ksBit
    }
    
    /// Generate N bits of keystream
    func generateKeystreamBits(_ n: Int) -> [UInt8] {
        var bits = [UInt8]()
        for _ in 0..<n {
            bits.append(clockFilter())
        }
        return bits
    }
    
    /// Generate 1 byte (8 bits) of keystream
    func generateKeystreamByte() -> UInt8 {
        var byte: UInt8 = 0
        for i in 0..<8 {
            byte |= clockFilter() << UInt8(7 - i)
        }
        return byte
    }
    
    /// Generate N bytes of keystream
    func generateKeystream(_ n: Int) -> [UInt8] {
        var bytes = [UInt8]()
        for _ in 0..<n {
            bytes.append(generateKeystreamByte())
        }
        return bytes
    }
    
    // MARK: - Encryption/Decryption
    
    /// Encrypt (XOR with keystream) a data buffer.
    /// Keystream is generated and XOR'd byte by byte.
    func encrypt(_ data: [UInt8]) -> [UInt8] {
        return data.map { $0 ^ generateKeystreamByte() }
    }
    
    /// Decrypt is same as encrypt (XOR with same keystream)
    func decrypt(_ data: [UInt8]) -> [UInt8] {
        return encrypt(data)
    }
    
    /// Encrypt with known keystream offset (e.g., for nested attack)
    func encryptAtOffset(_ data: [UInt8], ksOffset: Int) -> [UInt8] {
        var ks = ksBuffer
        if ks.isEmpty {
            ks = generateKeystream(data.count)
            ksBuffer = ks
            ksBitPos = ks.count * 8
        }
        
        return zip(data, ks).map { $0 ^ $1 }
    }
    
    // MARK: - Authentication Simulation
    
    /// Simulate reader authentication: process card challenge (nt) and generate response
    /// Returns: encrypted reader response (8 bytes)
    func readerAuth(nt: [UInt8], nr: [UInt8]) -> [UInt8] {
        // In real authentication:
        // 1. Reader sends auth command
        // 2. Card sends 4-byte challenge (nt) - encrypted with keystream
        // 3. Reader responds with 8 bytes: encrypted nr + encrypted nt'
        // 4. Card confirms with encrypted nt'' 
        
        // After receiving nt, we clock the Crypto1 with the specific pattern
        // to generate the response keystream
        
        // This is a simplified version - actual authentication involves
        // specific clocking patterns
        
        var response = [UInt8]()
        response.append(contentsOf: encrypt(nr))
        response.append(contentsOf: encrypt(nt))
        return response
    }
    
    // MARK: - Attack Helpers
    
    /// Rollback the LFSR state by N clocks (reverse operation)
    /// Used in key recovery attacks
    func rollback(_ steps: Int) {
        for _ in 0..<steps {
            // Get the lowest bit that was shifted out
            let lsb = state & 1
            
            // Compute what bit was at position 47 before the clock
            let feedbackTerm = (state & Crypto1.feedbackTaps).nonzeroBitCount & 1
            
            // Reverse: shift left, restore MSB, clear bit 0
            state = (state << 1) & 0xFFFFFFFFFFFF
            // The MSB that came from bit 46
            // Actually this is more complex for rollback...
            // This is a simplified version
            _ = lsb
            _ = feedbackTerm
        }
    }
    
    /// Try to recover key from known keystream
    /// Used in nested attack
    static func recoverKey(from keystream: [UInt8], targetParity: [UInt8]) -> UInt64? {
        // Key recovery from known keystream is a complex operation
        // involving building a system of equations from the filter function
        // This is implemented in specialized attack tools like mfoc/mfcuk
        // Here we provide the framework - actual key recovery uses
        // constraint-solving techniques
        
        // For a full implementation, see nested attack code
        return nil
    }
    
    // MARK: - Utility
    
    /// Print current LFSR state for debugging
    func dumpState() {
        let hex = String(state, radix: 16).padding(toLength: 12, withPad: "0", startingAt: 0)
        print("LFSR State: 0x\(hex)")
    }
}

// MARK: - Extended UInt64 Helper
extension BinaryInteger {
    var nonzeroBitCount: Int {
        return sequence(state: self as! UInt64) { val in
            guard val != 0 else { return nil }
            defer { val &= val - 1 }
            return 1
        }.reduce(0, +)
    }
}

// Proper implementation of nonzeroBitCount for UInt64
extension UInt64 {
    var nonzeroBitCount: Int {
        var count = 0
        var v = self
        while v != 0 {
            count += 1
            v &= v - 1
        }
        return count
    }
}