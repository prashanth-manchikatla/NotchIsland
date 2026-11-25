//
//  BluetoothBatteryMonitor.swift
//  Hoverbird
//
//  Battery levels of connected Bluetooth devices (AirPods left / right / case,
//  headphones, keyboards, mice…) for the Home tab — including which part is
//  charging — plus "Charge your left earbud" alerts.
//
//  Primary source: macOS's accessory power sources (the same data Apple's
//  Batteries widget uses), read in-process and refreshed only when the system
//  posts a change notification. `system_profiler` is a rare fallback for
//  devices that don't publish a power source (e.g. some third-party headsets).
//

import AppKit
import IOKit.ps
import notify
import SwiftUI

struct BluetoothBattery: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var symbol: String
    var left: Int? = nil
    var right: Int? = nil
    var caseLevel: Int? = nil
    var main: Int? = nil
    var leftCharging = false
    var rightCharging = false
    var caseCharging = false
    var mainCharging = false
    /// Both buds reported as one level (no per-bud detail) — used only when nothing better exists.
    var combined: Int? = nil
}

/// Battery text colours (same orange as the pinned pin) and ring colours.
enum BatteryColors {
    static func text(_ level: Int?) -> Color {
        guard let level else { return .gray }
        if level < 20 { return .red }
        if level < 30 { return .orange }
        return .white
    }

    static func ring(_ level: Int?, charging: Bool) -> Color {
        guard let level else { return .gray }
        if charging { return .green }
        if level < 20 { return .red }
        if level < 30 { return .orange }
        return .green
    }

    static func isLow(_ level: Int?, charging: Bool) -> Bool {
        guard let level else { return false }
        return level < 20 && !charging
    }
}

@MainActor
final class BluetoothBatteryMonitor: ObservableObject {
    static let shared = BluetoothBatteryMonitor()

    @Published private(set) var devices: [BluetoothBattery] = []
    @Published private(set) var loaded = false

    private var powerSourceDevices: [BluetoothBattery] = []
    private var profilerDevices: [BluetoothBattery] = []
    private var lastProfilerRun: Date = .distantPast
    private var profilerRunning = false
    private var readScheduled = false
    private var started = false
    private var tokens: [Int32] = []
    private var timer: Timer?
    private var viewers = 0
    /// Parts we already warned about ("name|left"), so each drop below 20% alerts once.
    private var warned: Set<String> = []
    /// Last level seen for each part ("name|left") — fills gaps while a part is briefly
    /// unreported (e.g. the case after its lid closes).
    private var lastKnown: [String: (level: Int, date: Date)] = [:]
    private var lastRaw = ""

    /// Raw power-source changes → battery-debug.txt (small rolling log for diagnosing odd states).
    private func logRaw(_ raw: String) {
        guard raw != lastRaw else { return }
        lastRaw = raw
        let url = IslandPaths.appSupportPath.appendingPathComponent("battery-debug.txt")
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        IslandDebugLog.write("battery-debug.txt", raw, reset: size > 150_000)
    }

    /// Starts listening for battery changes (event-driven, no polling).
    func start() {
        guard !started else { return }
        started = true
        for name in ["com.apple.system.accpowersources.source",
                     "com.apple.system.accpowersources.attach",
                     "com.apple.system.accpowersources.timeremaining"] {
            var token: Int32 = 0
            let status = notify_register_dispatch(name, &token, DispatchQueue.main) { _ in
                MainActor.assumeIsolated { BluetoothBatteryMonitor.shared.scheduleRead() }
            }
            if status == UInt32(NOTIFY_STATUS_OK) { tokens.append(token) }
        }
        scheduleRead()
    }

