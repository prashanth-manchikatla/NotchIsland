//
//  MonitorTabView.swift
//  Hoverbird
//
//  📈 Monitor tab (island): CPU (Super / Efficiency clusters, frequency, °C),
//  GPU, memory, power and I/O at a glance, every second. ⤢ opens the detailed
//  monitor window; 📌 puts a live CPU readout in the closed island.
//

import Defaults
import SwiftUI

struct MonitorTabView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var monitor = SystemMonitor.shared
    @Default(.monitorInIsland) private var inIsland

    var body: some View {
        let compact = vm.isCameraExpanded
        HStack(alignment: .top, spacing: 6) {
            if let s = monitor.snapshot {
                CPUTile(snapshot: s, history: monitor.history, showGPU: compact)
                    .frame(minWidth: 214, maxWidth: 250)
                if !compact {
                    GPUTile(snapshot: s, history: monitor.history).frame(minWidth: 104, maxWidth: .infinity)
                }
                MemoryTile(snapshot: s, history: monitor.history).frame(minWidth: 112, maxWidth: .infinity)
                PowerTile(snapshot: s, history: monitor.history).frame(minWidth: 112, maxWidth: .infinity)
            } else {
                HStack(spacing: 8) {
                    BirdActivityIndicator(size: 16)
                    Text("Reading sensors…").font(.system(size: 11)).foregroundStyle(.gray)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            VStack(spacing: 6) {
                MonitorSideButton(symbol: "arrow.up.left.and.arrow.down.right", active: false, help: "Open the detailed monitor") {
                    MonitorWindowController.shared.show()
                }
                MonitorSideButton(symbol: inIsland ? "pin.fill" : "pin", active: inIsland,
                                  help: inIsland ? "Stop showing CPU in the closed island" : "Show live CPU % and temperature in the closed island") {
                    inIsland.toggle()
                }
                Spacer(minLength: 0)
            }
            .frame(width: 24)
        }
        .frame(height: 128)
        .padding(.top, 2)
        .onAppear { monitor.attach(.tab) }
        .onDisappear { monitor.detach(.tab) }
    }
}

private struct MonitorSideButton: View {
    let symbol: String
    let active: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(active ? Color.orange : Color.white.opacity(0.85))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.18 : 0.09)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Tiles

private struct MonitorTile<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    var value: String? = nil
    var valueColor: Color = .white
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)).foregroundStyle(tint)
                Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                Spacer(minLength: 2)
                if let value {
                    Text(value)
                        .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(valueColor)
                        .lineLimit(1)
                        .fixedSize()
                        .contentTransition(.numericText())
                }
            }
            content()
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 124, maxHeight: 124, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.06)))
    }
}

private struct CPUTile: View {
    let snapshot: SystemSnapshot
    let history: MonitorHistory
    var showGPU = false

    var body: some View {
        MonitorTile(title: "CPU", symbol: "cpu", tint: .blue, value: MonitorFormat.percent(snapshot.cpuUsage),
                    valueColor: MonitorFormat.load(snapshot.cpuUsage)) {
            Sparkline(values: history.cpu, maxValue: 1, color: .blue).frame(height: 20)
            ForEach(snapshot.clusters, id: \.name) { cluster in
                ClusterLine(cluster: cluster)
            }
            HStack(spacing: 6) {
                Text(MonitorFormat.watts(snapshot.power.cpu))
                Text("load \(String(format: "%.1f", snapshot.loadAverage.first ?? 0))")
                if showGPU { Text("GPU \(MonitorFormat.percent(snapshot.gpu.usage))") }
            }
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(.gray)
            .lineLimit(1)
        }
    }
}

/// "S ▮▮▮▯ 34% 3.21 GHz 39°"
private struct ClusterLine: View {
    let cluster: ClusterLoad

    var body: some View {
        HStack(spacing: 4) {
            Text(cluster.isPerformance ? String(cluster.name.prefix(1)) : "E")
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(cluster.isPerformance ? Color.blue : Color.teal)
                .frame(width: 9)
            UsageBar(value: cluster.usage, color: cluster.isPerformance ? .blue : .teal)
                .frame(height: 5)
            Text(MonitorFormat.percent(cluster.usage)).frame(width: 27, alignment: .trailing)
            Text(MonitorFormat.frequency(cluster.mhz)).frame(width: 50, alignment: .trailing)
            Text(MonitorFormat.temperature(cluster.tempMax))
                .foregroundStyle(MonitorFormat.heat(cluster.tempMax))
                .frame(width: 24, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.85))
        .lineLimit(1)
        .help("\(cluster.name) cores ×\(cluster.cores) · \(MonitorFormat.watts(cluster.watts)) · avg \(MonitorFormat.temperature(cluster.tempAvg))")
    }
}

private struct GPUTile: View {
    let snapshot: SystemSnapshot
    let history: MonitorHistory

    var body: some View {
        let gpu = snapshot.gpu
        MonitorTile(title: "GPU", symbol: "cube.transparent", tint: .purple, value: MonitorFormat.percent(gpu.usage),
                    valueColor: MonitorFormat.load(gpu.usage)) {
            Sparkline(values: history.gpu, maxValue: 1, color: .purple).frame(height: 20)
            InfoLine(label: "Clock", value: MonitorFormat.frequency(gpu.mhz))
            InfoLine(label: "Power", value: MonitorFormat.watts(gpu.watts))
            InfoLine(label: "Temp", value: MonitorFormat.temperature(gpu.tempMax), color: MonitorFormat.heat(gpu.tempMax))
            InfoLine(label: "Memory", value: MonitorFormat.bytes(gpu.memoryInUse))
        }
    }
}

private struct MemoryTile: View {
    let snapshot: SystemSnapshot
    let history: MonitorHistory

