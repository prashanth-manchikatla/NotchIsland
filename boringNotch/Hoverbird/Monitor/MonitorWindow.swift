//
//  MonitorWindow.swift
//  Hoverbird
//
//  The detailed live monitor (opened from the Monitor tab): chip, CPU per cluster
//  and per core (load, frequency, power, temperature sensors), GPU, memory,
//  power per component, thermals, disk, network and the busiest processes.
//

import AppKit
import Defaults
import SwiftUI

@MainActor
final class MonitorWindowController: NSObject, NSWindowDelegate {
    static let shared = MonitorWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Hoverbird Monitor"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 760, height: 520)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = NSHostingView(rootView: MonitorDetailView())
            window.setFrameAutosaveName("HoverbirdMonitor")
            if window.frame.origin == .zero { window.center() }
            window.delegate = self
            self.window = window
        }
        applyLevel()
        SystemMonitor.shared.attach(.window)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func applyLevel() {
        window?.level = Defaults[.monitorWindowOnTop] ? .floating : .normal
    }

    func windowWillClose(_ notification: Notification) {
        SystemMonitor.shared.detach(.window)
    }
}

struct MonitorDetailView: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    @Default(.monitorInIsland) private var inIsland
    @Default(.monitorWindowOnTop) private var onTop

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let s = monitor.snapshot {
                    CPUSection(snapshot: s, history: monitor.history, chip: monitor.chip)
                    HStack(alignment: .top, spacing: 14) {
                        GPUSection(snapshot: s, history: monitor.history, cores: monitor.chip.gpuCores)
                        MemorySection(snapshot: s, history: monitor.history)
                    }
                    HStack(alignment: .top, spacing: 14) {
                        PowerSection(snapshot: s, history: monitor.history)
                        ThermalSection(snapshot: s)
                    }
                    HStack(alignment: .top, spacing: 14) {
                        DiskSection(snapshot: s, history: monitor.history)
                        NetworkSection(snapshot: s, history: monitor.history)
                    }
                    ProcessSection(snapshot: s)
                } else {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Reading sensors…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 34)
            .padding(.bottom, 18)
        }
        .background(Color(red: 0.07, green: 0.07, blue: 0.08))
        .onChange(of: onTop) { MonitorWindowController.shared.applyLevel() }
    }

    private var header: some View {
        let chip = monitor.chip
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: "cpu.fill").font(.system(size: 26)).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(chip.name).font(.system(size: 18, weight: .bold))
                Text("\(chip.performanceCores + chip.efficiencyCores)-core CPU (\(chip.performanceCores) \(chip.performanceName) + \(chip.efficiencyCores) Efficiency) · \(chip.gpuCores)-core GPU · \(MonitorFormat.gigabytes(chip.memoryBytes)) unified memory · \(chip.osVersion)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let s = monitor.snapshot {
                    let thermal = MonitorFormat.thermal(s.thermalState)
                    HStack(spacing: 8) {
                        Text("Up \(MonitorFormat.uptime(s.uptime))")
                        Text("·")
                        HStack(spacing: 4) { Circle().fill(thermal.1).frame(width: 7, height: 7); Text("Thermal: \(thermal.0)") }
                        Text("·")
                        Text(s.power.onAC ? (s.power.charging ? "Charging" : "On power adapter") : "On battery")
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Toggle("Show in island", isOn: $inIsland).toggleStyle(.switch).controlSize(.small)
                Toggle("Keep on top", isOn: $onTop).toggleStyle(.switch).controlSize(.small)
            }
            .font(.system(size: 11))
        }
    }
}

// MARK: - Card

private struct Card<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    var value: String? = nil
    var valueColor: Color = .primary
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(tint)
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                if let value {
                    Text(value).font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(valueColor)
                        .contentTransition(.numericText())
                }
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.07)))
    }
}

private struct Row: View {
    let label: String
    let value: String
    var color: Color = .primary

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).foregroundStyle(color).monospacedDigit()
        }
        .font(.system(size: 11.5))
    }
}

// MARK: - CPU

private struct CPUSection: View {
    let snapshot: SystemSnapshot
    let history: MonitorHistory
    let chip: ChipInfo

