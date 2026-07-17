import SwiftUI

// MARK: - Card Info View
struct CardInfoView: View {
    let cardInfo: CardInfo?
    @ObservedObject var mifareController: MIFAREController
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
                    DetailRow(label: "扇区数", value: "\(card.totalSectors)")
                    DetailRow(label: "总块数", value: "\(card.totalBlocks)")
                    if card.isMagicCard {
                        HStack {
                            Image(systemName: "wand.and.stars")
                                .foregroundColor(.yellow)
                            Text("魔术卡检测!")
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
                            Text("读取全卡")
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
                            Text("保存 Dump")
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
                    Text("未检测到卡片")
                        .font(.title2)
                        .foregroundColor(.gray)
                    Text("请将卡片靠近读写器\n然后点击「检测卡片」")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    
                    Button(action: { detectCard() }) {
                        HStack {
                            Image(systemName: "waveform.path.ecg")
                            Text("检测卡片")
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
        .alert("保存 Dump", isPresented: $showDumpAlert) {
            TextField("Dump 名称", text: $dumpName)
            Button("取消", role: .cancel) { }
            Button("保存") {
                if !dumpName.isEmpty {
                    _ = mifareController.saveCurrentDump(name: dumpName)
                    dumpName = ""
                }
            }
        } message: {
            Text("为当前卡片数据命名")
        }
    }
    
    private func detectCard() {
        isDetecting = true
        errorMessage = nil
        
        Task {
            do {
                let _ = try await mifareController.detectCard()
            } catch {
                errorMessage = error.localizedDescription
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
                    errorMessage = error.localizedDescription
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
                Text("扇区列表")
                    .font(.headline)
                Spacer()
                Text("已解密: \(mifareController.sectors.filter { $0.isAuthenticated }.count)/\(mifareController.sectors.count)")
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
                    Text("尚未加载扇区数据\n请先读取全卡")
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
                Text("扇区 \(sector.number)")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                if sector.isAuthenticated {
                    Text("已解密")
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
                    Text("密钥 \(keyType == 0x60 ? "A" : "B"):")
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
                    Text("(扇区尾块)")
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
                        Text("扇区 \(sector.number) - Block \(block.number)")
                            .font(.headline)
                        if block.isSectorTrailer {
                            Text("⚠️ 扇区尾块 - 包含密钥和访问位")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal)
                
                // Hex editor
                VStack(alignment: .leading, spacing: 8) {
                    Text("十六进制数据 (16字节):")
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
                    if let bytes = HexUtils.hexToBytes(hexText), bytes.count == 16 {
                        Text("ASCII: \(HexUtils.bytesToASCII(bytes))")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                .padding(.horizontal)
                
                // Quick access buttons
                if block.isSectorTrailer {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("快捷操作:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        HStack(spacing: 12) {
                            QuickActionButton("全 FF 密钥", color: .blue) {
                                setTrailerKey(key: [UInt8](repeating: 0xFF, count: 6), keyB: [UInt8](repeating: 0xFF, count: 6))
                            }
                            QuickActionButton("全 00 密钥", color: .orange) {
                                setTrailerKey(key: [UInt8](repeating: 0x00, count: 6), keyB: [UInt8](repeating: 0x00, count: 6))
                            }
                            QuickActionButton("默认访问位", color: .green) {
                                setDefaultAccessBits()
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                
                Spacer()
                
                // Action buttons
                HStack(spacing: 16) {
                    Button("取消") {
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
                                Text("写入")
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
            .navigationTitle("十六进制编辑器")
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
            errorMessage = "最多32个十六进制字符 (16字节)"
            return
        }
        guard cleaned.count % 2 == 0 else {
            errorMessage = "十六进制字符数必须为偶数"
            return
        }
        guard HexUtils.isValidHex(cleaned) else {
            errorMessage = "包含无效的十六进制字符"
            return
        }
        errorMessage = nil
    }
    
    private func writeBlock() {
        let bytes = HexUtils.hexToBytes(hexText)
        guard bytes.count == 16 else {
            errorMessage = "需要16字节数据"
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
                        errorMessage = "写入失败"
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
        guard var currentBytes = HexUtils.hexToBytes(hexText), currentBytes.count == 16 else { return }
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