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
                
                VStack(alignment: .leading, spacing: 12) {
                    DetailRow(label: "UID", value: card.uidString)
                    DetailRow(label: "SAK", value: String(format: "0x%02X", card.sak))
                    DetailRow(label: "ATQA", value: String(format: "0x%02X%02X", card.atqa.0, card.atqa.1))
                    DetailRow(label: "Sectors", value: "\(card.totalSectors)")
                    DetailRow(label: "Blocks", value: "\(card.totalBlocks)")
                    if card.isMagicCard {
                        HStack {
                            Image(systemName: "wand.and.stars").foregroundColor(.yellow)
                            Text("Magic card").foregroundColor(.yellow).fontWeight(.bold)
                        }
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
                .padding(.horizontal)
                
                HStack(spacing: 12) {
                    Button(action: { detectCard() }) {
                        Label(isDetecting ? "Detecting..." : "Detect", systemImage: "waveform.path.ecg")
                            .frame(maxWidth: .infinity).padding()
                            .background(Color.blue).foregroundColor(.white).cornerRadius(10)
                    }
                    .disabled(isDetecting || !bleManager.isConnected)
                    
                    Button(action: { readFullCard() }) {
                        Label("Dump", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity).padding()
                            .background(Color.green).foregroundColor(.white).cornerRadius(10)
                    }
                    .disabled(!bleManager.isConnected)
                    
                    Button(action: { showDumpAlert = true }) {
                        Label("Save", systemImage: "tray.and.arrow.down")
                            .frame(maxWidth: .infinity).padding()
                            .background(Color.orange).foregroundColor(.white).cornerRadius(10)
                    }
                    .disabled(cardInfo == nil)
                }
                .padding(.horizontal)
            } else {
                Spacer()
                Image(systemName: "creditcard").font(.system(size: 50)).foregroundColor(.gray)
                Text("No card detected").foregroundColor(.gray)
                Button(action: { detectCard() }) {
                    HStack {
                        if isDetecting { ProgressView().tint(.white) }
                        Text(isDetecting ? "Detecting..." : "Detect Card")
                    }
                    .frame(maxWidth: .infinity).padding()
                    .background(bleManager.isConnected ? Color.blue : Color.gray)
                    .foregroundColor(.white).cornerRadius(10)
                }
                .disabled(isDetecting || !bleManager.isConnected)
                .padding(.horizontal, 40)
                Spacer()
            }
            
            if let err = errorMessage {
                Text(err).font(.caption).foregroundColor(.red).multilineTextAlignment(.center).padding(.horizontal)
            }
            if !bleManager.lastDebugLog.isEmpty {
                Text(bleManager.lastDebugLog)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary).lineLimit(4).padding(.horizontal)
            }
            if !mifareController.statusMessage.isEmpty {
                Text(mifareController.statusMessage).font(.caption).foregroundColor(.secondary)
            }
        }
        .alert("Save dump", isPresented: $showDumpAlert) {
            TextField("Name", text: $dumpName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if !dumpName.isEmpty {
                    _ = mifareController.saveCurrentDump(name: dumpName)
                    dumpName = ""
                }
            }
        } message: {
            Text("Name this dump")
        }
    }
    
    private func detectCard() {
        isDetecting = true
        errorMessage = nil
        Task {
            do {
                _ = try await mifareController.detectCard()
            } catch {
                await MainActor.run {
                    errorMessage = "\(error.localizedDescription) | \(bleManager.lastDebugLog)"
                }
            }
            await MainActor.run { isDetecting = false }
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
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).fontWeight(.medium).font(.system(.body, design: .monospaced))
        }
    }
}

// MARK: - Sector List View
struct SectorListView: View {
    @ObservedObject var mifareController: MIFAREController
    @Binding var selectedSector: MIFARESector?
    
    var body: some View {
        Group {
            if mifareController.sectors.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "square.grid.3x3").font(.system(size: 40)).foregroundColor(.gray)
                    Text("No sector data").foregroundColor(.gray)
                    Text("Detect card then dump").font(.caption).foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List {
                    ForEach(mifareController.sectors) { sector in
                        SectorCell(sector: sector)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedSector = sector }
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}

// MARK: - Sector Cell
struct SectorCell: View {
    let sector: MIFARESector
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sector \(sector.number)").font(.headline)
                Text(sector.isAuthenticated ? "Auth OK" : "Locked")
                    .font(.caption)
                    .foregroundColor(sector.isAuthenticated ? .green : .red)
            }
            Spacer()
            if let key = sector.knownKey {
                Text(key.map { String(format: "%02X", $0) }.joined())
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Image(systemName: "chevron.right").foregroundColor(.gray)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Sector Detail View
struct SectorDetailView: View {
    let sector: MIFARESector
    @ObservedObject var mifareController: MIFAREController
    @Environment(\.dismiss) var dismiss
    @State private var selectedBlock: MIFAREBlock?
    
    var body: some View {
        NavigationView {
            List {
                Section("Info") {
                    DetailRow(label: "Sector", value: "\(sector.number)")
                    DetailRow(label: "Blocks", value: "\(sector.blocks.count)")
                    DetailRow(label: "Auth", value: sector.isAuthenticated ? "Yes" : "No")
                }
                Section("Blocks") {
                    ForEach(sector.blocks) { block in
                        BlockRow(block: block)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedBlock = block }
                    }
                }
            }
            .navigationTitle("Sector \(sector.number)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(item: $selectedBlock) { block in
                HexEditorView(block: block, sector: sector, mifareController: mifareController)
            }
        }
    }
}

// MARK: - Block Row
struct BlockRow: View {
    let block: MIFAREBlock
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Block \(block.number)").font(.subheadline).fontWeight(.semibold)
                if block.isSectorTrailer {
                    Text("Trailer").font(.caption2).padding(3).background(Color.orange.opacity(0.2)).cornerRadius(4)
                }
            }
            Text(block.hexString)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
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
                Text("Sector \(sector.number) - Block \(block.number)")
                    .font(.headline)
                TextEditor(text: $hexText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 100)
                    .padding(8)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                if let err = errorMessage {
                    Text(err).font(.caption).foregroundColor(.red)
                }
                Button(action: writeBlock) {
                    if isWriting { ProgressView() } else { Text("Write block") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWriting)
                Spacer()
            }
            .padding()
            .navigationTitle("Hex Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
    
    private func writeBlock() {
        let cleaned = hexText.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
        guard cleaned.count == 32, let bytes = cleaned.hexToBytes(), bytes.count == 16 else {
            errorMessage = "Need 16 bytes hex"
            return
        }
        isWriting = true
        Task {
            do {
                let ok = try await mifareController.writeBlock(block: block.number, data: bytes)
                await MainActor.run {
                    if ok { dismiss() } else { errorMessage = "Write failed" }
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
}

// MARK: - Quick Action Button
struct QuickActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title2)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(10)
        }
    }
}