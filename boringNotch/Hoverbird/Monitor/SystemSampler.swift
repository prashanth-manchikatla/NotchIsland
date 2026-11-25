//
//  SystemSampler.swift
//  Hoverbird
//
//  Live resource numbers for Apple silicon — no admin rights needed:
//   • CPU load per core (Mach), cluster / core frequency and power per component
//     (IOReport — the source `powermetrics` uses),
//   • GPU utilisation (IOAccelerator), memory (VM statistics), disk and network
//     throughput, temperatures (SMC), battery & whole-system power
//     (AppleSmartBattery) and processes (libproc).
//  Runs on the monitor's background queue, only while a monitor view is visible.
//

import AppKit
import Darwin
import IOKit

// MARK: - Data

struct ChipInfo {
    let name: String
    /// "Super" on M5, "Performance" on earlier chips.
    let performanceName: String
    let performanceCores: Int
    let efficiencyCores: Int
    let gpuCores: Int
    let memoryBytes: UInt64
    let osVersion: String
    /// true = performance ("Super") core, per logical CPU in CPU order.
    let isPerformanceCPU: [Bool]

    static func read() -> ChipInfo {
        func string(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
            return String(cString: buffer)
        }
        func int(_ name: String) -> Int? {
            var value: Int64 = 0
            var size = MemoryLayout<Int64>.size
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return Int(value)
        }
        let total = int("hw.ncpu") ?? ProcessInfo.processInfo.processorCount
        let pCores = int("hw.perflevel0.logicalcpu") ?? total
        let eCores = int("hw.perflevel1.logicalcpu") ?? 0
        var memory: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memory, &size, nil, 0)

        // Which logical CPU is which kind: the device tree's "cluster-type" (E / P).
        var kinds = [Bool?](repeating: nil, count: total)
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        if cpus != 0 {
            var iterator: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS {
                while case let child = IOIteratorNext(iterator), child != 0 {
                    defer { IOObjectRelease(child) }
                    guard let id = IORegistryEntryCreateCFProperty(child, "logical-cpu-id" as CFString, kCFAllocatorDefault, 0)?
                            .takeRetainedValue() as? NSNumber,
                          let type = IORegistryEntryCreateCFProperty(child, "cluster-type" as CFString, kCFAllocatorDefault, 0)?
                            .takeRetainedValue() as? Data,
                          let first = type.first else { continue }
                    let index = id.intValue
                    if index >= 0 && index < total { kinds[index] = first != UInt8(ascii: "E") }
                }
                IOObjectRelease(iterator)
            }
            IOObjectRelease(cpus)
        }
        // Fallback: efficiency cores come first on Apple silicon.
        let isPerformance = kinds.enumerated().map { $0.element ?? ($0.offset >= eCores) }