    var body: some View {
        Card(title: "CPU", symbol: "cpu", tint: .blue, value: MonitorFormat.percent(snapshot.cpuUsage),
             valueColor: MonitorFormat.load(snapshot.cpuUsage)) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    ZStack {
                        Sparkline(values: history.cpu, maxValue: 1, color: .blue)
                        Sparkline(values: history.efficiency, maxValue: 1, color: .teal, fill: false).opacity(0.8)
                    }
                    .frame(height: 70)
                    HStack(spacing: 12) {
                        Text("User \(MonitorFormat.percent(snapshot.cpuUser))")
                        Text("System \(MonitorFormat.percent(snapshot.cpuSystem))")
                        Text("Load \(snapshot.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " / "))")
                        Text("Power \(MonitorFormat.watts(snapshot.power.cpu))")
                    }
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(snapshot.clusters, id: \.name) { cluster in
                        ClusterDetail(cluster: cluster)
                    }
                }
                .frame(width: 300)
            }
            Divider().opacity(0.4)
            CoreGrid(cores: snapshot.cores)
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 6) {
                Text("Temperature sensors (°C) — macOS reports them per cluster, not per core")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                ForEach(snapshot.clusters, id: \.name) { cluster in
                    SensorStrip(title: "\(cluster.name) cluster", values: cluster.sensors)
                }
            }
        }
    }
}

private struct ClusterDetail: View {
    let cluster: ClusterLoad

    var body: some View {
        let tint: Color = cluster.isPerformance ? .blue : .teal
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(cluster.name) cores ×\(cluster.cores)").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(MonitorFormat.percent(cluster.usage)).font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            UsageBar(value: cluster.usage, color: tint).frame(height: 6)
            HStack(spacing: 12) {
                Label(MonitorFormat.frequency(cluster.mhz), systemImage: "speedometer")
                if let max = cluster.maxMHz { Text("max \(MonitorFormat.frequency(max))") }
                Label(MonitorFormat.watts(cluster.watts), systemImage: "bolt.fill")
            }
            .font(.system(size: 10.5).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            Label("\(MonitorFormat.temperature(cluster.tempMax)) max · \(MonitorFormat.temperature(cluster.tempAvg)) avg · \(cluster.sensors.count) sensors",
                  systemImage: "thermometer.medium")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(MonitorFormat.heat(cluster.tempMax))
                .lineLimit(1)
        }
    }
}

