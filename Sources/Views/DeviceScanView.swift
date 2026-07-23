import SwiftUI
import CoreBluetooth

// MARK: - Device Scan View
struct DeviceScanView: View {
    @ObservedObject var bleManager: BLEManager
    @Binding var selectedDevice: BLEDevice?
    @State private var isScanning = false
    @State private var useAllDevices = true
    @State private var showFilteredOnly = true
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title2)
                    .foregroundColor(bleManager.isConnected ? .green : (isScanning ? .blue : .gray))
                Text("PCR532 Pro")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                if bleManager.isConnected {
                    Text(bleManager.connectedDeviceName)
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
            .padding()
            .background(Color(.systemBackground))
            
            Divider()
            
            // Connection status
            HStack {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 10, height: 10)
                Text(connectionStatusText)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                if bleManager.isConnected {
                    Button("鏂紑") {
                        bleManager.disconnect()
                    }
                    .foregroundColor(.red)
                    .font(.subheadline)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            // Scan controls
            HStack {
                Button(action: {
                    if isScanning {
                        bleManager.stopScan()
                        isScanning = false
                    } else {
                        isScanning = true
                        if useAllDevices {
                            bleManager.startScanAll()
                        } else {
                            bleManager.startScan()
                        }
                    }
                }) {
                    HStack {
                        Image(systemName: isScanning ? "stop.fill" : "magnifyingglass")
                        Text(isScanning ? "鍋滄鎵弿" : "鎵弿璁惧")
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(isScanning ? Color.red : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .disabled(bleManager.isConnected || bleManager.connectionState == .connecting)
                
                Toggle("鍏ㄩ儴", isOn: $useAllDevices)
                    .font(.caption)
                    .toggleStyle(.switch)
                    .scaleEffect(0.8)
                    .disabled(isScanning)
                
                Spacer()
                
                if isScanning {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            
            // Device list
            if bleManager.discoveredDevices.isEmpty && !isScanning {
                VStack(spacing: 20) {
                    Spacer()
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 50))
                        .foregroundColor(.gray)
                    Text("鐐瑰嚮銆屾壂鎻忚澶囥€嶆煡鎵綷nPCR532 Pro 钃濈墮璇诲啓鍣?)
                        .font(.body)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(filteredDevices) { device in
                        DeviceRow(device: device)
                            .onTapGesture {
                                if !bleManager.isConnected {
                                    bleManager.stopScan()
                                    isScanning = false
                                    selectedDevice = device
                                    bleManager.connect(to: device)
                                }
                            }
                            .disabled(bleManager.isConnected || bleManager.connectionState == .connecting)
                    }
                }
                .listStyle(.plain)
            }
        }
    }
    
    private var filteredDevices: [BLEDevice] {
        if showFilteredOnly && !useAllDevices {
            return bleManager.discoveredDevices
        }
        return bleManager.discoveredDevices
    }
    
    private var connectionColor: Color {
        if bleManager.isConnected { return .green }
        if bleManager.connectionState == .connecting || bleManager.connectionState == .discovering { return .orange }
        return .red
    }
    
    private var connectionStatusText: String {
        if bleManager.isConnected { return "宸茶繛鎺? \(bleManager.connectedDeviceName)" }
        if bleManager.connectionState == .connecting { return "杩炴帴涓?.." }
        if bleManager.connectionState == .discovering { return "鍙戠幇鏈嶅姟..." }
        return "鏈繛鎺?
    }
}

// MARK: - Device Row
struct DeviceRow: View {
    let device: BLEDevice
    
    var body: some View {
        HStack {
            // Signal indicator
            VStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundColor(signalColor)
                Text("\(device.rssi) dBm")
                    .font(.system(size: 8))
                    .foregroundColor(.gray)
            }
            .frame(width: 40)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("ID: \(device.id.uuidString.prefix(8))...")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
            
            Spacer()
            
            // Signal bars
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(i < device.signalBars ? signalColor : Color.gray.opacity(0.3))
                        .frame(width: 3, height: CGFloat(4 + i * 4))
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    private var signalColor: Color {
        if device.rssi >= -60 { return .green }
        if device.rssi >= -75 { return .yellow }
        if device.rssi >= -90 { return .orange }
        return .red
    }
}

// MARK: - Device Scan Wrapper
struct DeviceScanWrapper: View {
    @ObservedObject var bleManager: BLEManager
    @Binding var selectedDevice: BLEDevice?
    @Binding var showScanner: Bool
    
    var body: some View {
        NavigationView {
            DeviceScanView(bleManager: bleManager, selectedDevice: $selectedDevice)
                .navigationTitle("杩炴帴璁惧")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        if bleManager.isConnected {
                            Button("瀹屾垚") {
                                showScanner = false
                            }
                        }
                    }
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("鍙栨秷") {
                            bleManager.stopScan()
                            showScanner = false
                        }
                    }
                }
        }
    }
}

// MARK: - Connection Status Badge
struct ConnectionBadge: View {
    let isConnected: Bool
    let deviceName: String
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(isConnected ? deviceName : "鏈繛鎺?)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }
}