        var gpuCores = 0
        let gpu = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        if gpu != 0 {
            gpuCores = (IORegistryEntryCreateCFProperty(gpu, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber)?.intValue ?? 0
            IOObjectRelease(gpu)
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return ChipInfo(name: string("machdep.cpu.brand_string") ?? "Apple silicon",
                        performanceName: string("hw.perflevel0.name") ?? "Performance",
                        performanceCores: pCores, efficiencyCores: eCores, gpuCores: gpuCores, memoryBytes: memory,
                        osVersion: "macOS \(os.majorVersion).\(os.minorVersion)\(os.patchVersion > 0 ? ".\(os.patchVersion)" : "")",
                        isPerformanceCPU: isPerformance)
    }
}

struct CoreLoad: Identifiable, Equatable {
    let id: Int
    let isPerformance: Bool
    let label: String
    let usage: Double
    var mhz: Double?
    var watts: Double?
}

struct ClusterLoad: Equatable {
    let name: String
    let isPerformance: Bool
    let cores: Int
    let usage: Double
    let mhz: Double?
    let maxMHz: Double?
    let watts: Double?
    let tempAvg: Double?
    let tempMax: Double?
    let sensors: [Double]
}

struct GPULoad: Equatable {
    let usage: Double
    let renderer: Double
    let tiler: Double
    let mhz: Double?
    let maxMHz: Double?
    let watts: Double?
    let memoryInUse: UInt64
    let tempAvg: Double?
    let tempMax: Double?
    let sensorCount: Int
}

struct MemoryLoad: Equatable {
    let total: UInt64
    let used: UInt64
    let app: UInt64
    let wired: UInt64
    let compressed: UInt64
    let cached: UInt64
    let swapUsed: UInt64
    let swapTotal: UInt64
    /// 1 normal, 2 warning, 4 critical.
    let pressure: Int
    let pageOutsPerSec: Double
}

struct DiskLoad: Equatable {
    let name: String
    let total: Int64
    let free: Int64
    let readPerSec: Double
    let writePerSec: Double
}

struct NetworkLoad: Equatable {
    let downPerSec: Double
    let upPerSec: Double
}

struct PowerLoad: Equatable {
    var system: Double?
    var cpu: Double?
    var gpu: Double?
    var ane: Double?
    var dram: Double?
    var display: Double?
    var media: Double?
    var battery: Double?
    var onAC = false
    var charging = false
    var adapterWatts: Int?
    var batteryPercent: Int?
    var batteryTemp: Double?
    var cycleCount: Int?
}

struct Temperatures: Equatable {
    var efficiency: [Double] = []
    var performance: [Double] = []
    var gpu: [Double] = []
    var soc: [Double] = []
    var ssd: Double?
    var battery: Double?
    var wifi: Double?

    var cpuMax: Double? { (efficiency + performance).max() }
    var hottest: Double? { (efficiency + performance + gpu + soc).max() }
}

struct ProcessLoad: Identifiable, Equatable {
    let id: pid_t
    let name: String
    let cpu: Double
    let memory: UInt64
    let threads: Int
    let bundleID: String?
    let isSystem: Bool
}

struct SystemSnapshot: Equatable {
    let date: Date
    let cpuUsage: Double
    let cpuUser: Double
    let cpuSystem: Double
    let cores: [CoreLoad]
    let clusters: [ClusterLoad]
    let gpu: GPULoad
    let memory: MemoryLoad
    let disk: DiskLoad
    let network: NetworkLoad
    let power: PowerLoad
    let temperatures: Temperatures
    let thermalState: ProcessInfo.ThermalState
    let loadAverage: [Double]
    let uptime: TimeInterval
    let processes: [ProcessLoad]
}

// MARK: - Sampler

final class SystemSampler: @unchecked Sendable {
    let chip = ChipInfo.read()
    private var previousTicks: [[UInt32]] = []
    private let ioreport = IOReportSampler()
    private let smc = SMCReader()
    private let processSampler = ProcessSampler()
    private var lastDate: Date?
    private var lastDisk: (read: UInt64, write: UInt64)?
    private var lastNet: (down: UInt64, up: UInt64)?
    private var lastPageOuts: UInt64?
    private var capacity: (name: String, total: Int64, free: Int64, date: Date)?

