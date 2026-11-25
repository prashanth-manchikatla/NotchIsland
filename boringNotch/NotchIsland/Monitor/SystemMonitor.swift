//
//  SystemMonitor.swift
//  NotchIsland
//
//  Live system monitor for testing software: samples only while something shows
//  it (Monitor tab / Monitor window: every second; the closed-island readout:
//  every 2 s) and stops completely otherwise.
//

import AppKit
import Combine
import Defaults
import SwiftUI

extension Defaults.Keys {
    /// Live CPU % and CPU temperature in the closed island.
    static let monitorInIsland = Key<Bool>("monitorInIsland", default: false)
    static let monitorWindowOnTop = Key<Bool>("monitorWindowOnTop", default: false)
}

struct MonitorHistory: Equatable {
    static let length = 90

    var cpu: [Double] = []
    var performance: [Double] = []
    var efficiency: [Double] = []
    var gpu: [Double] = []
    var memory: [Double] = []
    var power: [Double] = []
    var temperature: [Double] = []
    var down: [Double] = []
    var up: [Double] = []
    var read: [Double] = []
    var write: [Double] = []

    mutating func append(_ s: SystemSnapshot) {
        func push(_ array: inout [Double], _ value: Double) {
            array.append(value)
            if array.count > Self.length { array.removeFirst(array.count - Self.length) }
        }
        push(&cpu, s.cpuUsage)
        push(&performance, s.clusters.first { $0.isPerformance }?.usage ?? 0)
        push(&efficiency, s.clusters.first { !$0.isPerformance }?.usage ?? 0)
        push(&gpu, s.gpu.usage)
        push(&memory, s.memory.total > 0 ? Double(s.memory.used) / Double(s.memory.total) : 0)
        push(&power, s.power.system ?? s.power.cpu ?? 0)
        push(&temperature, s.temperatures.cpuMax ?? 0)
        push(&down, s.network.downPerSec)
        push(&up, s.network.upPerSec)
        push(&read, s.disk.readPerSec)
        push(&write, s.disk.writePerSec)
    }
}

@MainActor
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    enum Viewer: Hashable { case tab, window, island }

    @Published private(set) var snapshot: SystemSnapshot?
    @Published private(set) var history = MonitorHistory()
    let chip = ChipInfo.read()

    private final class SamplerBox: @unchecked Sendable { var sampler: SystemSampler? }
    private let box = SamplerBox()
    private let queue = DispatchQueue(label: "NotchIsland.Monitor", qos: .utility)
    private var viewers: Set<Viewer> = []
    private var timer: DispatchSourceTimer?
    private var currentInterval: Double?
    private var sampling = false
    private var cancellables = Set<AnyCancellable>()

    private init() {
        Defaults.publisher(.monitorInIsland)
            .map(\.newValue)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] on in
                MainActor.assumeIsolated {
                    if on { self?.attach(.island) } else { self?.detach(.island) }
                }
            }
            .store(in: &cancellables)
    }

    /// Starts the island readout at launch if it was left on.
    func startIfNeeded() {
        if Defaults[.monitorInIsland] { attach(.island) }
    }

    func attach(_ viewer: Viewer) {
        let inserted = viewers.insert(viewer).inserted
        if inserted { reschedule(prime: true) }
    }

    func detach(_ viewer: Viewer) {
        if viewers.remove(viewer) != nil { reschedule(prime: false) }
    }

    private var interval: Double? {
        if viewers.contains(.window) || viewers.contains(.tab) { return 1 }
        if viewers.contains(.island) { return 2 }
        return nil
    }

    private func reschedule(prime: Bool) {
        let wanted = interval
        guard wanted != currentInterval || prime else { return }
        timer?.cancel()
        timer = nil
        currentInterval = wanted
        guard let wanted else { return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + (prime ? 0.35 : wanted), repeating: wanted, leeway: .milliseconds(150))
        source.setEventHandler { MainActor.assumeIsolated { SystemMonitor.shared.tick() } }
        source.resume()
        timer = source
        if prime { tick() } // first reading right away (rates fill in on the next one)
    }

    private func tick() {
        guard !sampling else { return }
        sampling = true
        let processes = viewers.contains(.window) || viewers.contains(.tab)
        let system = viewers.contains(.window)
        var apps: [pid_t: (name: String, bundleID: String?)] = [:]
        if processes {
            for app in NSWorkspace.shared.runningApplications {
                apps[app.processIdentifier] = (app.localizedName ?? app.bundleIdentifier ?? "App", app.bundleIdentifier)
            }
        }
        let box = self.box
        queue.async {
            if box.sampler == nil { box.sampler = SystemSampler() }
            let snapshot = box.sampler?.sample(processes: processes, systemProcesses: system, apps: apps)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let monitor = SystemMonitor.shared
                    monitor.sampling = false
                    guard let snapshot, monitor.currentInterval != nil else { return }
                    monitor.snapshot = snapshot
                    monitor.history.append(snapshot)
                }
            }
        }
    }
}

// MARK: - Formatting

enum MonitorFormat {
    static func percent(_ value: Double) -> String { "\(Int((max(0, value) * 100).rounded()))%" }

    static func gigabytes(_ bytes: UInt64) -> String { String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }

    static func bytes(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        if value >= 1_073_741_824 { return String(format: "%.1f GB", value / 1_073_741_824) }
        if value >= 1_048_576 { return String(format: "%.0f MB", value / 1_048_576) }
        return String(format: "%.0f KB", value / 1024)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_048_576 { return String(format: "%.1f MB/s", bytesPerSecond / 1_048_576) }
        if bytesPerSecond >= 1024 { return String(format: "%.0f KB/s", bytesPerSecond / 1024) }
        return "\(Int(bytesPerSecond)) B/s"
    }

    /// Compact rate for small tiles: "1.2M", "340K", "0".
    static func shortRate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_048_576 { return String(format: "%.1fM", bytesPerSecond / 1_048_576) }
        if bytesPerSecond >= 1024 { return String(format: "%.0fK", bytesPerSecond / 1024) }
        return bytesPerSecond < 1 ? "0" : "\(Int(bytesPerSecond))B"
    }

    static func watts(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value < 0.095 { return "\(Int((value * 1000).rounded())) mW" }
        return String(format: "%.1f W", value)
    }

    static func temperature(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))°" } ?? "—" }

    static func frequency(_ mhz: Double?) -> String {
        guard let mhz, mhz > 0 else { return "—" }
        return mhz >= 1000 ? String(format: "%.2f GHz", mhz / 1000) : "\(Int(mhz.rounded())) MHz"
    }

    static func heat(_ value: Double?) -> Color {
        guard let value else { return .gray }
        if value < 55 { return .green }
        if value < 70 { return .yellow }
        if value < 85 { return .orange }
        return .red
    }

    static func load(_ value: Double) -> Color {
        if value < 0.5 { return .green }
        if value < 0.8 { return .yellow }
        return .orange
    }

    static func pressure(_ level: Int) -> (String, Color) {
        switch level {
        case 4: return ("Critical", .red)
        case 2: return ("Warning", .orange)
        default: return ("Normal", .green)
        }
    }

    static func thermal(_ state: ProcessInfo.ThermalState) -> (String, Color) {
        switch state {
        case .nominal: return ("Nominal", .green)
        case .fair: return ("Fair", .yellow)
        case .serious: return ("Serious", .orange)
        case .critical: return ("Critical", .red)
        @unknown default: return ("Unknown", .gray)
        }
    }

    static func uptime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        let days = minutes / 1440, hours = (minutes % 1440) / 60, mins = minutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }
}
