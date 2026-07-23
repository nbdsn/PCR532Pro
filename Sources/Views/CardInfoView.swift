import SwiftUI

// MARK: - Card Info View
struct CardInfoView: View {
    let cardInfo: CardInfo?
    @ObservedObject var mifareController: MIFAREController
    @ObservedObject var bleManager: BLEManager
    @State private var isDetecting = false
    @State private var errorMessage: String?
    @State private var showDumpAlert = false
    @State private var dumpName = ""
    
    var body: some View {
        VStack(spacing: 16) {
            if let card = cardInfo {
                // Card type icon
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(LinearGradient(
                            gradient: Gradient(colors: [.blue, .purple]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(height: 120)
                    
                    VStack(spacing: 8) {
                        Image(systemName: "creditcard.and.123")
                            .font(.system(size: 36))
                            .foregroundColor(.white)
                        Text(card.typeDescription)
                            .font(.headline)
                            .foregroundColor(.white)
                    }
                }
                .padding(.horizontal)
                
                // Card details
                VStack(alignment: .leading, spacing: 12) {
                    DetailRow(label: "UID", value: card.uidString)
                    DetailRow(label: "SAK", value: String(format: "0x%02X", card.sak))
                    DetailRow(label: "ATQA", value: String(format: "0x%02X%02X", card.atqa.0, card.atqa.1))
                    DetailRow(label: "鎵囧尯鏁?, value: "\(card.totalSectors)")
                    DetailRow(label: "鎬诲潡鏁?, value: "\(card.totalBlocks)")
                    if card.isMagicCard {
                        HStack {
                            Image(systemName: "wand.and.stars")
                                .foregroundColor(.yellow)
                            Text("榄旀湳鍗℃娴?")
                                .foregroundColor(.yellow)
                                .fontWeight(.bold)
                        }
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
                .padding(.horizontal)
                
                // Action buttons
                VStack(spacing: 12) {
                    // Read full card
                    Button(action: { readFullCard() }) {
                        HStack {
                            Image(systemName: "arrow.down.doc.fill")
                            Text("璇诲彇鍏ㄥ崱")
                            if mifareController.isReading {
                                Spacer()
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .disabled(mifareController.isReading)
                    
                    // Save dump
                    Button(action: { showDumpAlert = true }) {
                        HStack {
                            Image(systemName: "square.and.arrow.down.fill")
                            Text("淇濆瓨 Dump")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .disabled(mifareController.sectors.isEmpty)
                }
                .padding(.horizontal)
                
                // Progress bar
                if mifareController.isReading {
                    VStack(spacing: 4) {
                        ProgressView(value: mifareController.progress)
                            .progressViewStyle(.linear)
                            .tint(.blue)
                        Text(mifareController.statusMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                }
                
                // Status message
                if !mifareController.statusMessage.isEmpty && !mifareController.isReading {
                    Text(mifareController.statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                }
                
            } else {
                // No card detected
                VStack(spacing: 20) {
                    Spacer()
                    Image(systemName: "creditcard.trianglebadge.exclamationmark")
                        .font(.system(size: 60))
                        .foregroundColor(.gray)
                    Text("鏈娴嬪埌鍗＄墖")
                        .font(.title2)
                        .foregroundColor(.gray)
                    Text("璇峰皢鍗＄墖闈犺繎璇诲啓鍣╘n鐒跺悗鐐瑰嚮銆屾娴嬪崱鐗囥€?)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    
                    Button(action: { detectCard() }) {
                        HStack {
                            Image(systemName: "waveform.path.ecg")
                            Text("妫€娴嬪崱鐗?)
                            if isDetecting {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .tint(.white)
                            }
                        }
                        .frame(maxWidth: 200)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .disabled(isDetecting)
                    
                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.horizontal)
                    }
                    
                    Spacer()
                }
            }
        }
        .alert("淇濆瓨 Dump", isPresented: $showDumpAlert) {
            TextField("Dump 鍚嶇О", text: $dumpName)
            Button("鍙栨秷", role: .cancel) { }
            Button("淇濆瓨") {
                if !dumpName.isEmpty {
                    _ = mifareController.saveCurrentDump(name: dumpName)
                    dumpName = ""
                }
            }
        } message: {
            Text("涓哄綋鍓嶅崱鐗囨暟鎹懡鍚?)
        }
    }
    
    private func detectCard() {
        isDetecting = true
        errorMessage = nil
        
        Task {
            do {
                let _ = try await mifareController.detectCard()
            } catch {
                errorMessage = "\(error.localizedDescription) | \(bleManager.lastDebugLog)"
            }
            await MainActor.run {
                isDetecting = false
            }
        }
    }
    
    private func readFullCard() {
        Task {
            do {
                _ = try await mifareController.readAllSectors()
            } catch {
                await MainActor.run {
                    errorMessage = "\(error.localizedDescription) | \(bleManager.lastDebugLog)"
                }
            }
        }
    }
}

// MARK: - Detail Row
struct DetailRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)
            Spacer()
        }
    }
}

// MARK: - Sector List View
struct SectorListView: View {
    @ObservedObject var mifareController: MIFAREController
    @Binding var selectedSector: MIFARESector?
    @State private var sortByNumber = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("鎵囧尯鍒楄〃")
                    .font(.headline)
                Spacer()
                Text("宸茶В瀵? \(mifareController.sectors.filter { $0.isAuthenticated }.count)/\(mifareController.sectors.count)")
                    .font(.caption)
                    .foregroundColor(.green)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            if mifareController.sectors.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 40))
                        .foregroundColor(.gray)
                    Text("灏氭湭鍔犺浇鎵囧尯鏁版嵁\n璇峰厛璇诲彇鍏ㄥ崱")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 80, maximum: 100))
                    ], spacing: 8) {
                        ForEach(Array(mifareController.sectors.enumerated()), id: \.element.id) { index, sector in
                            SectorCell(
                                sector: sector,
                                isSelected: selectedSector?.number == sector.number
                            )
                            .onTapGesture {
                                selectedSector = sector
                            }
                        }
                    }
                    .padding()
                }
            }
        }
    }
}

// MARK: - Sector Cell
struct SectorCell: View {
    let sector: MIFARESector
    let isSelected: Bool
    
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(backgroundColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
                    )
                
                VStack(spacing: 2) {
                    Text("S\(sector.number)")
                        .font(.caption)
                        .fontWeight(.bold)
                    if sector.isAuthenticated {
                        Image(systemName: "lock.open.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                    } else {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.red)
                    }
                }
            }
            .frame(height: 50)
        }
    }
    
