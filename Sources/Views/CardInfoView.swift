import SwiftUI

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
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
                .padding(.horizontal)
                
                HStack(spacing: 12) {
                    Button(action: { detectCard() }) {
                        Label("Detect", systemImage: "waveform.path.ecg")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .disabled(isDetecting || !bleManager.isConnected)
                    
                    Button(action: { readFullCard() }) {
                        Label("Dump", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .disabled(!bleManager.isConnected || cardInfo == nil)
                }
                .padding(.horizontal)
            } else {
                Spacer()
                Image(systemName: "creditcard")
                    .font(.system(size: 50))
                    .foregroundColor(.gray)
                Text("No card")
                    .foregroundColor(.gray)
                Button(action: { detectCard() }) {
                    HStack {
                        if isDetecting { ProgressView().tint(.white) }
                        Text(isDetecting ? "Detecting..." : "Detect Card")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(bleManager.isConnected ? Color.blue : Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .disabled(isDetecting || !bleManager.isConnected)
                .padding(.horizontal, 40)
                Spacer()
            }
            
            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            
            if !bleManager.lastDebugLog.isEmpty {
                Text(bleManager.lastDebugLog)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .padding(.horizontal)
            }
            
            if !mifareController.statusMessage.isEmpty {
                Text(mifareController.statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
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
                    errorMessage = "\(error.localizedDescription)\n\(bleManager.lastDebugLog)"
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
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
    }
}