    var body: some View {
        let memory = snapshot.memory
        let pressure = MonitorFormat.pressure(memory.pressure)
        MonitorTile(title: "RAM", symbol: "memorychip", tint: .green, value: MonitorFormat.gigabytes(memory.used)) {
            MemoryBar(memory: memory).frame(height: 7)
            Text("of \(MonitorFormat.gigabytes(memory.total))")
                .font(.system(size: 9, weight: .medium)).foregroundStyle(.gray)
            InfoLine(label: "Pressure", value: pressure.0, color: pressure.1)
            InfoLine(label: "App", value: MonitorFormat.gigabytes(memory.app))
            InfoLine(label: "Swap", value: MonitorFormat.gigabytes(memory.swapUsed))
        }
    }
}

private struct PowerTile: View {
    let snapshot: SystemSnapshot
    let history: MonitorHistory

    var body: some View {
        let power = snapshot.power
        MonitorTile(title: "Power", symbol: "bolt.fill", tint: .orange, value: MonitorFormat.watts(power.system ?? power.cpu)) {
            Sparkline(values: history.power, color: .orange).frame(height: 18)
            InfoLine(label: "Net", value: "↓\(MonitorFormat.shortRate(snapshot.network.downPerSec)) ↑\(MonitorFormat.shortRate(snapshot.network.upPerSec))")
            InfoLine(label: "Disk", value: "R\(MonitorFormat.shortRate(snapshot.disk.readPerSec)) W\(MonitorFormat.shortRate(snapshot.disk.writePerSec))")
            InfoLine(label: "SSD/Batt", value: "\(MonitorFormat.temperature(snapshot.temperatures.ssd))/\(MonitorFormat.temperature(snapshot.temperatures.battery))")
            let thermal = MonitorFormat.thermal(snapshot.thermalState)
            InfoLine(label: "Thermal", value: thermal.0, color: thermal.1)
        }
    }
}

struct InfoLine: View {
    let label: String
    let value: String
    var color: Color = .white.opacity(0.85)

    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.gray)
            Spacer(minLength: 2)
            Text(value).foregroundStyle(color)
        }
        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
        .lineLimit(1)
    }
}

// MARK: - Building blocks (shared with the window)

/// Lightweight history graph (newest value on the right).
struct Sparkline: View {
    let values: [Double]
    var maxValue: Double? = nil
    var color: Color
    var fill = true

    var body: some View {
        GeometryReader { geo in
            let peak = max(maxValue ?? (values.max() ?? 1), 0.000_001)
            let step = geo.size.width / CGFloat(max(1, MonitorHistory.length - 1))
            let start = CGFloat(MonitorHistory.length - values.count) * step
            let points = values.enumerated().map { index, value in
                CGPoint(x: start + CGFloat(index) * step, y: geo.size.height * (1 - CGFloat(min(1, max(0, value / peak)))))
            }
            ZStack {
                if fill, let first = points.first, let last = points.last {
                    Path { path in
                        path.move(to: CGPoint(x: first.x, y: geo.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: last.x, y: geo.size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                }
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    points.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
            }
        }
        .drawingGroup()
    }
}

struct UsageBar: View {
    let value: Double
    var color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule().fill(color).frame(width: max(2, geo.size.width * CGFloat(min(1, max(0, value)))))
            }
        }
    }
}

/// App · wired · compressed · cached, like Activity Monitor's memory graph.
struct MemoryBar: View {
    let memory: MemoryLoad

    var body: some View {
        GeometryReader { geo in
            let total = max(1, Double(memory.total))
            let parts: [(Double, Color)] = [(Double(memory.app), .green), (Double(memory.wired), .orange),
                                            (Double(memory.compressed), .purple), (Double(memory.cached), .gray.opacity(0.6))]
            HStack(spacing: 1) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    Rectangle().fill(part.1).frame(width: max(0, geo.size.width * CGFloat(part.0 / total) - 1))
                }
                Spacer(minLength: 0)
            }
            .background(Color.white.opacity(0.08))
            .clipShape(Capsule())
        }
    }
}

// MARK: - Closed-island readout

/// "⚙︎ 23%  ·  41°" around the camera while the island is closed.
struct MonitorCompactView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var monitor = SystemMonitor.shared

    var body: some View {
        let usage = monitor.snapshot?.cpuUsage ?? 0
        let temp = monitor.snapshot?.temperatures.cpuMax
        IslandCompactRow(sideWidth: 56) {
            HStack(spacing: 4) {
                Image(systemName: "cpu").font(.system(size: max(11, vm.effectiveClosedNotchHeight - 18), weight: .semibold))
                Text(MonitorFormat.percent(usage))
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
            }
            .foregroundStyle(MonitorFormat.load(usage))
        } trailing: {
            HStack(spacing: 3) {
                Image(systemName: "thermometer.medium").font(.system(size: 10, weight: .semibold))
                Text(MonitorFormat.temperature(temp))
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
            }
            .foregroundStyle(MonitorFormat.heat(temp))
        }
        .animation(.smooth, value: monitor.snapshot?.date)
    }
}

/// Bubble version: a CPU ring.
struct MonitorBubbleView: View {
    let diameter: CGFloat
    @ObservedObject private var monitor = SystemMonitor.shared

    var body: some View {
        let usage = monitor.snapshot?.cpuUsage ?? 0
        ZStack {
            Circle().stroke(Color.white.opacity(0.15), lineWidth: 2.5)
            Circle().trim(from: 0, to: max(0.02, usage))
                .stroke(MonitorFormat.load(usage), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int((usage * 100).rounded()))")
                .font(.system(size: diameter * 0.3, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
        }
        .frame(width: diameter - 9, height: diameter - 9)
    }
}