/// One bar per core: load, frequency and power.
private struct CoreGrid: View {
    let cores: [CoreLoad]

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(cores.sorted { ($0.isPerformance ? 0 : 1, $0.id) < ($1.isPerformance ? 0 : 1, $1.id) }) { core in
                VStack(spacing: 3) {
                    Text(MonitorFormat.percent(core.usage)).font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    GeometryReader { geo in
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08))
                            RoundedRectangle(cornerRadius: 4)
                                .fill(core.isPerformance ? Color.blue : Color.teal)
                                .frame(height: max(2, geo.size.height * CGFloat(min(1, core.usage))))
                        }
                    }
                    .frame(height: 56)
                    Text(core.label).font(.system(size: 10, weight: .bold)).foregroundStyle(core.isPerformance ? Color.blue : Color.teal)
                    Text(core.mhz.map { $0 >= 1000 ? String(format: "%.1fG", $0 / 1000) : "\(Int($0))M" } ?? "—")
                        .font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                    Text(MonitorFormat.watts(core.watts)).font(.system(size: 8.5).monospacedDigit()).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct SensorStrip: View {
    let title: String
    let values: [Double]

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(title).font(.system(size: 10.5, weight: .semibold)).frame(width: 120, alignment: .leading)
            if values.isEmpty {
                Text("no sensors reported").font(.system(size: 10.5)).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                            Text("\(Int(value.rounded()))")
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(MonitorFormat.heat(value).opacity(0.22)))
                                .foregroundStyle(MonitorFormat.heat(value))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - GPU / Memory / Power / Thermal / Disk / Network

private struct GPUSection: View {
    let snapshot: SystemSnapshot
    let history: MonitorHistory
    let cores: Int

    var body: some View {
        let gpu = snapshot.gpu
        Card(title: "GPU · \(cores) cores", symbol: "cube.transparent", tint: .purple, value: MonitorFormat.percent(gpu.usage),
             valueColor: MonitorFormat.load(gpu.usage)) {
            Sparkline(values: history.gpu, maxValue: 1, color: .purple).frame(height: 54)
            Row(label: "Renderer / Tiler", value: "\(MonitorFormat.percent(gpu.renderer)) / \(MonitorFormat.percent(gpu.tiler))")
            Row(label: "Frequency", value: gpu.maxMHz.map { "\(MonitorFormat.frequency(gpu.mhz)) of \(MonitorFormat.frequency($0))" } ?? MonitorFormat.frequency(gpu.mhz))
            Row(label: "Power", value: MonitorFormat.watts(gpu.watts))
            Row(label: "Memory in use", value: MonitorFormat.bytes(gpu.memoryInUse))
            Row(label: "Temperature", value: "\(MonitorFormat.temperature(gpu.tempMax)) max · \(MonitorFormat.temperature(gpu.tempAvg)) avg (\(gpu.sensorCount) sensors)",
                color: MonitorFormat.heat(gpu.tempMax))
        }
    }
}

private struct MemorySection: View {
    let snapshot: SystemSnapshot
    let history: MonitorHistory

    var body: some View {
        let memory = snapshot.memory
        let pressure = MonitorFormat.pressure(memory.pressure)
        Card(title: "Memory", symbol: "memorychip", tint: .green, value: "\(MonitorFormat.gigabytes(memory.used)) / \(MonitorFormat.gigabytes(memory.total))") {
            Sparkline(values: history.memory, maxValue: 1, color: .green).frame(height: 40)
            MemoryBar(memory: memory).frame(height: 9)
            HStack(spacing: 10) {
                legend("App", .green, memory.app)
                legend("Wired", .orange, memory.wired)
                legend("Compressed", .purple, memory.compressed)
                legend("Cached", .gray, memory.cached)
            }
            Row(label: "Pressure", value: pressure.0, color: pressure.1)
            Row(label: "Swap used", value: "\(MonitorFormat.gigabytes(memory.swapUsed)) of \(MonitorFormat.gigabytes(memory.swapTotal))")
            Row(label: "Page-outs", value: MonitorFormat.rate(memory.pageOutsPerSec))
        }
    }

    private func legend(_ title: String, _ color: Color, _ bytes: UInt64) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(title) \(MonitorFormat.gigabytes(bytes))").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

private struct PowerSection: View {
    let snapshot: SystemSnapshot
    let history: MonitorHistory

    var body: some View {
        let power = snapshot.power
        Card(title: "Power", symbol: "bolt.fill", tint: .orange, value: MonitorFormat.watts(power.system)) {
            Sparkline(values: history.power, color: .orange).frame(height: 40)
            let parts: [(String, String, Double?)] = [("CPU", "cpu", power.cpu), ("GPU", "cube.transparent", power.gpu),
                                                     ("Neural Engine", "brain", power.ane), ("Memory (DRAM)", "memorychip", power.dram),
                                                     ("Display engine", "display", power.display), ("Media / camera", "film", power.media)]
            let peak = max(0.5, parts.compactMap(\.2).max() ?? 1)
            ForEach(parts, id: \.0) { part in
                HStack(spacing: 8) {
                    Label(part.0, systemImage: part.1).font(.system(size: 11)).frame(width: 140, alignment: .leading)
                    UsageBar(value: (part.2 ?? 0) / peak, color: .orange).frame(height: 5)
                    Text(MonitorFormat.watts(part.2)).font(.system(size: 11).monospacedDigit()).frame(width: 58, alignment: .trailing)
                }
            }
            Divider().opacity(0.4)
            Row(label: "Battery", value: batteryText(power))
            if let adapter = power.adapterWatts, power.onAC { Row(label: "Power adapter", value: "\(adapter) W") }
            Row(label: "Battery temperature · cycles", value: "\(MonitorFormat.temperature(power.batteryTemp)) · \(power.cycleCount.map(String.init) ?? "—")")
        }
    }

    private func batteryText(_ power: PowerLoad) -> String {
        let level = power.batteryPercent.map { "\($0)%" } ?? "—"
        guard let watts = power.battery else { return level }
        if watts > 0.05 { return "\(level) · charging \(MonitorFormat.watts(watts))" }
        if watts < -0.05 { return "\(level) · using \(MonitorFormat.watts(-watts))" }
        return level
    }
}

private struct ThermalSection: View {
    let snapshot: SystemSnapshot

    var body: some View {
        let t = snapshot.temperatures
        let thermal = MonitorFormat.thermal(snapshot.thermalState)
        Card(title: "Thermals", symbol: "thermometer.medium", tint: .red, value: MonitorFormat.temperature(t.hottest),
             valueColor: MonitorFormat.heat(t.hottest)) {
            Row(label: "macOS thermal state", value: thermal.0, color: thermal.1)
            ForEach(snapshot.clusters, id: \.name) { cluster in
                Row(label: "\(cluster.name) CPU cores", value: "\(MonitorFormat.temperature(cluster.tempMax)) max · \(MonitorFormat.temperature(cluster.tempAvg)) avg",
                    color: MonitorFormat.heat(cluster.tempMax))
            }
            Row(label: "GPU", value: MonitorFormat.temperature(snapshot.gpu.tempMax), color: MonitorFormat.heat(snapshot.gpu.tempMax))
            Row(label: "SoC", value: MonitorFormat.temperature(t.soc.max()), color: MonitorFormat.heat(t.soc.max()))
            Row(label: "SSD", value: MonitorFormat.temperature(t.ssd), color: MonitorFormat.heat(t.ssd))
            Row(label: "Wi-Fi", value: MonitorFormat.temperature(t.wifi), color: MonitorFormat.heat(t.wifi))
            Row(label: "Battery", value: MonitorFormat.temperature(t.battery), color: MonitorFormat.heat(t.battery))
            Text("MacBook Air has no fan — it slows the chip down instead when it gets hot (state above).")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

private struct DiskSection: View {
    let snapshot: SystemSnapshot
    let history: MonitorHistory

    var body: some View {
        let disk = snapshot.disk
        let used = max(0, disk.total - disk.free)
        Card(title: "Disk · \(disk.name)", symbol: "internaldrive", tint: .cyan,
             value: "\(MonitorFormat.gigabytes(UInt64(disk.free))) free") {
            UsageBar(value: disk.total > 0 ? Double(used) / Double(disk.total) : 0, color: .cyan).frame(height: 8)
            Text("\(MonitorFormat.gigabytes(UInt64(used))) used of \(MonitorFormat.gigabytes(UInt64(disk.total)))")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
            ZStack {
                Sparkline(values: history.read, color: .cyan)
                Sparkline(values: history.write, color: .pink, fill: false)
            }
            .frame(height: 40)
            Row(label: "Read", value: MonitorFormat.rate(disk.readPerSec), color: .cyan)
            Row(label: "Write", value: MonitorFormat.rate(disk.writePerSec), color: .pink)
        }
    }
}

private struct NetworkSection: View {
    let snapshot: SystemSnapshot
    let history: MonitorHistory
    @ObservedObject private var connectivity = ConnectivityMonitor.shared

    var body: some View {
        let net = snapshot.network
        Card(title: "Network · \(connectivity.shortStatus)", symbol: "network", tint: .mint,
             value: MonitorFormat.rate(net.downPerSec)) {
            ZStack {
                Sparkline(values: history.down, color: .mint)
                Sparkline(values: history.up, color: .yellow, fill: false)
            }
            .frame(height: 54)
            Row(label: "Download", value: MonitorFormat.rate(net.downPerSec), color: .mint)
            Row(label: "Upload", value: MonitorFormat.rate(net.upPerSec), color: .yellow)
            if let rssi = connectivity.wifi.rssi { Row(label: "Wi-Fi signal", value: "\(connectivity.wifi.quality) (\(rssi) dBm)") }
        }
    }
}

// MARK: - Processes

private struct ProcessSection: View {
    let snapshot: SystemSnapshot
    @State private var sortByMemory = false
    @State private var filter = ""

    var body: some View {
        let list = snapshot.processes
            .filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
            .sorted { sortByMemory ? $0.memory > $1.memory : $0.cpu > $1.cpu }
            .prefix(16)
        Card(title: "Processes", symbol: "list.bullet.rectangle", tint: .yellow) {
            HStack(spacing: 10) {
                Picker("", selection: $sortByMemory) {
                    Text("By CPU").tag(false)
                    Text("By Memory").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .labelsHidden()
                TextField("Filter (e.g. the app you're testing)", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer()
                Text("% of one core").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack {
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                Text("CPU").frame(width: 70, alignment: .trailing)
                Text("Memory").frame(width: 80, alignment: .trailing)
                Text("Threads").frame(width: 60, alignment: .trailing)
                Text("PID").frame(width: 60, alignment: .trailing)
            }
            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(Array(list)) { process in
                HStack {
                    HStack(spacing: 6) {
                        if let id = process.bundleID, let icon = AppIconAsNSImage(for: id) {
                            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                        } else {
                            Image(systemName: process.isSystem ? "gearshape.2" : "terminal").font(.system(size: 10))
                                .foregroundStyle(.secondary).frame(width: 16, height: 16)
                        }
                        Text(process.name).lineLimit(1)
                        if process.isSystem {
                            Text("system").font(.system(size: 9)).foregroundStyle(.secondary)
                                .padding(.horizontal, 4).background(Capsule().fill(Color.white.opacity(0.08)))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(String(format: "%.1f%%", process.cpu)).frame(width: 70, alignment: .trailing)
                        .foregroundStyle(process.cpu > 80 ? Color.orange : Color.primary)
                    Text(MonitorFormat.bytes(process.memory)).frame(width: 80, alignment: .trailing)
                    Text(process.threads > 0 ? "\(process.threads)" : "—").frame(width: 60, alignment: .trailing)
                    Text("\(process.id)").frame(width: 60, alignment: .trailing).foregroundStyle(.secondary)
                }
                .font(.system(size: 11.5).monospacedDigit())
                .padding(.vertical, 1)
            }
        }
    }
}
