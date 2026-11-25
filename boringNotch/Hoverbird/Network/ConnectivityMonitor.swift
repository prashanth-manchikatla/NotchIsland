//
//  ConnectivityMonitor.swift
//  Hoverbird
//
//  Everything the Mac is connected to, for the header's connectivity button:
//  Wi-Fi (network name, signal, band, speed), iPhone Personal Hotspot (Wi-Fi or
//  USB), Ethernet, VPN, and connected Bluetooth devices.
//
//  Event-driven: NWPathMonitor + CoreWLAN change events. Signal strength is
//  re-read only while the details popover is open.
//

import AppKit
import CoreLocation
import CoreWLAN
import IOBluetooth
import Network
import SwiftUI
import SystemConfiguration

struct WiFiInfo: Equatable {
    var poweredOn = false
    var associated = false
    var ssid: String?
    var rssi: Int?
    var noise: Int?
    var txRate: Double?
    var band: String?
    var channel: Int?
    var security: String?
    var interfaceName: String?

    /// 0…1 for the signal bars.
    var signal: Double {
        guard let rssi else { return associated ? 0.66 : 0 }
        switch rssi {
        case (-55)...: return 1
        case (-67)...: return 0.66
        case (-77)...: return 0.33
        default: return 0.1
        }
    }

    var quality: String {
        guard let rssi else { return "" }
        switch rssi {
        case (-55)...: return "Excellent"
        case (-67)...: return "Good"
        case (-77)...: return "Fair"
        default: return "Weak"
        }
    }
}

struct NetworkInterfaceInfo: Identifiable, Equatable {
    enum Kind: Equatable { case wifi, ethernet, iPhoneUSB, bluetoothPAN, vpn, other }
    var id: String { bsdName }
    let bsdName: String
    let displayName: String
    let kind: Kind
    let ipv4: String
    /// Bits per second (0 when unknown).
    let linkSpeed: UInt64
}

struct ConnectedBluetoothDevice: Identifiable, Equatable {
    var id: String { address }
    let address: String
    let name: String
    let symbol: String

    /// "Alex's AirPods Pro" → "AirPods Pro".
    var shortName: String {
        for marker in ["’s ", "'s "] {
            if let range = name.range(of: marker), range.upperBound < name.endIndex { return String(name[range.upperBound...]) }
        }
        return name
    }
}

@MainActor
final class ConnectivityMonitor: NSObject, ObservableObject, CWEventDelegate {
    static let shared = ConnectivityMonitor()

    enum Primary: Equatable { case wifi, hotspot, ethernet, iPhoneUSB, other, offline }

    @Published private(set) var primary: Primary = .offline
    @Published private(set) var internet = false
    @Published private(set) var isExpensive = false
    @Published private(set) var isConstrained = false
    @Published private(set) var wifi = WiFiInfo()
    @Published private(set) var interfaces: [NetworkInterfaceInfo] = []
    @Published private(set) var bluetoothOn = false
    @Published private(set) var bluetoothDevices: [ConnectedBluetoothDevice] = []