    func viewAppeared() {
        start()
        viewers += 1
        scheduleRead()
        runProfiler(maxAge: 180)
        guard timer == nil else { return }
        // Safety net while the card is on screen; the change notifications do the real work.
        let t = Timer(timeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                BluetoothBatteryMonitor.shared.scheduleRead()
                BluetoothBatteryMonitor.shared.runProfiler(maxAge: 180)
            }
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func viewDisappeared() {
        viewers = max(0, viewers - 1)
        if viewers == 0 {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Called when a device connects/disconnects.
    func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.scheduleRead() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.runProfiler(maxAge: 0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.scheduleRead() } // AirPods report a bit later
    }

    // MARK: Power sources (cheap, in-process)

    /// Coalesces bursts of notifications into one read.
    private func scheduleRead() {
        guard !readScheduled else { return }
        readScheduled = true
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
            let result = Self.readPowerSources()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let monitor = BluetoothBatteryMonitor.shared
                    monitor.readScheduled = false
                    monitor.powerSourceDevices = result.devices
                    monitor.logRaw(result.raw)
                    monitor.publish()
                }
            }
        }
    }

    private typealias CopyByType = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
    private nonisolated static let copyPowerSourcesByType: CopyByType? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let symbol = dlsym(handle, "IOPSCopyPowerSourcesByType") else { return nil }
        return unsafeBitCast(symbol, to: CopyByType.self)
    }()

    /// Accessory power sources, grouped into devices (AirPods buds + case share a group).
    /// Also returns a compact description of the raw data for battery-debug.txt.
    private nonisolated static func readPowerSources() -> (devices: [BluetoothBattery], raw: String) {
        guard let copy = copyPowerSourcesByType, let blob = copy(4 /* accessories */)?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return ([], "no accessory sources") }

        struct Part { let name: String; let part: String; let level: Int?; let charging: Bool; let category: String }
        func makePart(_ info: [String: Any], fallbackName: String) -> Part {
            var level: Int?
            if let current = info["Current Capacity"] as? Int {
                let maximum = info["Max Capacity"] as? Int ?? 100
                level = maximum > 0 && maximum != 100 ? Int((Double(current) / Double(maximum) * 100).rounded()) : current
                level = level.map { min(100, max(0, $0)) }
            }
            return Part(name: info["Name"] as? String ?? fallbackName,
                        part: (info["Part Identifier"] as? String ?? "").lowercased(),
                        level: level,
                        charging: info["Is Charging"] as? Bool ?? false,
                        category: info["Accessory Category"] as? String ?? "")
        }

        var groups: [String: [Part]] = [:]
        var order: [String] = []
        var raw: [String] = []
        for source in list {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            if (info["Is Present"] as? Bool) == false { continue }
            if (info["Type"] as? String) == "InternalBattery" { continue }
            let name = info["Name"] as? String ?? "Accessory"
            let key = info["Group Identifier"] as? String ?? info["Accessory Identifier"] as? String ?? name
            if groups[key] == nil { order.append(key) }
            let part = makePart(info, fallbackName: name)
            // Both buds out of the case (or both charging in it): macOS publishes ONE "Combined"
            // source (the lower level) and nests each bud's own source in "Combined Parts".
            if part.part == "combined", let nested = info["Combined Parts"] as? [[String: Any]], !nested.isEmpty {
                let buds = nested.filter { ($0["Is Present"] as? Bool) != false }.map { makePart($0, fallbackName: name) }
                groups[key, default: []].append(contentsOf: buds)
                raw.append("\(name) combined \(part.level.map(String.init) ?? "?")%\(part.charging ? "⚡" : "") = "
                           + buds.map { "\($0.part) \($0.level.map(String.init) ?? "?")%\($0.charging ? "⚡" : "")" }.joined(separator: ", "))
            } else {
                groups[key, default: []].append(part)
                raw.append("\(name) \(part.part.isEmpty ? "-" : part.part) \(part.level.map(String.init) ?? "?")%\(part.charging ? "⚡" : "")")
            }
        }

        var result: [BluetoothBattery] = []
        for key in order {
            guard let parts = groups[key], !parts.isEmpty else { continue }
            let primary = parts.first { $0.part != "case" } ?? parts[0]
            var name = primary.name
            if primary.part == "case", name.hasSuffix(" Case") { name = String(name.dropLast(5)) }
            var device = BluetoothBattery(name: name, symbol: symbol(name: name, type: primary.category))
            for part in parts {
                switch part.part {
                case "left": device.left = part.level; device.leftCharging = part.charging
                case "right": device.right = part.level; device.rightCharging = part.charging
                case "case": device.caseLevel = part.level; device.caseCharging = part.charging
                case "combined":
                    // No per-bud detail: remember the shared level (per-bud values are filled in later).
                    device.combined = part.level
                    if part.charging { device.leftCharging = true; device.rightCharging = true }
                default: device.main = part.level; device.mainCharging = part.charging
                }
            }
            result.append(device)
        }
        return (result, raw.joined(separator: " | "))
    }

    // MARK: system_profiler fallback (rare)

    private func runProfiler(maxAge: TimeInterval) {
        guard !profilerRunning, Date().timeIntervalSince(lastProfilerRun) >= maxAge else { return }
        profilerRunning = true
        Task.detached(priority: .utility) {
            let result = Self.readProfiler()
            await MainActor.run {
                let monitor = BluetoothBatteryMonitor.shared
                monitor.profilerRunning = false
                monitor.lastProfilerRun = Date()
                if let result { monitor.profilerDevices = result }
                monitor.publish()
            }
        }
    }

    private nonisolated static func readProfiler() -> [BluetoothBattery]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "mini"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = json["SPBluetoothDataType"] as? [[String: Any]] else { return nil }

        func level(_ info: [String: Any], _ key: String) -> Int? {
            guard let raw = info[key] as? String else { return nil }
            return Int(raw.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
        }
        var result: [BluetoothBattery] = []
        for controller in controllers {
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    result.append(BluetoothBattery(
                        name: name,
                        symbol: symbol(name: name, type: info["device_minorType"] as? String ?? ""),
                        left: level(info, "device_batteryLevelLeft"),
                        right: level(info, "device_batteryLevelRight"),
                        caseLevel: level(info, "device_batteryLevelCase"),
                        main: level(info, "device_batteryLevelMain") ?? level(info, "device_batteryLevel")))
                }
            }
        }
        return result
    }

    // MARK: Publish + alerts

    private func publish() {
        // Power sources win; system_profiler only adds devices they don't cover.
        let known = Set(powerSourceDevices.map { $0.name.lowercased() })
        let merged = (powerSourceDevices.map(fillGaps) + profilerDevices.filter { !known.contains($0.name.lowercased()) })
            .sorted { $0.name < $1.name }
        // Still missing a bud's level? Ask system_profiler (at most once a minute).
        if powerSourceDevices.contains(where: { $0.combined != nil && ($0.left == nil || $0.right == nil) })
            || merged.contains(where: { $0.isEarbuds && ($0.left == nil || $0.right == nil) }) {
            runProfiler(maxAge: 60)
        }
        loaded = true
        if merged != devices {
            withAnimation(.easeInOut(duration: 0.25)) { devices = merged }
        }
        checkLowBattery(merged)
    }

    /// Every part shows a percentage: power sources first, then system_profiler, then the
    /// last level seen (30 min) — so buds in the case, in your ears or charging always show one.
    private func fillGaps(_ device: BluetoothBattery) -> BluetoothBattery {
        var device = device
        let profiler = profilerDevices.first { $0.name.lowercased() == device.name.lowercased() }
        let fresh = Date().timeIntervalSince(lastProfilerRun) < 600
        func resolve(_ part: String, _ level: Int?, _ fromProfiler: Int?) -> Int? {
            let key = "\(device.name)|\(part)"
            if let level {
                lastKnown[key] = (level, Date())
                return level
            }
            if fresh, let fromProfiler {
                lastKnown[key] = (fromProfiler, Date())
                return fromProfiler
            }
            if let remembered = lastKnown[key], Date().timeIntervalSince(remembered.date) < 1800 { return remembered.level }
            return nil
        }
        if device.isEarbuds || device.left != nil || device.right != nil || device.combined != nil {
            device.left = resolve("left", device.left, profiler?.left) ?? device.combined
            device.right = resolve("right", device.right, profiler?.right) ?? device.combined
            device.caseLevel = resolve("case", device.caseLevel, profiler?.caseLevel)
        } else {
            device.main = resolve("main", device.main, profiler?.main)
        }
        return device
    }

    /// Island alert the first time a bud / case / device drops below 20% (and isn't charging).
    private func checkLowBattery(_ devices: [BluetoothBattery]) {
        var alert: (symbol: String, text: String)?
        for device in devices {
            let parts: [(String, Int?, Bool, String)] = [
                ("left", device.left, device.leftCharging, device.budSymbols.left),
                ("right", device.right, device.rightCharging, device.budSymbols.right),
                ("case", device.caseLevel, device.caseCharging, device.budSymbols.caseSymbol),
                ("main", device.main, device.mainCharging, device.symbol),
            ]
            var newlyLow: [String] = []
            for (part, level, charging, symbol) in parts {
                guard let level else { continue }
                let key = "\(device.name)|\(part)"
                if BatteryColors.isLow(level, charging: charging) {
                    if !warned.contains(key) {
                        warned.insert(key)
                        newlyLow.append(symbol)
                    }
                } else if charging || level >= 25 {
                    warned.remove(key) // hysteresis: warn again only after it recovered
                }
            }
            if alert == nil, !newlyLow.isEmpty, let message = device.lowBatteryMessage {
                alert = (newlyLow.count == 1 ? newlyLow[0] : device.symbol, message)
            }
        }
        if let alert {
            IslandActivityHub.shared.showPill(.info(symbol: alert.symbol, text: alert.text, tint: .red), duration: 4.5)
        }
    }

    nonisolated static func symbol(name: String, type: String) -> String {
        let n = name.lowercased(), t = type.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("beats") { return "beats.headphones" }
        if t.contains("keyboard") || n.contains("keyboard") { return "keyboard.fill" }
        if t.contains("mouse") || n.contains("mouse") { return "magicmouse.fill" }
        if t.contains("trackpad") || n.contains("trackpad") { return "rectangle.and.hand.point.up.left.fill" }
        if t.contains("gamepad") || t.contains("game") || n.contains("controller") { return "gamecontroller.fill" }
        if t.contains("pencil") || n.contains("pencil") { return "applepencil" }
        if t.contains("watch") { return "applewatch" }
        if t.contains("phone") && !t.contains("headphone") { return "iphone" }
        if t.contains("headphone") || t.contains("headset") { return "headphones" }
        if t.contains("speaker") { return "hifispeaker.fill" }
        return "dot.radiowaves.left.and.right"
    }
}