    func sample(processes: Bool, systemProcesses: Bool, apps: [pid_t: (name: String, bundleID: String?)]) -> SystemSnapshot {
        let now = Date()
        let elapsed = max(0.2, lastDate.map { now.timeIntervalSince($0) } ?? 1)
        lastDate = now

        // CPU per core.
        let perCore = cpuLoads()
        let report = ioreport.sample()
        var cores: [CoreLoad] = []
        var eIndex = 0, pIndex = 0
        for (index, load) in perCore.enumerated() {
            let isP = index < chip.isPerformanceCPU.count ? chip.isPerformanceCPU[index] : false
            let ordinal = isP ? pIndex : eIndex
            if isP { pIndex += 1 } else { eIndex += 1 }
            let key = "\(isP ? "PCPU" : "ECPU")\(ordinal)"
            cores.append(CoreLoad(id: index, isPerformance: isP,
                                  label: "\(isP ? String(chip.performanceName.prefix(1)) : "E")\(ordinal + 1)",
                                  usage: load.usage, mhz: report?.cores[key]?.mhz,
                                  watts: report.map { ($0.energy[key] ?? 0) + ($0.energy[key + "_SRAM"] ?? 0) }))
        }
        let totalUsage = perCore.isEmpty ? 0 : perCore.map(\.usage).reduce(0, +) / Double(perCore.count)
        let totalUser = perCore.isEmpty ? 0 : perCore.map(\.user).reduce(0, +) / Double(perCore.count)
        let totalSystem = perCore.isEmpty ? 0 : perCore.map(\.system).reduce(0, +) / Double(perCore.count)

        var temps = smc.temperatures()
        let battery = Self.battery()
        temps.battery = temps.battery ?? battery.temp

        func cluster(_ isP: Bool) -> ClusterLoad {
            let members = cores.filter { $0.isPerformance == isP }
            let usage = members.isEmpty ? 0 : members.map(\.usage).reduce(0, +) / Double(members.count)
            let state = report?.clusters[isP ? "PCPU" : "ECPU"]
            let sensors = isP ? temps.performance : temps.efficiency
            return ClusterLoad(name: isP ? chip.performanceName : "Efficiency", isPerformance: isP, cores: members.count,
                               usage: usage, mhz: state?.mhz, maxMHz: isP ? ioreport.pcpuTable.last : ioreport.ecpuTable.last,
                               watts: report?.energy[isP ? "PCPU" : "ECPU"],
                               tempAvg: sensors.isEmpty ? nil : sensors.reduce(0, +) / Double(sensors.count),
                               tempMax: sensors.max(), sensors: sensors)
        }
        let clusters = [cluster(true), cluster(false)]

        let gpuStats = Self.gpuStatistics()
        let gpu = GPULoad(usage: gpuStats.device, renderer: gpuStats.renderer, tiler: gpuStats.tiler,
                          mhz: report?.gpu?.mhz, maxMHz: ioreport.gpuTable.last, watts: report?.energy["GPU Energy"] ?? report?.energy["GPU"],
                          memoryInUse: gpuStats.memory,
                          tempAvg: temps.gpu.isEmpty ? nil : temps.gpu.reduce(0, +) / Double(temps.gpu.count),
                          tempMax: temps.gpu.max(), sensorCount: temps.gpu.count)

        let memory = memoryLoad(elapsed: elapsed)

        // Disk: capacity every 15 s, throughput every sample.
        if capacity == nil || now.timeIntervalSince(capacity!.date) > 15 {
            let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeNameKey])
            capacity = (values?.volumeName ?? "Macintosh HD", Int64(values?.volumeTotalCapacity ?? 0),
                        values?.volumeAvailableCapacityForImportantUsage ?? 0, now)
        }
        let diskBytes = Self.diskBytes()
        var readRate = 0.0, writeRate = 0.0
        if let lastDisk {
            readRate = Double(diskBytes.read &- lastDisk.read) / elapsed
            writeRate = Double(diskBytes.write &- lastDisk.write) / elapsed
        }
        lastDisk = diskBytes
        let disk = DiskLoad(name: capacity?.name ?? "Macintosh HD", total: capacity?.total ?? 0, free: capacity?.free ?? 0,
                            readPerSec: max(0, readRate), writePerSec: max(0, writeRate))

        let netBytes = Self.networkBytes()
        var down = 0.0, up = 0.0
        if let lastNet, netBytes.down >= lastNet.down, netBytes.up >= lastNet.up {
            down = Double(netBytes.down - lastNet.down) / elapsed
            up = Double(netBytes.up - lastNet.up) / elapsed
        }
        lastNet = netBytes