    private let pathMonitor = NWPathMonitor()
    private let locationManager = CLLocationManager()
    private var started = false
    private var detailTimer: Timer?

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        pathMonitor.pathUpdateHandler = { path in
            let status = path.status == .satisfied
            let expensive = path.isExpensive, constrained = path.isConstrained
            let wired = path.usesInterfaceType(.wiredEthernet), wireless = path.usesInterfaceType(.wifi)
            let cellular = path.usesInterfaceType(.cellular)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    ConnectivityMonitor.shared.pathChanged(satisfied: status, expensive: expensive, constrained: constrained,
                                                           wired: wired, wifi: wireless, cellular: cellular)
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "Hoverbird.Connectivity", qos: .utility))

        let client = CWWiFiClient.shared()
        client.delegate = self
        for event in [CWEventType.ssidDidChange, .linkDidChange, .powerDidChange] {
            try? client.startMonitoringEvent(with: event)
        }
        refreshNetwork()
    }

    /// The island opened (header visible): make the icon current.
    func headerAppeared() {
        start()
        refreshNetwork()
        refreshBluetooth()
    }

    func popoverOpened() {
        refreshNetwork()
        refreshBluetooth()
        detailTimer?.invalidate()
        let timer = Timer(timeInterval: 4, repeats: true) { _ in
            MainActor.assumeIsolated { ConnectivityMonitor.shared.refreshNetwork() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        detailTimer = timer
    }

    func popoverClosed() {
        detailTimer?.invalidate()
        detailTimer = nil
    }

    // MARK: Network

    private var lastPath: (satisfied: Bool, wired: Bool, wifi: Bool, cellular: Bool) = (false, false, false, false)

    private func pathChanged(satisfied: Bool, expensive: Bool, constrained: Bool, wired: Bool, wifi: Bool, cellular: Bool) {
        internet = satisfied
        isExpensive = expensive
        isConstrained = constrained
        lastPath = (satisfied, wired, wifi, cellular)
        refreshNetwork()
    }

    func refreshNetwork() {
        let wifiNow = Self.readWiFi()
        let interfacesNow = Self.readInterfaces()
        if wifiNow != wifi { wifi = wifiNow }
        if interfacesNow != interfaces { interfaces = interfacesNow }
        let newPrimary = computePrimary()
        if newPrimary != primary { withAnimation(.smooth) { primary = newPrimary } }
    }

    private func computePrimary() -> Primary {
        guard lastPath.satisfied || wifi.associated || interfaces.contains(where: { $0.kind != .vpn }) else { return .offline }
        if lastPath.wired || (!lastPath.wifi && interfaces.contains { $0.kind == .ethernet || $0.kind == .iPhoneUSB }) {
            return interfaces.contains { $0.kind == .iPhoneUSB } && !interfaces.contains { $0.kind == .ethernet } ? .iPhoneUSB : .ethernet
        }
        if lastPath.wifi || wifi.associated { return isHotspot ? .hotspot : .wifi }
        if lastPath.cellular { return .hotspot }
        return lastPath.satisfied ? .other : .offline
    }

    /// Connected to an iPhone / iPad Personal Hotspot over Wi-Fi.
    var isHotspot: Bool {
        guard wifi.associated else { return false }
        let wifiIP = interfaces.first { $0.kind == .wifi }?.ipv4 ?? ""
        return wifiIP.hasPrefix("172.20.10.") || (isExpensive && lastPath.wifi)
    }

    var wifiIP: String? { interfaces.first { $0.kind == .wifi }?.ipv4 }
    var wiredInterfaces: [NetworkInterfaceInfo] { interfaces.filter { $0.kind == .ethernet || $0.kind == .iPhoneUSB || $0.kind == .bluetoothPAN } }
    var vpnInterfaces: [NetworkInterfaceInfo] { interfaces.filter { $0.kind == .vpn } }

    /// Short text for the header's hover tag.
    var shortStatus: String {
        switch primary {
        case .wifi: return wifi.ssid ?? "Wi-Fi"
        case .hotspot: return "Hotspot" + (wifi.ssid.map { " · \($0)" } ?? "")
        case .ethernet: return "Ethernet"
        case .iPhoneUSB: return "iPhone USB"
        case .other: return "Connected"
        case .offline: return wifi.poweredOn ? "Not connected" : "Wi-Fi off"
        }
    }

    var locationAuthorized: Bool {
        let status = locationManager.authorizationStatus
        return status != .notDetermined && status != .denied && status != .restricted
    }

    var locationDenied: Bool {
        let status = locationManager.authorizationStatus
        return status == .denied || status == .restricted
    }

    private nonisolated static func readWiFi() -> WiFiInfo {
        guard let iface = CWWiFiClient.shared().interface() else { return WiFiInfo() }
        var info = WiFiInfo()
        info.interfaceName = iface.interfaceName
        info.poweredOn = iface.powerOn()
        guard info.poweredOn else { return info }
        let rssi = iface.rssiValue()
        let channel = iface.wlanChannel()
        info.associated = channel != nil || rssi != 0
        guard info.associated else { return info }
        info.ssid = iface.ssid() // needs Location permission (macOS 14+)
        info.rssi = rssi == 0 ? nil : rssi
        let noise = iface.noiseMeasurement()
        info.noise = noise == 0 ? nil : noise
        let rate = iface.transmitRate()
        info.txRate = rate > 0 ? rate : nil
        if let channel {
            info.channel = channel.channelNumber
            switch channel.channelBand {
            case .band2GHz: info.band = "2.4 GHz"
            case .band5GHz: info.band = "5 GHz"
            case .band6GHz: info.band = "6 GHz"
            default: info.band = nil
            }
        }
        info.security = securityName(iface.security())
        return info
    }

    private nonisolated static func securityName(_ security: CWSecurity) -> String? {
        switch security {
        case .none: return "Open"
        case .WEP, .dynamicWEP: return "WEP"
        case .wpaPersonal, .wpaPersonalMixed: return "WPA"
        case .wpa2Personal, .personal: return "WPA2"
        case .wpa3Personal: return "WPA3"
        case .wpa3Transition: return "WPA2/WPA3"
        case .wpaEnterprise, .wpaEnterpriseMixed, .wpa2Enterprise, .enterprise: return "Enterprise"
        case .wpa3Enterprise: return "WPA3 Enterprise"
        case .OWE, .oweTransition: return "Enhanced Open"
        default: return nil
        }
    }

    /// Interfaces that have an IPv4 address right now, with friendly names and link speeds.
    private nonisolated static func readInterfaces() -> [NetworkInterfaceInfo] {
        var friendly: [String: (name: String, type: String)] = [:]
        if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for iface in all {
                guard let bsd = SCNetworkInterfaceGetBSDName(iface) as String? else { continue }
                friendly[bsd] = (SCNetworkInterfaceGetLocalizedDisplayName(iface) as String? ?? bsd,
                                 SCNetworkInterfaceGetInterfaceType(iface) as String? ?? "")
            }
        }
        var addresses: [String: String] = [:]
        var speeds: [String: UInt64] = [:]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let address = entry.ifa_addr else { continue }
            let name = String(cString: entry.ifa_name)
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if !ip.hasPrefix("169.254.") { addresses[name] = ip }
                }
            case AF_LINK:
                if let data = entry.ifa_data?.assumingMemoryBound(to: if_data.self) {
                    speeds[name] = UInt64(data.pointee.ifi_baudrate)
                }
            default:
                break
            }
        }
        var result: [NetworkInterfaceInfo] = []
        for (bsd, ip) in addresses {
            let info = friendly[bsd]
            let display = info?.name ?? bsd
            let type = info?.type ?? ""
            let kind: NetworkInterfaceInfo.Kind
            if type == (kSCNetworkInterfaceTypeIEEE80211 as String) {
                kind = .wifi
            } else if display.localizedCaseInsensitiveContains("iphone") || display.localizedCaseInsensitiveContains("ipad") {
                kind = .iPhoneUSB
            } else if type == (kSCNetworkInterfaceTypeBluetooth as String) || display.localizedCaseInsensitiveContains("bluetooth pan") {
                kind = .bluetoothPAN
            } else if type == (kSCNetworkInterfaceTypeEthernet as String) {
                kind = .ethernet
            } else if bsd.hasPrefix("utun") || bsd.hasPrefix("ipsec") || bsd.hasPrefix("ppp") || bsd.hasPrefix("tun") {
                kind = .vpn
            } else if bsd.hasPrefix("bridge") || bsd.hasPrefix("ap") || bsd.hasPrefix("awdl") || bsd.hasPrefix("llw") {
                continue
            } else {
                kind = .other
            }
            let vpnName = kind == .vpn ? "VPN" : display
            result.append(NetworkInterfaceInfo(bsdName: bsd, displayName: vpnName, kind: kind, ipv4: ip, linkSpeed: speeds[bsd] ?? 0))
        }
        return result.sorted { $0.bsdName < $1.bsdName }
    }

    // MARK: Bluetooth

    func refreshBluetooth() {
        let on = IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON
        if on != bluetoothOn { bluetoothOn = on }
        var devices: [ConnectedBluetoothDevice] = []
        var batteries = BluetoothBatteryMonitor.shared.devices
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        for device in paired where device.isConnected() {
            var name = device.name ?? "Bluetooth device"
            // The battery data may use the full name ("Alex's AirPods Pro" vs "AirPods Pro"): one row.
            let lower = name.lowercased()
            if let index = batteries.firstIndex(where: {
                let other = $0.name.lowercased()
                return other == lower || other.hasSuffix(lower) || lower.hasSuffix(other)
            }) {
                name = batteries[index].name
                batteries.remove(at: index)
            }
            devices.append(ConnectedBluetoothDevice(address: device.addressString ?? name, name: name,
                                                    symbol: BluetoothBatteryMonitor.symbol(name: name, type: Self.typeHint(device))))
        }
        // Low-energy accessories that report a battery but aren't "connected" classic devices.
        for battery in batteries {
            devices.append(ConnectedBluetoothDevice(address: battery.name, name: battery.name, symbol: battery.symbol))
        }
        devices.sort { $0.name < $1.name }
        if devices != bluetoothDevices { withAnimation(.smooth) { bluetoothDevices = devices } }
    }

    private static func typeHint(_ device: IOBluetoothDevice) -> String {
        switch device.deviceClassMajor {
        case BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorAudio): return "headphones"
        case BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorPhone): return "phone"
        case BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorWearable): return "watch"
        case BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorPeripheral):
            let minor = device.deviceClassMinor
            if minor & 0x10 != 0 { return "keyboard" }
            if minor & 0x20 != 0 { return "mouse" }
            return "gamepad"
        default: return ""
        }
    }

    // MARK: CWEventDelegate (called on a CoreWLAN queue)

    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) { scheduleRefresh() }
    nonisolated func linkDidChangeForWiFiInterface(withName interfaceName: String) { scheduleRefresh() }
    nonisolated func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { scheduleRefresh() }

    private nonisolated func scheduleRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            MainActor.assumeIsolated { ConnectivityMonitor.shared.refreshNetwork() }
        }
    }

    // MARK: Formatting

    static func speedText(_ bitsPerSecond: UInt64) -> String? {
        guard bitsPerSecond > 0 else { return nil }
        if bitsPerSecond >= 1_000_000_000 {
            let gbps = Double(bitsPerSecond) / 1_000_000_000
            return gbps == gbps.rounded() ? "\(Int(gbps)) Gbps" : String(format: "%.1f Gbps", gbps)
        }
        return "\(bitsPerSecond / 1_000_000) Mbps"
    }
}