    private var backgroundColor: Color {
        if isSelected { return Color.blue.opacity(0.15) }
        if sector.isAuthenticated { return Color.green.opacity(0.1) }
        return Color(.systemGray6)
    }
}

// MARK: - Sector Detail View
struct SectorDetailView: View {
    let sector: MIFARESector
    @ObservedObject var mifareController: MIFAREController
    @State private var editingBlock: MIFAREBlock?
    @State private var showHexEditor = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Sector header
            HStack {
                Image(systemName: sector.isAuthenticated ? "lock.open.fill" : "lock.fill")
                    .foregroundColor(sector.isAuthenticated ? .green : .red)
                Text("鎵囧尯 \(sector.number)")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                if sector.isAuthenticated {
                    Text("宸茶В瀵?)
                        .font(.caption)
                        .foregroundColor(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(4)
                }
            }
            .padding()
            
            // Key info
            if let key = sector.knownKey, let keyType = sector.knownKeyType {
                HStack {
                    Text("瀵嗛挜 \(keyType == 0x60 ? "A" : "B"):")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(key.map { String(format: "%02X", $0) }.joined(separator: " "))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.green)
                }
                .padding(.horizontal)
                .padding(.bottom, 4)
            }
            
            Divider()
            
            // Block list
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(sector.blocks) { block in
                        BlockRow(block: block, isEditable: block.isSectorTrailer || sector.isAuthenticated)
                            .onTapGesture {
                                editingBlock = block
                                showHexEditor = true
                            }
                    }
                }
                .padding()
            }
        }
        .sheet(isPresented: $showHexEditor) {
            if let block = editingBlock {
                HexEditorView(
                    block: block,
                    sector: sector,
                    mifareController: mifareController
                )
            }
        }
    }
}

// MARK: - Block Row
struct BlockRow: View {
    let block: MIFAREBlock
    let isEditable: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Block \(block.number)")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundColor(block.isSectorTrailer ? .orange : .primary)
                
                if block.isSectorTrailer {
                    Text("(鎵囧尯灏惧潡)")
                        .font(.system(size: 8))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(2)
                }
                
                Spacer()
                
                if isEditable {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                        .foregroundColor(.blue)
                }
            }
            
            // Hex data
            HStack(spacing: 0) {
                ForEach(0..<16, id: \.self) { i in
                    if i < block.data.count {
                        Text(String(format: "%02X", block.data[i]))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(block.isSectorTrailer && i >= 10 ? .green : (block.isSectorTrailer && i >= 6 && i < 10 ? .orange : .primary))
                            .frame(width: 18, alignment: .center)
                    }
                }
            }
            .padding(.vertical, 2)
            
            // ASCII representation
            HStack(spacing: 0) {
                ForEach(0..<16, id: \.self) { i in
                    if i < block.data.count {
                        let byte = block.data[i]
                        let char = (byte >= 32 && byte < 127) ? Character(UnicodeScalar(byte)) : "."
                        Text(String(char))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.gray)
                            .frame(width: 18, alignment: .center)
                    }
                }
            }
        }
        .padding(8)
        .background(block.isSectorTrailer ? Color.orange.opacity(0.05) : Color(.systemGray6))
        .cornerRadius(6)
    }
}

// MARK: - Hex Editor View
struct HexEditorView: View {
    let block: MIFAREBlock
    let sector: MIFARESector
    @ObservedObject var mifareController: MIFAREController
    @Environment(\.dismiss) var dismiss
    
    @State private var hexText: String
    @State private var errorMessage: String?
    @State private var isWriting = false
    
