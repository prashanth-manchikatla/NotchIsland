//
//  ConnectivityViews.swift
//  Hoverbird
//
//  Header button (replaces the battery glyph) showing how the Mac is online —
//  Wi-Fi with signal bars, Personal Hotspot, Ethernet or offline. Clicking it
//  opens the Connectivity section inside the island, like Calendar (never a
//  separate popover window): the connection, Wi-Fi details, Ethernet and VPN
//  on the left, connected Bluetooth devices with their batteries on the right.
//

import AppKit
import SwiftUI

struct ConnectivityHeaderButton: View {
    @ObservedObject private var monitor = ConnectivityMonitor.shared
    @ObservedObject private var batteries = BluetoothBatteryMonitor.shared
    @ObservedObject private var coordinator = BoringViewCoordinator.shared

    var body: some View {
        let active = coordinator.currentView == .connectivity
        HeaderCircleButton(title: monitor.shortStatus, help: "Connections — Wi-Fi, hotspot, Ethernet, Bluetooth",
                           tap: toggle, selected: active) {
            ConnectivityGlyph(primary: monitor.primary, signal: monitor.wifi.signal, internet: monitor.internet,
                              bluetoothConnected: !monitor.bluetoothDevices.isEmpty)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Connections")
        .accessibilityValue(monitor.shortStatus)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityAction { toggle() }
        .accessibilityIdentifier("header.connectivity")
        .onChange(of: batteries.devices) { monitor.refreshBluetooth() }
        .onAppear { monitor.headerAppeared() }
    }

    /// Shows the Connectivity section in the island, or goes back Home.
    private func toggle() {
        withAnimation(.smooth) {
            coordinator.currentView = coordinator.currentView == .connectivity ? .home : .connectivity
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

/// 📶 Connectivity section (opened from the header), shown inside the island.
struct IslandConnectivitySection: View {
    @ObservedObject private var monitor = ConnectivityMonitor.shared
    @ObservedObject private var batteries = BluetoothBatteryMonitor.shared

    /// Text starts here in both cards: after the 30 pt icon column and its spacing.
    private static let textInset: CGFloat = 39

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            networkCard
            bluetoothCard
        }
        .frame(height: 134)
        .padding(.top, 2)
        .buttonStyle(.plain)
        .onAppear { monitor.detailsShown() }
        .onDisappear { monitor.detailsHidden() }
    }

    // MARK: Network

    private var networkCard: some View {
        ConnectivityCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    ConnectivityGlyph(primary: monitor.primary, signal: monitor.wifi.signal, internet: monitor.internet,
                                      bluetoothConnected: false)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                    VStack(alignment: .leading, spacing: 2) {
                        networkTitle
                        HStack(spacing: 5) {
                            Circle().fill(monitor.internet ? Color.green : Color.orange).frame(width: 6, height: 6)
                            ViewThatFits(in: .horizontal) {
                                detailText(networkStatus(.full))
                                detailText(networkStatus(.withoutType))
                                detailText(networkStatus(.compact))
                            }
                        }
                    }
                    Spacer(minLength: 4)
                    SettingsPaneButton(help: "Open Network Settings",
                                       url: "x-apple.systempreferences:com.apple.Network-Settings.extension")
                }
                ScrollingIfNeeded {
                    VStack(alignment: .leading, spacing: 6) {
                        wifiDetails
                        ForEach(monitor.wiredInterfaces) { iface in wiredRow(iface) }
                        ForEach(monitor.vpnInterfaces) { iface in
                            detailRow(symbol: "network.badge.shield.half.filled", tint: .purple, title: "VPN",
                                      detail: "\(iface.bsdName) · \(iface.ipv4)")
                        }
                    }
                }
            }
        }
    }

    /// On Wi-Fi or a hotspot the network's name is the title.
    private var onWiFi: Bool { monitor.primary == .wifi || monitor.primary == .hotspot }

    @ViewBuilder
    private var networkTitle: some View {
        if onWiFi, monitor.wifi.associated, monitor.wifi.ssid == nil {
            HStack(spacing: 6) {
                titleText(monitor.isHotspot ? "Personal Hotspot" : "Wi-Fi network")
                Button(monitor.locationDenied ? "Show name…" : "Show name") { showNetworkName() }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.blue)
                    .fixedSize()
                    .help("macOS shows the Wi-Fi name only to apps allowed to use Location")
            }
        } else {
            titleText(onWiFi ? (monitor.wifi.ssid ?? connectionName) : connectionName)
        }
    }

    private var connectionName: String {
        switch monitor.primary {
        case .wifi: return "Wi-Fi"
        case .hotspot: return "Personal Hotspot"
        case .ethernet: return "Ethernet"
        case .iPhoneUSB: return "iPhone USB"
        case .other: return "Connected"
        case .offline: return "Offline"
        }
    }

    private enum StatusLength { case full, withoutType, compact }

    /// "Wi-Fi · Internet connected · Low Data Mode" (the type leads when the title is the
    /// network's name); shorter forms for narrow layouts: "Internet connected · …", "Online · …".
    private func networkStatus(_ length: StatusLength) -> String {
        var parts: [String] = []
        if length == .full, onWiFi, monitor.wifi.ssid != nil { parts.append(monitor.primary == .hotspot ? "Hotspot" : "Wi-Fi") }
        parts.append(monitor.internet ? (length == .compact ? "Online" : "Internet connected") : "No internet")
        if monitor.isConstrained { parts.append("Low Data Mode") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var wifiDetails: some View {
        let wifi = monitor.wifi
        if !wifi.poweredOn {
            detailRow(symbol: "wifi.slash", tint: .gray, title: "Wi-Fi", detail: "Off")
        } else if !wifi.associated {
            detailRow(symbol: "wifi", tint: .gray, title: "Wi-Fi", detail: "On · not connected")
        } else if onWiFi {
            // The title already names the network: its signal and address under it.
            let signal = signalLine(wifi), address = addressLine(wifi)
            if !signal.isEmpty || !address.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if !signal.isEmpty { fittingDetail(signal, signalLine(wifi, full: false)) }
                    if !address.isEmpty { fittingDetail(address, addressLine(wifi, full: false)) }
                }
                .padding(.leading, Self.textInset)
            }
        } else {
            // On Ethernet or iPhone USB, with Wi-Fi joined as well.
            detailRow(symbol: "wifi", tint: .blue, title: wifi.ssid ?? "Wi-Fi", detail: signalLine(wifi), signal: wifi.signal)
        }
    }

    /// "Excellent · -52 dBm · 5 GHz (ch 149)"; the short form leaves out the channel.
    private func signalLine(_ wifi: WiFiInfo, full: Bool = true) -> String {
        var parts: [String] = []
        if let rssi = wifi.rssi { parts.append("\(wifi.quality) · \(rssi) dBm") }
        if let band = wifi.band { parts.append(full ? (wifi.channel.map { "\(band) (ch \($0))" } ?? band) : band) }
        return parts.joined(separator: " · ")
    }

    /// "IP 192.168.1.23 · 866 Mbps · WPA3"; the short form leaves out the security type.
    private func addressLine(_ wifi: WiFiInfo, full: Bool = true) -> String {
        [monitor.wifiIP.map { "IP \($0)" }, wifi.txRate.map { "\(Int($0)) Mbps" }, full ? wifi.security : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

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
        return detailRow(symbol: symbol, tint: tint, title: iface.displayName, detail: detail.joined(separator: " · "))
    }

    private func showNetworkName() {
        if monitor.locationDenied { WeatherManager.shared.openLocationSettings() } else { WeatherManager.shared.refresh() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { ConnectivityMonitor.shared.refreshNetwork() }
    }

    // MARK: Bluetooth

    private var bluetoothCard: some View {
        ConnectivityCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    BluetoothRune()
                        .stroke(monitor.bluetoothOn ? Color.blue : Color.gray,
                                style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                        .frame(width: 9, height: 15)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                    VStack(alignment: .leading, spacing: 2) {
                        titleText("Bluetooth")
                        Text(bluetoothStatus).font(.system(size: 11)).foregroundStyle(.gray).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    SettingsPaneButton(help: "Open Bluetooth Settings", url: "x-apple.systempreferences:com.apple.BluetoothSettings")
                }
                if monitor.bluetoothOn, !monitor.bluetoothDevices.isEmpty {
                    ScrollingIfNeeded {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(monitor.bluetoothDevices) { device in deviceRow(device) }
                        }
                    }
                } else if monitor.bluetoothOn {
                    Text("No devices connected")
                        .font(.system(size: 11)).foregroundStyle(.gray)
                        .padding(.leading, Self.textInset)
                }
            }
        }
    }

    private var bluetoothStatus: String {
        guard monitor.bluetoothOn else { return "Off" }
        let count = monitor.bluetoothDevices.count
        return count == 0 ? "On" : "\(count) connected"
    }

    /// Name and battery. When space is short (the camera mirror beside the section), the
    /// earbuds' case level goes first, so the name stays readable.
    private func deviceRow(_ device: ConnectedBluetoothDevice) -> some View {
        let battery = batteries.devices.first { $0.name == device.name }
        return ViewThatFits(in: .horizontal) {
            deviceRow(device, battery: battery, showsCase: true)
            deviceRow(device, battery: battery, showsCase: false)
        }
    }

    private func deviceRow(_ device: ConnectedBluetoothDevice, battery: BluetoothBattery?, showsCase: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: device.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 30)
            Text(device.shortName)
                .font(.system(size: 12)).foregroundStyle(.white)
                .lineLimit(1).truncationMode(.tail)
                .help(device.name)
            Spacer(minLength: 6)
            if let battery {
                BatterySummary(device: battery, showsCase: showsCase)
                    .fixedSize()
                    .layoutPriority(1)
            }
        }
    }

    // MARK: Building blocks

    private func titleText(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
    }

    private func detailText(_ text: String) -> some View {
        Text(text).font(.system(size: 11).monospacedDigit()).foregroundStyle(.gray).lineLimit(1)
    }

    /// The full text when it fits, else the shorter one (truncated if even that is too long).
    private func fittingDetail(_ full: String, _ short: String) -> some View {
        ViewThatFits(in: .horizontal) {
            detailText(full)
            detailText(short)
        }
    }

    /// One line: icon, name, details ("Ethernet  1 Gbps · 10.0.0.5").
    private func detailRow(symbol: String, tint: Color, title: String, detail: String, signal: Double? = nil) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol, variableValue: signal)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30)
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    .layoutPriority(1)
                if !detail.isEmpty { detailText(detail) }
            }
            Spacer(minLength: 0)
        }
    }
}

/// The island's dark glass card.
private struct ConnectivityCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.07)))
    }
}

/// The content as it is when it fits, otherwise in a quiet scroll view, so a card never clips.
private struct ScrollingIfNeeded<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content()
            ScrollView(.vertical, showsIndicators: false) { content() }
        }
    }
}

/// A small round button that opens a System Settings pane.
private struct SettingsPaneButton: View {
    let help: String
    let url: String
    @State private var hovering = false

    var body: some View {
        Button {
            if let url = URL(string: url) { NSWorkspace.shared.open(url) }
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.2 : 0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// "L 76% · R 70% · Case 85%" (or "64%") with the usual colours and charging bolts.
struct BatterySummary: View {
    let device: BluetoothBattery
    /// The earbuds' case level (left out when space is short).
    var showsCase = true

    var body: some View {
        HStack(spacing: 6) {
            if device.isEarbuds {
                part("L", device.left, device.leftCharging)
                part("R", device.right, device.rightCharging)
                if showsCase, device.caseLevel != nil { part(nil, device.caseLevel, device.caseCharging, symbol: device.budSymbols.caseSymbol) }
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