// MARK: - Earbud styling (AirPods / Beats)

extension BluetoothBattery {
    var isEarbuds: Bool { left != nil || right != nil || name.lowercased().contains("airpods") && !name.lowercased().contains("max") }

    var budSymbols: (left: String, right: String, caseSymbol: String) {
        let n = name.lowercased()
        if n.contains("airpods pro") { return ("airpodpro.left", "airpodpro.right", "airpodspro.chargingcase.wireless.fill") }
        if n.contains("airpods (3") || n.contains("airpods 3") || n.contains("airpods 4") || n.contains("airpods (4") {
            return ("airpod.gen3.left", "airpod.gen3.right", "airpods.gen3.chargingcase.wireless.fill")
        }
        if n.contains("airpods") { return ("airpod.left", "airpod.right", "airpods.chargingcase.fill") }
        return ("earbuds", "earbuds", "earbuds.case.fill")
    }

    /// "Alex's AirPods Pro" → "AirPods Pro".
    var shortName: String {
        for marker in ["’s ", "'s "] {
            if let range = name.range(of: marker), range.upperBound < name.endIndex {
                return String(name[range.upperBound...])
            }
        }
        return name
    }

    private var familyName: String {
        if name.localizedCaseInsensitiveContains("airpods") { return "AirPods" }
        if name.localizedCaseInsensitiveContains("beats") { return "Beats" }
        return "earbuds"
    }