    init(block: MIFAREBlock, sector: MIFARESector, mifareController: MIFAREController) {
        self.block = block
        self.sector = sector
        self.mifareController = mifareController
        _hexText = State(initialValue: block.data.map { String(format: "%02X", $0) }.joined(separator: " "))
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                // Block info
                HStack {
                    VStack(alignment: .leading) {
                        Text("鎵囧尯 \(sector.number) - Block \(block.number)")
                            .font(.headline)
                        if block.isSectorTrailer {
                            Text("鈿狅笍 鎵囧尯灏惧潡 - 鍖呭惈瀵嗛挜鍜岃闂綅")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal)
                
                // Hex editor
                VStack(alignment: .leading, spacing: 8) {
                    Text("鍗佸叚杩涘埗鏁版嵁 (16瀛楄妭):")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    TextEditor(text: $hexText)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 100)
                        .padding(8)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.3))
                        )
                        .onChange(of: hexText) { newValue in
                            validateHex(newValue)
                        }
                    
                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    
                    // ASCII preview
                    let hexBytes = HexUtils.hexToBytes(hexText)
                    if hexBytes.count == 16 {
                        Text("ASCII: \(HexUtils.bytesToASCII(hexBytes))")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                .padding(.horizontal)
                
                // Quick access buttons
                if block.isSectorTrailer {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("蹇嵎鎿嶄綔:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        HStack(spacing: 12) {
                            QuickActionButton("鍏?FF 瀵嗛挜", color: .blue) {
                                setTrailerKey(key: [UInt8](repeating: 0xFF, count: 6), keyB: [UInt8](repeating: 0xFF, count: 6))
                            }
                            QuickActionButton("鍏?00 瀵嗛挜", color: .orange) {
                                setTrailerKey(key: [UInt8](repeating: 0x00, count: 6), keyB: [UInt8](repeating: 0x00, count: 6))
                            }
                            QuickActionButton("榛樿璁块棶浣?, color: .green) {
                                setDefaultAccessBits()
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                
                Spacer()
                
                // Action buttons
                HStack(spacing: 16) {
                    Button("鍙栨秷") {
                        dismiss()
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.systemGray5))
                    .cornerRadius(12)
                    
                    Button(action: { writeBlock() }) {
                        HStack {
                            if isWriting {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .tint(.white)
                            } else {
                                Image(systemName: "square.and.arrow.down")
                                Text("鍐欏叆")
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .disabled(isWriting || errorMessage != nil)
                }
                .padding()
            }
            .navigationTitle("鍗佸叚杩涘埗缂栬緫鍣?)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    private func validateHex(_ text: String) {
        let cleaned = text.replacingOccurrences(of: " ", with: "")
        if cleaned.isEmpty {
            errorMessage = nil
            return
        }
        guard cleaned.count <= 32 else {
            errorMessage = "鏈€澶?2涓崄鍏繘鍒跺瓧绗?(16瀛楄妭)"
            return
        }
        guard cleaned.count % 2 == 0 else {
            errorMessage = "鍗佸叚杩涘埗瀛楃鏁板繀椤讳负鍋舵暟"
            return
        }
        guard HexUtils.isValidHex(cleaned) else {
            errorMessage = "鍖呭惈鏃犳晥鐨勫崄鍏繘鍒跺瓧绗?
            return
        }
        errorMessage = nil
    }
    
    private func writeBlock() {
        let bytes = HexUtils.hexToBytes(hexText)
        guard bytes.count == 16 else {
            errorMessage = "闇€瑕?6瀛楄妭鏁版嵁"
            return
        }
        
        isWriting = true
        Task {
            do {
                let success = try await mifareController.writeBlock(block: block.number, data: bytes)
                await MainActor.run {
                    if success {
                        dismiss()
                    } else {
                        errorMessage = "鍐欏叆澶辫触"
                    }
                    isWriting = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isWriting = false
                }
            }
        }
    }
    
    private func setTrailerKey(key: [UInt8], keyB: [UInt8]) {
        var data = [UInt8]()
        data.append(contentsOf: key)           // Key A (6 bytes)
        data.append(contentsOf: [0xFF, 0x07, 0x80]) // Access bits (default)
        data.append(0x69)                      // User byte
        data.append(contentsOf: keyB)          // Key B (6 bytes)
        hexText = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        errorMessage = nil
    }
    
    private func setDefaultAccessBits() {
        var currentBytes = HexUtils.hexToBytes(hexText)
        guard currentBytes.count == 16 else { return }
        // Default access bits: 0xFF, 0x07, 0x80, 0x69
        // Key A readable, Key B readable, all access granted
        currentBytes[6] = 0xFF
        currentBytes[7] = 0x07
        currentBytes[8] = 0x80
        currentBytes[9] = 0x69
        hexText = currentBytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        errorMessage = nil
    }
}

// MARK: - Quick Action Button
struct QuickActionButton: View {
    let title: String
    let color: Color
    let action: () -> Void
    
    init(_ title: String, color: Color, action: @escaping () -> Void) {
        self.title = title
        self.color = color
        self.action = action
    }
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(color.opacity(0.15))
                .foregroundColor(color)
                .cornerRadius(6)
        }
    }
}