        var power = PowerLoad()
        power.system = battery.system
        power.cpu = report?.energy["CPU Energy"]
        power.gpu = gpu.watts
        power.ane = report?.energy["ANE"]
        power.dram = report?.energy["DRAM"]
        power.display = report.map { ($0.energy["DISP"] ?? 0) + ($0.energy["DISPEXT"] ?? 0) }
        power.media = report.map { ($0.energy["AVE"] ?? 0) + ($0.energy["AVD"] ?? 0) + ($0.energy["ISP"] ?? 0) }
        power.battery = battery.watts
        power.onAC = battery.onAC
        power.charging = battery.charging
        power.adapterWatts = battery.adapter
        power.batteryPercent = battery.percent
        power.batteryTemp = battery.temp
        power.cycleCount = battery.cycles

        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)

        return SystemSnapshot(
            date: now, cpuUsage: totalUsage, cpuUser: totalUser, cpuSystem: totalSystem, cores: cores, clusters: clusters,
            gpu: gpu, memory: memory, disk: disk, network: NetworkLoad(downPerSec: down, upPerSec: up), power: power,
            temperatures: temps, thermalState: ProcessInfo.processInfo.thermalState, loadAverage: load,
            uptime: ProcessInfo.processInfo.systemUptime,
            processes: processes ? processSampler.sample(elapsed: elapsed, includeSystem: systemProcesses, apps: apps) : [])
    }

    // MARK: CPU ticks

    private func cpuLoads() -> [(usage: Double, user: Double, system: Double)] {
        var count = natural_t(0)
        var info: processor_info_array_t?
        var infoCount = mach_msg_type_number_t(0)
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var ticks: [[UInt32]] = []
        for cpu in 0..<Int(count) {
            let base = Int(CPU_STATE_MAX) * cpu
            ticks.append([UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                          UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                          UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                          UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])])
        }
        defer { previousTicks = ticks }
        guard previousTicks.count == ticks.count else { return ticks.map { _ in (0, 0, 0) } }
        return zip(ticks, previousTicks).map { now, before in
            let user = Double(now[0] &- before[0]) + Double(now[3] &- before[3])
            let system = Double(now[1] &- before[1])
            let idle = Double(now[2] &- before[2])
            let total = max(1, user + system + idle)
            return ((user + system) / total, user / total, system / total)
        }
    }

    // MARK: GPU

    private static func gpuStatistics() -> (device: Double, renderer: Double, tiler: Double, memory: UInt64) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        guard service != 0 else { return (0, 0, 0, 0) }
        defer { IOObjectRelease(service) }
        guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { return (0, 0, 0, 0) }
        func number(_ key: String) -> Double { (stats[key] as? NSNumber)?.doubleValue ?? 0 }
        return (number("Device Utilization %") / 100, number("Renderer Utilization %") / 100,
                number("Tiler Utilization %") / 100, (stats["In use system memory"] as? NSNumber)?.uint64Value ?? 0)
    }

    // MARK: Memory

    private func memoryLoad(elapsed: Double) -> MemoryLoad {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        let page = UInt64(getpagesize())
        let total = chip.memoryBytes
        guard result == KERN_SUCCESS else {
            return MemoryLoad(total: total, used: 0, app: 0, wired: 0, compressed: 0, cached: 0, swapUsed: 0, swapTotal: 0, pressure: 1, pageOutsPerSec: 0)
        }
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let cached = (UInt64(stats.external_page_count) + purgeable) * page

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0)

        let pageOuts = UInt64(stats.pageouts)
        let rate = lastPageOuts.map { Double(pageOuts &- $0) * Double(page) / elapsed } ?? 0
        lastPageOuts = pageOuts
        return MemoryLoad(total: total, used: min(total, app + wired + compressed), app: app, wired: wired, compressed: compressed,
                          cached: cached, swapUsed: swap.xsu_used, swapTotal: swap.xsu_total, pressure: Int(level),
                          pageOutsPerSec: max(0, rate))
    }

    // MARK: Disk & network

    private static func diskBytes() -> (read: UInt64, write: UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return (0, 0)
        }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, write: UInt64 = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            if let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                read &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                write &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(service)
        }
        return (read, write)
    }

    /// Bytes through physical interfaces (Wi-Fi, Ethernet), 64-bit counters.
    private static func networkBytes() -> (down: UInt64, up: UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return (0, 0) }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return (0, 0) }
        var down: UInt64 = 0, up: UInt64 = 0
        var offset = 0
        buffer.withUnsafeBytes { raw in
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                    if if_indextoname(UInt32(info.ifm_index), &name) != nil, String(cString: name).hasPrefix("en") {
                        down &+= info.ifm_data.ifi_ibytes
                        up &+= info.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return (down, up)
    }

    // MARK: Battery & system power

    private static func battery() -> (system: Double?, watts: Double?, onAC: Bool, charging: Bool, adapter: Int?,
                                      percent: Int?, temp: Double?, cycles: Int?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return (nil, nil, true, false, nil, nil, nil, nil) }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = unmanaged?.takeRetainedValue() as? [String: Any] else { return (nil, nil, true, false, nil, nil, nil, nil) }
        func int64(_ key: String) -> Int64? { (props[key] as? NSNumber)?.int64Value }
        let voltage = int64("Voltage").map { Double($0) / 1000 }
        let amperage = int64("InstantAmperage") ?? int64("Amperage")
        let watts = voltage.flatMap { v in amperage.map { v * Double($0) / 1000 } }
        let telemetry = props["PowerTelemetryData"] as? [String: Any]
        let systemLoad = (telemetry?["SystemLoad"] as? NSNumber).map { $0.doubleValue / 1000 }
        let adapter = (props["AdapterDetails"] as? [String: Any])?["Watts"] as? NSNumber
        let current = int64("CurrentCapacity"), maximum = int64("MaxCapacity")
        let percent = current.flatMap { c in maximum.map { $0 > 0 ? Int((Double(c) / Double($0) * 100).rounded()) : Int(c) } }
        return (systemLoad, watts, (props["ExternalConnected"] as? Bool) ?? false, (props["IsCharging"] as? Bool) ?? false,
                adapter?.intValue, percent, int64("Temperature").map { Double($0) / 100 }, int64("CycleCount").map(Int.init))
    }
}