    /// Red message when something needs charging (nil when all is fine).
    var lowBatteryMessage: String? {
        let lowLeft = BatteryColors.isLow(left, charging: leftCharging)
        let lowRight = BatteryColors.isLow(right, charging: rightCharging)
        let lowCase = BatteryColors.isLow(caseLevel, charging: caseCharging)
        let caseName = familyName == "earbuds" ? "case" : "\(familyName) case"
        if lowLeft && lowRight { return lowCase ? "Charge your \(familyName) & case" : "Charge your \(familyName)" }
        if lowLeft, let left { return lowCase ? "Charge left earbud & case" : "Charge left earbud · \(left)%" }
        if lowRight, let right { return lowCase ? "Charge right earbud & case" : "Charge right earbud · \(right)%" }
        if lowCase, let caseLevel { return "Charge the \(caseName) · \(caseLevel)%" }
        if BatteryColors.isLow(main, charging: mainCharging), let main { return "Charge \(shortName) · \(main)%" }
        return nil
    }

    /// Green message saying which part is charging and how full it is.
    var chargingMessage: String? {
        func pct(_ value: Int?) -> String { value.map { " · \($0)%" } ?? "" }
        switch (leftCharging, rightCharging, caseCharging) {
        case (true, true, true): return "Earbuds & case charging" + (left != nil && right != nil ? " · L \(left!)% R \(right!)%" : "")
        case (true, true, false):
            if let left, let right { return "Both earbuds charging · L \(left)% R \(right)%" }
            return "Both earbuds charging"
        case (true, false, _): return "Left earbud charging" + pct(left)
        case (false, true, _): return "Right earbud charging" + pct(right)
        case (false, false, true): return "Case charging" + pct(caseLevel)
        default: break
        }
        if mainCharging { return "\(shortName) charging" + pct(main) }
        return nil
    }
}

