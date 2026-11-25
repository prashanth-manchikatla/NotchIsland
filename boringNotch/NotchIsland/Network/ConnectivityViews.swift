//
//  ConnectivityViews.swift
//  NotchIsland
//
//  Header button (replaces the battery glyph) showing how the Mac is online —
//  Wi-Fi with signal bars, Personal Hotspot, Ethernet or offline — and a
//  popover with every connection: Wi-Fi details, hotspot, Ethernet, VPN and
//  connected Bluetooth devices (with their batteries).
//

import AppKit
import SwiftUI

struct ConnectivityHeaderButton: View {
    @ObservedObject private var monitor = ConnectivityMonitor.shared
    @ObservedObject private var batteries = BluetoothBatteryMonitor.shared
    @EnvironmentObject var vm: BoringViewModel
    @State private var showDetails = false
    @State private var hoveringPopover = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        HeaderCircleButton(title: showDetails ? nil : monitor.shortStatus, help: "Connections — Wi-Fi, hotspot, Ethernet, Bluetooth",
                           tap: { withAnimation(.smooth) { showDetails.toggle() } }) {
            ConnectivityGlyph(primary: monitor.primary, signal: monitor.wifi.signal, internet: monitor.internet,
                              bluetoothConnected: !monitor.bluetoothDevices.isEmpty)
        }
        .popover(isPresented: $showDetails, arrowEdge: .bottom) {
            ConnectivityDetails()
                .onHover { hovering in
                    hoveringPopover = hovering
                    if hovering {
                        hideTask?.cancel()
                        hideTask = nil
                    } else {
                        scheduleHide()
                    }
                }
        }
        .onChange(of: showDetails) {
            vm.isBatteryPopoverActive = showDetails // keeps the island open while it shows
            if showDetails { monitor.popoverOpened() } else { monitor.popoverClosed() }
        }
        .onChange(of: batteries.devices) { monitor.refreshBluetooth() }
        .onAppear { monitor.headerAppeared() }
        .onDisappear {
            hideTask?.cancel()
            if showDetails {
                showDetails = false
                vm.isBatteryPopoverActive = false // never leave a stale "keep open" flag behind
            }
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, !hoveringPopover else { return }
            await MainActor.run { withAnimation(.smooth) { showDetails = false } }
        }
    }
}

/// The header icon: Wi-Fi bars, hotspot, Ethernet or offline, plus a small blue dot
/// when Bluetooth devices are connected.
struct ConnectivityGlyph: View {
    let primary: ConnectivityMonitor.Primary
    let signal: Double
    let internet: Bool
    let bluetoothConnected: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            icon
                .imageScale(.medium)
                .contentTransition(.symbolEffect(.replace))
            if bluetoothConnected {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 5, height: 5)
                    .offset(x: 3, y: -1)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch primary {
        case .wifi:
            if internet {
                Image(systemName: "wifi", variableValue: signal).foregroundStyle(.white)
            } else {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
            }
        case .hotspot:
            Image(systemName: "personalhotspot").foregroundStyle(internet ? Color.green : Color.orange)
        case .ethernet:
            Image(systemName: "cable.connector.horizontal").foregroundStyle(internet ? Color.white : Color.orange)
        case .iPhoneUSB:
            Image(systemName: "iphone.gen3.radiowaves.left.and.right").foregroundStyle(internet ? Color.green : Color.orange)
        case .other:
            Image(systemName: "network").foregroundStyle(.white)
        case .offline:
            Image(systemName: "wifi.slash").foregroundStyle(.gray)
        }
    }
}

/// The Bluetooth rune, drawn (SF Symbols has no Bluetooth glyph).
struct BluetoothRune: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y) }
        var path = Path()
        path.move(to: p(0.18, 0.28))
        path.addLine(to: p(0.82, 0.72))
        path.addLine(to: p(0.5, 0.96))
        path.addLine(to: p(0.5, 0.04))
        path.addLine(to: p(0.82, 0.28))
        path.addLine(to: p(0.18, 0.72))
        return path
    }
}