// MARK: - IOReport (frequencies, residency, energy)

final class IOReportSampler {
    private typealias CopyChannels = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias MergeChannels = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Void
    private typealias CreateSubscription = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary,
                                                           UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> OpaquePointer?
    private typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias GetString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias SimpleInteger = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias StateCount = @convention(c) (CFDictionary) -> Int32
    private typealias StateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias StateResidency = @convention(c) (CFDictionary, Int32) -> Int64

    struct Result {
        var energy: [String: Double] = [:]      // watts
        var clusters: [String: (active: Double, mhz: Double?)] = [:]
        var cores: [String: (active: Double, mhz: Double?)] = [:]
        var gpu: (active: Double, mhz: Double?)?
    }

    /// MHz per performance state (lowest first).
    private(set) var ecpuTable: [Double] = []
    private(set) var pcpuTable: [Double] = []
    private(set) var gpuTable: [Double] = []

    private var subscription: OpaquePointer?
    private var subscribed: CFMutableDictionary?
    private var previous: CFDictionary?
    private var previousDate: Date?
    private var createSamples: CreateSamples?
    private var createDelta: CreateDelta?
    private var group: GetString?, subgroup: GetString?, channelName: GetString?, unit: GetString?
    private var simple: SimpleInteger?, stateCount: StateCount?, stateName: StateName?, residency: StateResidency?