/// Turns a view around its vertical axis using a flat (2D) transform, so it can't
/// cover neighbouring views the way a 3D-projected layer can.
struct TurnEffect: GeometryEffect {
    var angle: Double
    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        var scale = cos(angle * .pi / 180)
        if abs(scale) < 0.02 { scale = scale < 0 ? -0.02 : 0.02 }
        let transform = CGAffineTransform(translationX: size.width / 2, y: 0)
            .scaledBy(x: scale, y: 1)
            .translatedBy(x: -size.width / 2, y: 0)
        return ProjectionTransform(transform)
    }
}

/// AirPods the Apple way: "85% (L)(R) 82%" plus the case with its level.
/// A charging part gets a green bolt and a green icon.
struct EarbudsBatteryRow: View {
    let device: BluetoothBattery
    var iconSize: CGFloat = 16

    var body: some View {
        let symbols = device.budSymbols
        HStack(spacing: 6) {
            percent(device.left, charging: device.leftCharging)
            HStack(spacing: 1) {
                Image(systemName: symbols.left)
                    .foregroundStyle(device.leftCharging ? Color.green : Color.white)
                Image(systemName: symbols.right)
                    .foregroundStyle(device.rightCharging ? Color.green : Color.white)
            }
            .font(.system(size: iconSize, weight: .medium))
            percent(device.right, charging: device.rightCharging)
            Spacer(minLength: 8)
            if device.caseLevel != nil || device.left != nil {
                Image(systemName: symbols.caseSymbol)
                    .font(.system(size: iconSize * 0.82, weight: .medium))
                    .foregroundStyle(device.caseCharging ? Color.green : Color.white)
                percent(device.caseLevel, charging: device.caseCharging)
            }
        }
    }

    private func percent(_ value: Int?, charging: Bool) -> some View {
        HStack(spacing: 1) {
            if charging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.green)
            }
            Text(value.map { "\($0)%" } ?? "—")
                .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(BatteryColors.text(value))
        }
        .fixedSize() // never squeezed away when space is tight
        .layoutPriority(2)
    }
}

/// One line under the batteries: red "Charge left earbud", or green "Right earbud charging · 79%".
struct BatteryStatusLine: View {
    let text: String
    let isWarning: Bool
    var size: CGFloat = 10

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isWarning ? "exclamationmark.circle.fill" : "bolt.fill")
                .font(.system(size: size, weight: .bold))
            Text(text)
                .font(.system(size: size, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(isWarning ? Color.red : Color.green)
    }
}

/// One device as an Apple Batteries-widget ring: level arc, icon inside, % below.
struct BatteryRing: View {
    let symbol: String
    let level: Int?
    var charging = false
    var size: CGFloat = 36

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.14), lineWidth: 3.5)
                if let level {
                    Circle()
                        .trim(from: 0, to: CGFloat(max(2, level)) / 100)
                        .stroke(BatteryColors.ring(level, charging: charging), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Image(systemName: symbol)
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.white)
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: size * 0.24, weight: .bold))
                        .foregroundStyle(.green)
                        .offset(x: size * 0.36, y: -size * 0.36)
                }
            }
            .frame(width: size, height: size)
            Text(level.map { "\($0)%" } ?? "—")
                .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(BatteryColors.text(level))
        }
    }
}

/// Home-tab card: this Mac + every connected Bluetooth device, like Apple's Batteries widget.
struct BluetoothBatteryCard: View {
    @ObservedObject private var monitor = BluetoothBatteryMonitor.shared
    @ObservedObject private var mac = BatteryStatusViewModel.shared

