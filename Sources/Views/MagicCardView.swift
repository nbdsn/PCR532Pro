import SwiftUI

// MARK: - Magic Card View
struct MagicCardView: View {
    @ObservedObject var magicController: MagicCardController
    @ObservedObject var mifareController: MIFAREController
    @State private var newUID = ""
    @State private var selectedOperation: MagicOperation = .writeUID
    @State private var isOperating = false
    @State private var resultMessage: String?
    @State private var showResult = false
    
    enum MagicOperation: String, CaseIterable {
        case writeUID = "改 UID"
        case writeBlock0 = "写 Block 0"
        case fuse = "融合卡片"
        case restore = "恢复出厂"
        case detect = "检测类型"
    }
    
    var body: some View {
        NavigationView {
            List {
                // Section: Card info
                if let card = mifareController.currentCard {
                    Section("当前卡片") {
                        HStack {
                            Text("UID")
                            Spacer()
                            Text(card.uidString)
                                .font(.system(.body, design: .monospaced))
                        }
                        HStack {
                            Text("类型")
                            Spacer()
                            Text(card.typeDescription)
                                .foregroundColor(.secondary)
                        }
                        HStack {
                            Text("魔术卡检测")
                            Spacer()
                            if card.isMagicCard {
                                Text("✅ 是")
                                    .foregroundColor(.green)
                            } else {
                                Text("❌ 否或未知")
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                }
                
                // Section: Operation
                Section("选择操作") {
                    Picker("操作", selection: $selectedOperation) {
                        ForEach(MagicOperation.allCases, id: \.self) { op in
                            Text(op.rawValue).tag(op)
                        }
                    }
                    .pickerStyle(.menu)
                }
                
                // Section: UID input (for write UID / write Block 0)
                if selectedOperation == .writeUID || selectedOperation == .writeBlock0 {
                    Section("新 UID (十六进制)") {
                        TextField("4字节: AABBCCDD 或 7字节: AABBCCDDEEFFGG", text: $newUID)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.characters)
                        
                        HStack {
                            QuickActionButton("随机 UID", color: .blue) {
                                newUID = generateRandomUID()
                            }
                            QuickActionButton("原 UID", color: .green) {
                                if let card = mifareController.currentCard {
                                    newUID = card.uidString.replacingOccurrences(of: ":", with: "")
                                }
                            }
                        }
                        
                        Text("示例: 4字节 UID = 8个字符, 7字节 = 14个字符")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                
                // Section: Action
                Section {
                    Button(action: { executeOperation() }) {
                        HStack {
                            Spacer()
                            if isOperating {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: operationIcon)
                                Text(operationButtonText)
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                        .foregroundColor(.white)
                        .listRowBackground(Color.blue)
                    }
                    .disabled(isOperating || !isOperationValid)
                }
                
                // Section: Warnings
                if selectedOperation == .fuse {
                    Section {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text("融合后卡片将永久化，无法再更改 UID。此操作不可逆！")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                }
                
                if selectedOperation == .writeBlock0 {
                    Section {
                        HStack {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(.orange)
                            Text("写 Block 0 会修改卡片的 UID、SAK 和 ATQA。请确保新 UID 格式正确。")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                }
                
                // Section: Result
                if let result = resultMessage, showResult {
                    Section("结果") {
                        Text(result)
                            .font(.subheadline)
                            .foregroundColor(result.contains("成功") ? .green : .red)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("魔术卡")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    private var operationIcon: String {
        switch selectedOperation {
        case .writeUID: return "pencil"
        case .writeBlock0: return "doc.badge.gearshape"
        case .fuse: return "lock.fill"
        case .restore: return "arrow.counterclockwise"
        case .detect: return "magnifyingglass"
        }
    }
    
    private var operationButtonText: String {
        if isOperating { return "操作中..." }
        return "执行 \(selectedOperation.rawValue)"
    }
    
    private var isOperationValid: Bool {
        switch selectedOperation {
        case .writeUID, .writeBlock0:
            return !newUID.isEmpty && MagicCardController.validateUID(newUID)
        case .fuse, .restore, .detect:
            return mifareController.currentCard != nil
        }
    }
    
    private func executeOperation() {
        isOperating = true
        resultMessage = nil
        
        Task {
            do {
                var success = false
                var message = ""
                
                switch selectedOperation {
                case .writeUID:
                    let uid = MagicCardController.parseUID(newUID)
                    success = try await magicController.writeUID(newUID: uid)
                    message = success ? "UID 写入成功!" : "UID 写入失败"
                    
                case .writeBlock0:
                    let uid = MagicCardController.parseUID(newUID)
                    success = try await magicController.writeBlock0(uid: uid)
                    message = success ? "Block 0 写入成功!" : "Block 0 写入失败"
                    
                case .fuse:
                    success = try await magicController.fuseCard()
                    message = success ? "卡片融合成功" : "卡片融合失败"
                    
                case .restore:
                    success = try await magicController.restoreDefaults()
                    message = success ? "卡片已恢复出厂设置" : "恢复失败"
                    
                case .detect:
                    if let card = mifareController.currentCard {
                        let type = magicController.detectMagicCard(uid: card.uid)
                        message = "检测结果: \(type.rawValue)"
                        success = true
                    } else {
                        message = "未检测到卡片"
                    }
                }
                
                await MainActor.run {
                    resultMessage = message
                    showResult = true
                    isOperating = false
                }
            } catch {
                await MainActor.run {
                    resultMessage = "错误: \(error.localizedDescription)"
                    showResult = true
                    isOperating = false
                }
            }
        }
    }
    
    private func generateRandomUID() -> String {
        var uid = [UInt8](repeating: 0, count: 4)
        for i in 0..<4 {
            uid[i] = UInt8.random(in: 0x01...0xFE)
        }
        // Avoid magic card prefixes (0x08, 0x09, 0x88)
        uid[0] = UInt8.random(in: 0x10...0xFE)
        return uid.map { String(format: "%02X", $0) }.joined()
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @ObservedObject var bleManager: BLEManager
    @ObservedObject var mifareController: MIFAREController
    @State private var showFirmwareInfo = false
    @State private var firmwareVersion = ""
    @State private var showDumpFiles = false
    @State private var showImportPicker = false
    
    var body: some View {
        NavigationView {
            List {
                // Section: Device
                Section("设备信息") {
                    HStack {
                        Text("连接状态")
                        Spacer()
                        Text(bleManager.isConnected ? "已连接" : "未连接")
                            .foregroundColor(bleManager.isConnected ? .green : .red)
                    }
                    
                    if bleManager.isConnected {
                        HStack {
                            Text("设备名称")
                            Spacer()
                            Text(bleManager.connectedDeviceName)
                                .foregroundColor(.secondary)
                        }
                        
                        Button(action: { getFirmware() }) {
                            HStack {
                                Text("固件版本")
                                Spacer()
                                if showFirmwareInfo {
                                    Text(firmwareVersion)
                                        .foregroundColor(.secondary)
                                } else {
                                    Text("获取")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                        
                        Button(action: { bleManager.disconnect() }) {
                            Text("断开连接")
                                .foregroundColor(.red)
                        }
                    }
                }
                
                // Section: Dump Management
                Section("Dump 管理") {
                    Button(action: { showDumpFiles = true }) {
                        HStack {
                            Image(systemName: "tray.full")
                            Text("查看已保存的 Dump")
                        }
                    }
                    
                    Text("已保存 \(mifareController.dumpHistory.count) 个 Dump")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                // Section: About
                Section("关于") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("平台")
                        Spacer()
                        Text("iOS 16.0+")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("作者")
                        Spacer()
                        Text("Hermes Agent")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
            .sheet(isPresented: $showDumpFiles) {
                DumpListView(mifareController: mifareController)
            }
        }
    }
    
    private func getFirmware() {
        Task {
            let frame = PN532CommandBuilder.getFirmwareVersion()
            do {
                let response = try await bleManager.sendFrame(frame)
                let fw = PN532ResponseParser.parseFirmware(response.data)
                await MainActor.run {
                    firmwareVersion = "IC:\(String(format: "%02X", fw.ic)) Ver:\(fw.ver).\(fw.rev)"
                    showFirmwareInfo = true
                }
            } catch {
                await MainActor.run {
                    firmwareVersion = "获取失败"
                    showFirmwareInfo = true
                }
            }
        }
    }
}

// MARK: - Dump List View
struct DumpListView: View {
    @ObservedObject var mifareController: MIFAREController
    @Environment(\.dismiss) var dismiss
    @State private var selectedDump: MIFAREDump?
    @State private var showDetail = false
    
    var body: some View {
        NavigationView {
            List {
                if mifareController.dumpHistory.isEmpty {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "tray")
                                .font(.system(size: 40))
                                .foregroundColor(.gray)
                            Text("暂无保存的 Dump\n读取完整卡片后，在卡片信息页面保存")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }
                }
                
                ForEach(Array(mifareController.dumpHistory.enumerated()), id: \.element.id) { index, dump in
                    Button(action: {
                        selectedDump = dump
                        showDetail = true
                    }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(dump.name)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Text("UID: \(dump.uidString)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("\(dump.formattedDate) · \(dump.sectorCount) 个扇区")
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        if index < mifareController.dumpHistory.count {
                            mifareController.dumpHistory.remove(at: index)
                        }
                    }
                    mifareController.saveDumpsToDisk()
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("已保存的 Dump")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                }
            }
            .sheet(isPresented: $showDetail) {
                if let dump = selectedDump {
                    DumpDetailView(dump: dump)
                }
            }
        }
    }
}

// MARK: - Dump Detail View
struct DumpDetailView: View {
    let dump: MIFAREDump
    @Environment(\.dismiss) var dismiss
    @State private var selectedSector: Int = 0
    @State private var showingShareSheet = false
    @State private var binaryData: Data?
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(dump.name)
                            .font(.title2)
                            .fontWeight(.bold)
                        Spacer()
                        Text(dump.formattedDate)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        DetailRow(label: "UID", value: dump.uidString)
                        Spacer()
                        DetailRow(label: "扇区", value: "\(dump.sectorCount)")
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                
                // Sector selector
                Picker("扇区", selection: $selectedSector) {
                    ForEach(dump.sectors.keys.sorted(), id: \.self) { sector in
                        Text("S\(sector)").tag(sector)
                    }
                }
                .pickerStyle(.segmented)
                .padding()
                
                // Sector data display
                if let sectorData = dump.sectors[selectedSector] {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            let blockCount = selectedSector < 32 ? 4 : 16
                            ForEach(0..<blockCount, id: \.self) { i in
                                let start = i * 16
                                let end = min(start + 16, sectorData.count)
                                if start < sectorData.count {
                                    let blockData = Array(sectorData[start..<end])
                                    let isTrailer = (i + 1) % 4 == 0 || selectedSector >= 32
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text("Block \(start / 16 * 4 + (selectedSector * 4) + i)")
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(isTrailer ? .orange : .gray)
                                            if isTrailer {
                                                Text("(尾块)")
                                                    .font(.system(size: 8))
                                                    .foregroundColor(.orange)
                                            }
                                            Spacer()
                                        }
                                        
                                        Text(HexUtils.formatHexDump(blockData, startOffset: 0, bytesPerLine: 16))
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundColor(isTrailer ? .orange : .primary)
                                    }
                                    .padding(8)
                                    .background(isTrailer ? Color.orange.opacity(0.05) : Color.clear)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                
                // Export button
                Button(action: { exportDump() }) {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                        Text("导出 .mfd 文件")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .padding()
            }
            .navigationTitle("Dump 详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
    
    private func exportDump() {
        binaryData = dump.toBinary()
        showingShareSheet = true
    }
}