    init() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return }
        func load<T>(_ name: String, _ type: T.Type) -> T? {
            guard let symbol = dlsym(handle, name) else { return nil }
            return unsafeBitCast(symbol, to: type)
        }
        guard let copy = load("IOReportCopyChannelsInGroup", CopyChannels.self),
              let merge = load("IOReportMergeChannels", MergeChannels.self),
              let subscribe = load("IOReportCreateSubscription", CreateSubscription.self) else { return }
        createSamples = load("IOReportCreateSamples", CreateSamples.self)
        createDelta = load("IOReportCreateSamplesDelta", CreateDelta.self)
        group = load("IOReportChannelGetGroup", GetString.self)
        subgroup = load("IOReportChannelGetSubGroup", GetString.self)
        channelName = load("IOReportChannelGetChannelName", GetString.self)
        unit = load("IOReportChannelGetUnitLabel", GetString.self)
        simple = load("IOReportSimpleGetIntegerValue", SimpleInteger.self)
        stateCount = load("IOReportStateGetCount", StateCount.self)
        stateName = load("IOReportStateGetNameForIndex", StateName.self)
        residency = load("IOReportStateGetResidency", StateResidency.self)

        var channels: CFDictionary?
        for (groupName, subgroupName) in [("Energy Model", nil), ("CPU Stats", "CPU Complex Performance States"),
                                          ("CPU Stats", "CPU Core Performance States"), ("GPU Stats", "GPU Performance States")] as [(String, String?)] {
            guard let found = copy(groupName as CFString, subgroupName as CFString?, 0, 0, 0)?.takeRetainedValue() else { continue }
            if let channels { merge(channels, found, nil) } else { channels = found }
        }
        guard let channels, let mutable = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, channels) else { return }
        var out: Unmanaged<CFMutableDictionary>?
        guard let subscription = subscribe(nil, mutable, &out, 0, nil), let subscribed = out?.takeRetainedValue() else { return }
        self.subscription = subscription
        self.subscribed = subscribed
        loadFrequencyTables()
    }

    /// The chip's DVFS tables (pmgr "voltage-states*"): KHz on newer chips, Hz on older ones.
    private func loadFrequencyTables() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var name = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(service, &name)
            guard String(cString: name) == "pmgr" else { continue }
            func table(_ key: String) -> [Double] {
                guard let data = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? Data else { return [] }
                var values: [Double] = []
                data.withUnsafeBytes { raw in
                    var offset = 0
                    while offset + 8 <= raw.count {
                        values.append(Double(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                        offset += 8
                    }
                }
                let scale = (values.max() ?? 0) > 100_000_000 ? 1_000_000.0 : 1_000.0
                return values.map { $0 / scale }.filter { $0 > 0 }
            }
            ecpuTable = table("voltage-states1-sram")
            pcpuTable = table("voltage-states5-sram")
            gpuTable = table("voltage-states9")
            break
        }
    }

    func sample() -> Result? {
        guard let subscription, let subscribed, let createSamples, let createDelta,
              let current = createSamples(subscription, subscribed, nil)?.takeRetainedValue() else { return nil }
        let now = Date()
        defer { previous = current; previousDate = now }
        guard let previous, let previousDate,
              let delta = createDelta(previous, current, nil)?.takeRetainedValue() as? [String: Any],
              let list = delta["IOReportChannels"] as? [NSDictionary] else { return nil }
        let items = list.map { $0 as CFDictionary }
        let seconds = max(0.05, now.timeIntervalSince(previousDate))
        var result = Result()
        for item in items {
            let groupName = group?(item)?.takeUnretainedValue() as String? ?? ""
            let name = channelName?(item)?.takeUnretainedValue() as String? ?? ""
            if groupName == "Energy Model" {
                guard let simple else { continue }
                let raw = Double(simple(item, 0))
                let label = unit?(item)?.takeUnretainedValue() as String? ?? "mJ"
                let joules: Double
                switch label {
                case "nJ": joules = raw / 1e9
                case "uJ", "µJ": joules = raw / 1e6
                case "J": joules = raw
                default: joules = raw / 1e3
                }
                result.energy[name] = joules / seconds
            } else {
                let sub = subgroup?(item)?.takeUnretainedValue() as String? ?? ""
                guard let state = states(item, table: table(for: name)) else { continue }
                if sub == "CPU Complex Performance States", name == "ECPU" || name == "PCPU" {
                    result.clusters[name] = state
                } else if sub == "CPU Core Performance States" {
                    result.cores[name] = state
                } else if sub == "GPU Performance States", name == "GPUPH" {
                    result.gpu = state
                }
            }
        }
        return result
    }

    private func table(for channel: String) -> [Double] {
        if channel.hasPrefix("ECPU") { return ecpuTable }
        if channel.hasPrefix("PCPU") { return pcpuTable }
        return gpuTable
    }

    /// Active share and average frequency from state residencies.
    private func states(_ item: CFDictionary, table: [Double]) -> (active: Double, mhz: Double?)? {
        guard let stateCount, let stateName, let residency else { return nil }
        let count = stateCount(item)
        guard count > 0 else { return nil }
        var total = 0.0, active = 0.0, weighted = 0.0, ordinal = 0
        for index in 0..<count {
            let value = Double(residency(item, index))
            total += value
            let name = stateName(item, index)?.takeUnretainedValue() as String? ?? ""
            if name == "IDLE" || name == "OFF" || name == "DOWN" { continue }
            active += value
            if !table.isEmpty { weighted += value * table[min(ordinal, table.count - 1)] }
            ordinal += 1
        }
        guard total > 0 else { return nil }
        return (active / total, active > 0 && !table.isEmpty ? weighted / active : nil)
    }
}