    var body: some View {
        let earbuds = monitor.devices.filter(\.isEarbuds)
        let others = monitor.devices.filter { !$0.isEarbuds }
        let status = statusLine
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                if let status {
                    BatteryStatusLine(text: status.text, isWarning: status.isWarning)
                } else {
                    Image(systemName: "battery.100percent").font(.system(size: 10, weight: .bold)).foregroundStyle(.green)
                    Text("Batteries").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                }
                Spacer(minLength: 4)
                if !monitor.devices.isEmpty {
                    Text("\(monitor.devices.count + 1)").font(.system(size: 10, weight: .medium)).foregroundStyle(.gray)
                }
            }
            .frame(height: 14)
            ForEach(earbuds) { device in
                EarbudsBatteryRow(device: device, iconSize: earbuds.count > 1 ? 14 : 16)
                    .help(device.name)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    MacBatteryRing(size: earbuds.isEmpty ? 42 : 34)
                    ForEach(others) { device in
                        BatteryRing(symbol: device.symbol, level: device.main ?? device.caseLevel,
                                    charging: device.mainCharging || (device.main == nil && device.caseCharging),
                                    size: earbuds.isEmpty ? 42 : 34)
                            .help(device.name)
                    }
                }
                .padding(.horizontal, 1)
            }
            if monitor.devices.isEmpty && monitor.loaded {
                Text("No Bluetooth devices connected").font(.system(size: 10)).foregroundStyle(.gray)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.07)))
        .onAppear { monitor.viewAppeared() }
        .onDisappear { monitor.viewDisappeared() }
    }

    /// Low batteries first (red), then what's charging (green).
    private var statusLine: (text: String, isWarning: Bool)? {
        if let low = monitor.devices.lazy.compactMap(\.lowBatteryMessage).first { return (low, true) }
        let macLevel = Int(mac.levelBattery)
        if mac.levelBattery > 0, BatteryColors.isLow(macLevel, charging: mac.isCharging || mac.isPluggedIn) {
            return ("Charge your Mac · \(macLevel)%", true)
        }
        if let charging = monitor.devices.lazy.compactMap(\.chargingMessage).first { return (charging, false) }
        return nil
    }
}

/// This Mac's ring; click it for battery health and the charge limit
/// (the details the header's battery icon used to show).
struct MacBatteryRing: View {
    let size: CGFloat
    @ObservedObject private var mac = BatteryStatusViewModel.shared
    @EnvironmentObject var vm: BoringViewModel
    @State private var showDetails = false

    var body: some View {
        Button { showDetails.toggle() } label: {
            BatteryRing(symbol: "laptopcomputer", level: Int(mac.levelBattery), charging: mac.isCharging, size: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("This Mac — click for battery health and charge limit")
        .popover(isPresented: $showDetails, arrowEdge: .bottom) {
            BatteryMenuView(isPluggedIn: mac.isPluggedIn, isCharging: mac.isCharging, levelBattery: mac.levelBattery,
                            maxCapacity: mac.maxCapacity, timeToFullCharge: mac.timeToFullCharge,
                            isInLowPowerMode: mac.isInLowPowerMode, onDismiss: { showDetails = false })
        }
        .onChange(of: showDetails) { vm.isBatteryPopoverActive = showDetails }
        .onDisappear {
            // Switched tabs / camera came on while the popover was open: don't leave the flag behind.
            if showDetails {
                showDetails = false
                vm.isBatteryPopoverActive = false
            }
        }
    }
}

/// The island when AirPods connect: buds turning around + their batteries.
struct EarbudsConnectedIsland: View {
    let name: String
    @ObservedObject private var monitor = BluetoothBatteryMonitor.shared
    @EnvironmentObject var vm: BoringViewModel
    @State private var spin = 0.0

    private var device: BluetoothBattery? {
        monitor.devices.first { $0.name == name } ?? monitor.devices.first(where: \.isEarbuds)
    }

    var body: some View {
        let symbols = (device ?? BluetoothBattery(name: name, symbol: "")).budSymbols
        VStack(spacing: 5) {
            IslandCompactRow(sideWidth: 70) {
                HStack(spacing: 0) {
                    Image(systemName: symbols.left).modifier(TurnEffect(angle: spin))
                    Image(systemName: symbols.right).modifier(TurnEffect(angle: spin))
                }
                .font(.system(size: max(13, vm.effectiveClosedNotchHeight - 15), weight: .medium))
                .foregroundStyle(.white)
            } trailing: {
                Text("Connected").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.green)
            }
            Group {
                if let device, device.left != nil || device.caseLevel != nil {
                    VStack(spacing: 4) {
                        EarbudsBatteryRow(device: device, iconSize: 15)
                        if let low = device.lowBatteryMessage {
                            BatteryStatusLine(text: low, isWarning: true, size: 10.5)
                        } else if let charging = device.chargingMessage {
                            BatteryStatusLine(text: charging, isWarning: false, size: 10.5)
                        }
                    }
                } else {
                    Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(width: 270)
            .padding(.bottom, 10)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatCount(2, autoreverses: false)) { spin = 360 }
        }
    }
}