/// Popover with every connection.
struct ConnectivityDetails: View {
    @ObservedObject private var monitor = ConnectivityMonitor.shared
    @ObservedObject private var batteries = BluetoothBatteryMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            wifiSection
            if !monitor.wiredInterfaces.isEmpty || !monitor.vpnInterfaces.isEmpty {
                Divider().opacity(0.5)
                ForEach(monitor.wiredInterfaces) { iface in wiredRow(iface) }
                ForEach(monitor.vpnInterfaces) { iface in
                    row(symbol: "network.badge.shield.half.filled", tint: .purple, title: "VPN",
                        detail: "\(iface.bsdName) · \(iface.ipv4)")
                }
            }
            Divider().opacity(0.5)
            bluetoothSection
            Divider().opacity(0.5)
            HStack(spacing: 8) {
                settingsButton("Network Settings…", url: "x-apple.systempreferences:com.apple.Network-Settings.extension")
                settingsButton("Bluetooth Settings…", url: "x-apple.systempreferences:com.apple.BluetoothSettings")
            }
        }
        .padding(14)
        .frame(width: 310)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            ConnectivityGlyph(primary: monitor.primary, signal: monitor.wifi.signal, internet: monitor.internet, bluetoothConnected: false)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.primary.opacity(0.08)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                HStack(spacing: 4) {
                    Circle().fill(monitor.internet ? Color.green : Color.orange).frame(width: 6, height: 6)
                    Text(monitor.internet ? "Internet connected" : "No internet connection")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if monitor.isConstrained {
                        Text("· Low Data Mode").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var title: String {
        switch monitor.primary {
        case .wifi: return "Wi-Fi"
        case .hotspot: return "Personal Hotspot"
        case .ethernet: return "Ethernet"
        case .iPhoneUSB: return "iPhone USB"
        case .other: return "Connected"
        case .offline: return "Offline"
        }
    }

    // MARK: Wi-Fi

    @ViewBuilder
    private var wifiSection: some View {
        let wifi = monitor.wifi
        if !wifi.poweredOn {
            row(symbol: "wifi.slash", tint: .gray, title: "Wi-Fi", detail: "Off")
        } else if !wifi.associated {
            row(symbol: "wifi", tint: .gray, title: "Wi-Fi", detail: "On · not connected")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: monitor.isHotspot ? "personalhotspot" : "wifi", variableValue: monitor.isHotspot ? nil : wifi.signal)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(monitor.isHotspot ? Color.green : Color.blue)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        if let ssid = wifi.ssid {
                            Text(ssid).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        } else {
                            HStack(spacing: 6) {
                                Text("Wi-Fi network").font(.system(size: 12.5, weight: .semibold))
                                Button(monitor.locationDenied ? "Show name…" : "Show name") {
                                    if monitor.locationDenied { WeatherManager.shared.openLocationSettings() } else { WeatherManager.shared.refresh() }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { monitor.refreshNetwork() }
                                }
                                .buttonStyle(.link)
                                .font(.system(size: 11))
                                .help("macOS shows the Wi-Fi name only to apps allowed to use Location")
                            }
                        }
                        Text(wifiDetail(wifi)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                if monitor.isHotspot {
                    Text("Personal Hotspot from your iPhone").font(.system(size: 11)).foregroundStyle(.green).padding(.leading, 30)
                }
                let extra = [monitor.wifiIP.map { "IP \($0)" }, wifi.txRate.map { "\(Int($0)) Mbps" }, wifi.security]
                    .compactMap { $0 }.joined(separator: " · ")
                if !extra.isEmpty {
                    Text(extra)
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).padding(.leading, 30)
                }
            }
        }
    }

    private func wifiDetail(_ wifi: WiFiInfo) -> String {
        var parts: [String] = []
        if let rssi = wifi.rssi { parts.append("\(wifi.quality) · \(rssi) dBm") }
        if let band = wifi.band { parts.append(wifi.channel.map { "\(band) (ch \($0))" } ?? band) }
        return parts.joined(separator: " · ")
    }

    // MARK: Wired / VPN

    private func wiredRow(_ iface: NetworkInterfaceInfo) -> some View {
        let symbol: String
        let tint: Color
        switch iface.kind {
        case .iPhoneUSB: symbol = "iphone.gen3.radiowaves.left.and.right"; tint = .green
        case .bluetoothPAN: symbol = "personalhotspot"; tint = .blue
        default: symbol = "cable.connector.horizontal"; tint = .blue
        }
        var detail = [iface.ipv4]
        if let speed = ConnectivityMonitor.speedText(iface.linkSpeed) { detail.insert(speed, at: 0) }
        return row(symbol: symbol, tint: tint, title: iface.displayName, detail: detail.joined(separator: " · "))
    }

    // MARK: Bluetooth

    private var bluetoothSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                BluetoothRune()
                    .stroke(monitor.bluetoothOn ? Color.blue : Color.gray, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .frame(width: 9, height: 15)
                    .frame(width: 22)
                Text("Bluetooth").font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text(monitor.bluetoothOn ? (monitor.bluetoothDevices.isEmpty ? "On" : "\(monitor.bluetoothDevices.count) connected") : "Off")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(monitor.bluetoothDevices) { device in
                HStack(spacing: 8) {
                    Image(systemName: device.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 22)
                    Text(device.shortName).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                        .help(device.name)
                    Spacer(minLength: 6)
                    if let battery = batteries.devices.first(where: { $0.name == device.name }) {
                        BatterySummary(device: battery)
                            .fixedSize()
                            .layoutPriority(1)
                    }
                }
            }
        }
    }

    // MARK: Building blocks

    private func row(symbol: String, tint: Color, title: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(detail).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func settingsButton(_ title: String, url: String) -> some View {
        Button(title) {
            if let url = URL(string: url) { NSWorkspace.shared.open(url) }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

/// "L 76% · R 70% · Case 85%" (or "64%") with the usual colours and charging bolts.
struct BatterySummary: View {
    let device: BluetoothBattery

    var body: some View {
        HStack(spacing: 6) {
            if device.isEarbuds {
                part("L", device.left, device.leftCharging)
                part("R", device.right, device.rightCharging)
                if device.caseLevel != nil { part(nil, device.caseLevel, device.caseCharging, symbol: device.budSymbols.caseSymbol) }
            } else if let main = device.main ?? device.caseLevel {
                part(nil, main, device.mainCharging)
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
    }

    @ViewBuilder
    private func part(_ label: String?, _ level: Int?, _ charging: Bool, symbol: String? = nil) -> some View {
        if let level {
            HStack(spacing: 2) {
                if let label { Text(label).foregroundStyle(.secondary) }
                if let symbol { Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(.secondary) }
                if charging { Image(systemName: "bolt.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(.green) }
                Text("\(level)%").foregroundStyle(level < 20 ? Color.red : (level < 30 ? Color.orange : Color.primary))
            }
        }
    }
}