// MARK: - SMC temperatures

final class SMCReader {
    private typealias Bytes32 = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                 UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
    private struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
    private struct Limits { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, memory: UInt32 = 0 }
    private struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0; var attributes: UInt8 = 0 }
    private struct Message {
        var key: UInt32 = 0
        var version = Version()
        var limits = Limits()
        var info = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0, status: UInt8 = 0, command: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes32 = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private var connection: io_connect_t = 0
    private var keys: [(code: UInt32, name: String)] = []
    private var enumerated = false

    init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        if IOServiceOpen(service, mach_task_self_, 0, &connection) != KERN_SUCCESS { connection = 0 }
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    private func call(_ input: inout Message) -> Message? {
        guard connection != 0 else { return nil }
        var output = Message()
        var size = MemoryLayout<Message>.stride
        let status = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<Message>.stride, &output, &size)
        return status == KERN_SUCCESS && output.result == 0 ? output : nil
    }

    private static func code(_ text: String) -> UInt32 { text.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
    private static func text(_ code: UInt32) -> String {
        String(bytes: [UInt8(code >> 24 & 0xff), UInt8(code >> 16 & 0xff), UInt8(code >> 8 & 0xff), UInt8(code & 0xff)], encoding: .ascii) ?? ""
    }

    private func read(_ code: UInt32, size: UInt32) -> [UInt8]? {
        var message = Message()
        message.key = code
        message.info.dataSize = size
        message.command = 5 // read
        guard let output = call(&message) else { return nil }
        return withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(size))) }
    }

    /// Finds every 4-byte float temperature key once (~2,000 keys, a few ms).
    private func enumerate() {
        enumerated = true
        var info = Message()
        info.key = Self.code("#KEY")
        info.command = 9
        guard let countInfo = call(&info), let countBytes = read(Self.code("#KEY"), size: countInfo.info.dataSize) else { return }
        let count = countBytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let float = Self.code("flt ")
        for index in 0..<min(count, 4000) {
            var message = Message()
            message.command = 8 // key at index
            message.data32 = index
            guard let output = call(&message) else { continue }
            let name = Self.text(output.key)
            guard name.hasPrefix("T") else { continue }
            var keyInfo = Message()
            keyInfo.key = output.key
            keyInfo.command = 9
            guard let described = call(&keyInfo), described.info.dataType == float, described.info.dataSize == 4 else { continue }
            keys.append((output.key, name))
        }
    }

    func temperatures() -> Temperatures {
        if !enumerated { enumerate() }
        var result = Temperatures()
        var batteries: [Double] = []
        for (code, name) in keys {
            guard let bytes = read(code, size: 4), bytes.count == 4 else { continue }
            let value = Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
            guard value > 5, value < 130 else { continue }
            if name.hasPrefix("Te") {
                result.efficiency.append(value)
            } else if name.hasPrefix("Tp") {
                result.performance.append(value)
            } else if name.hasPrefix("Tg") {
                result.gpu.append(value)
            } else if name.hasPrefix("Ts") {
                result.soc.append(value)
            } else if name == "TH0x" || name == "TH0T" || name.hasPrefix("TN0") {
                result.ssd = max(result.ssd ?? 0, value)
            } else if name.hasPrefix("TB") && name.hasSuffix("T") {
                batteries.append(value)
            } else if name == "TW0P" {
                result.wifi = value
            }
        }
        if !batteries.isEmpty { result.battery = batteries.reduce(0, +) / Double(batteries.count) }
        return result
    }
}

// MARK: - Processes

final class ProcessSampler {
    private var previous: [pid_t: UInt64] = [:]
    private var names: [pid_t: String] = [:]
    private var systemCache: [ProcessLoad] = []
    private var systemDate: Date = .distantPast
    private let numer: UInt64
    private let denom: UInt64

    init() {
        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)
        numer = UInt64(timebase.numer)
        denom = UInt64(max(1, timebase.denom))
    }

    func sample(elapsed: Double, includeSystem: Bool, apps: [pid_t: (name: String, bundleID: String?)]) -> [ProcessLoad] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.stride * pids.count)))
        var current: [pid_t: UInt64] = [:]
        var loads: [ProcessLoad] = []
        var unreadable = Set<pid_t>()
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else {
                unreadable.insert(pid)
                continue
            }
            let cpuNanos = (info.pti_total_user + info.pti_total_system) * numer / denom
            current[pid] = cpuNanos
            let cpu = previous[pid].map { cpuNanos >= $0 ? Double(cpuNanos - $0) / (elapsed * 1e9) * 100 : 0 } ?? 0
            var usage = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            let footprint = status == 0 ? usage.ri_phys_footprint : info.pti_resident_size
            let app = apps[pid]
            loads.append(ProcessLoad(id: pid, name: app?.name ?? name(of: pid), cpu: cpu, memory: footprint,
                                     threads: Int(info.pti_threadnum), bundleID: app?.bundleID, isSystem: false))
        }
        previous = current
        names = names.filter { current[$0.key] != nil || unreadable.contains($0.key) }

        // Root-owned system processes aren't readable directly: `ps` (setuid) every few seconds.
        if includeSystem {
            if Date().timeIntervalSince(systemDate) > 4 {
                systemDate = Date()
                systemCache = Self.systemProcesses(only: unreadable)
            }
            loads += systemCache.filter { unreadable.contains($0.id) }
        }
        // Keep the interesting ones: top by CPU and by memory.
        let byCPU = loads.sorted { $0.cpu > $1.cpu }.prefix(40)
        let byMemory = loads.sorted { $0.memory > $1.memory }.prefix(40)
        var seen = Set<pid_t>()
        return (byCPU + byMemory).filter { seen.insert($0.id).inserted }
    }

    private func name(of pid: pid_t) -> String {
        if let cached = names[pid] { return cached }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var result = ""
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            result = (String(cString: buffer) as NSString).lastPathComponent
        } else if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            result = String(cString: buffer)
        }
        if result.isEmpty { result = "pid \(pid)" }
        names[pid] = result
        return result
    }

    private static func systemProcesses(only pids: Set<pid_t>) -> [ProcessLoad] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Ao", "pid=,pcpu=,rss=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var result: [ProcessLoad] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = pid_t(parts[0]), pids.contains(pid),
                  let cpu = Double(parts[1].replacingOccurrences(of: ",", with: ".")), let rss = UInt64(parts[2]) else { continue }
            let name = (String(parts[3]) as NSString).lastPathComponent
            result.append(ProcessLoad(id: pid, name: name, cpu: cpu, memory: rss * 1024, threads: 0, bundleID: nil, isSystem: true))
        }
        return result
    }
}
