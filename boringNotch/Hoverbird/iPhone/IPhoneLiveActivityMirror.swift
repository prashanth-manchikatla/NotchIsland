//
//  IPhoneLiveActivityMirror.swift
//  Hoverbird
//
//  macOS Tahoe shows your iPhone's Live Activities (food delivery, rides,
//  timers, sports…) as status items in the menu bar, hosted by ControlCenter.
//  On a 13" MacBook those items often hide behind the notch. This mirror reads
//  them through Accessibility and shows them in the island instead.
//
//  Event-driven: ControlCenter posts `…didPresentLiveActivity` when one
//  appears; while any are live we refresh their text every few seconds.
//

import AppKit
import ApplicationServices
import Combine
import Defaults

/// Optional, hand-tunable recognition rules: ~/Library/Application Support/Hoverbird/liveactivity-rules.json
struct LiveActivityRules: Codable {
    var hostBundleIDs: [String]? = nil
    var identifierContains: [String]? = nil
    var labelContains: [String]? = nil
    var excludeIdentifierContains: [String]? = nil
    var treatUnknownControlCenterItemsAsLive: Bool? = nil
    var scanWindows: Bool? = nil
}

struct MirroredLiveActivity: Identifiable, Equatable {
    let id: String
    var appName: String?
    var title: String
    var detail: String
    var allText: [String]
    var frame: CGRect?
}

@MainActor
final class IPhoneLiveActivityMirror: ObservableObject {
    static let shared = IPhoneLiveActivityMirror()

    @Published private(set) var activities: [MirroredLiveActivity] = []
    var primary: MirroredLiveActivity? { activities.first }

    private static let hostBundleIDs = ["com.apple.controlcenter", "com.apple.systemuiserver"]
    private var elements: [String: AXUIElement] = [:]
    private var refreshTimer: Timer?
    private var observers: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    private var enabled = false
    private var rules = LiveActivityRules()
    private var rulesModified: Date?
    private var didAutoExport = false

    private var rulesURL: URL { IslandPaths.appSupport.appendingPathComponent("liveactivity-rules.json") }

    private func reloadRulesIfNeeded() {
        let modified = (try? FileManager.default.attributesOfItem(atPath: rulesURL.path)[.modificationDate]) as? Date
        guard modified != rulesModified else { return }
        rulesModified = modified
        if let data = try? Data(contentsOf: rulesURL), let decoded = try? JSONDecoder().decode(LiveActivityRules.self, from: data) {
            rules = decoded
        } else {
            rules = LiveActivityRules()
        }
    }

    private init() {
        Defaults.publisher(.iPhoneLiveActivitiesEnabled)
            .map(\.newValue)
            .combineLatest(NotificationCenter.default.publisher(for: .accessibilityAuthorizationChanged).map { _ in () }.prepend(()))
            .receive(on: RunLoop.main)
            .sink { [weak self] on, _ in
                guard let self else { return }
                self.enabled = on && AXIsProcessTrusted()
                if self.enabled { self.start() } else { self.stop() }
            }
            .store(in: &cancellables)
    }

    private func start() {
        guard observers.isEmpty else { return }
        let names = [
            "com.apple.controlcenter.liveActivityController.didPresentLiveActivity",
            "com.apple.controlcenter.liveactivity",
        ]
        for name in names {
            observers.append(DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { IPhoneLiveActivityMirror.shared.refresh() } })
        }
        // Wake / unlock can change what's live.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { IPhoneLiveActivityMirror.shared.refresh() } })
        refresh()
        scheduleRefresh()
    }

    private func stop() {
        observers.forEach {
            DistributedNotificationCenter.default().removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        observers.removeAll()
        refreshTimer?.invalidate()
        refreshTimer = nil
        if !activities.isEmpty { activities = [] }
        elements = [:]
    }

    /// Fast refresh while something is live, a slow safety net otherwise.
    private func scheduleRefresh() {
        refreshTimer?.invalidate()
        guard enabled else { return }
        let interval: TimeInterval = activities.isEmpty ? 20 : 4
        let timer = Timer(timeInterval: interval, repeats: false) { _ in
            MainActor.assumeIsolated {
                IPhoneLiveActivityMirror.shared.refresh()
                IPhoneLiveActivityMirror.shared.scheduleRefresh()
            }
        }
        timer.tolerance = interval * 0.25
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func refresh() {
        guard enabled else { return }
        reloadRulesIfNeeded()
        if !didAutoExport {
            didAutoExport = true
            _ = exportDiagnostics()
        }
        var found: [MirroredLiveActivity] = []
        var newElements: [String: AXUIElement] = [:]
        let hosts = Self.hostBundleIDs + (rules.hostBundleIDs ?? [])
        for host in hosts {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: host).first else { continue }
            let appElement = AX.app(pid: app.processIdentifier)
            for bar in AX.elements(appElement, "AXExtrasMenuBar") {
                for item in AX.children(bar) {
                    guard let activity = Self.liveActivity(from: item, host: host, rules: rules) else { continue }
                    found.append(activity)
                    newElements[activity.id] = item
                }
            }
            if rules.scanWindows == true {
                for window in AX.elements(appElement, kAXWindowsAttribute as String) {
                    guard let activity = Self.liveActivity(from: window, host: host, rules: rules) else { continue }
                    found.append(activity)
                    newElements[activity.id] = window
                }
            }
        }
        elements = newElements
        let wasEmpty = activities.isEmpty
        if found != activities { activities = found }
        if wasEmpty != activities.isEmpty { scheduleRefresh() }
    }

    /// Expands the activity in the menu bar (macOS shows its full Live Activity view).
    func open(_ activity: MirroredLiveActivity) {
        if let element = elements[activity.id] {
            AX.press(element)
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ScreenContinuity") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Recognition

    private static let systemExtraPrefixes = [
        "com.apple.menuextra.", "com.apple.controlcenter.clock", "com.apple.controlcenter.battery",
        "com.apple.controlcenter.wifi", "com.apple.controlcenter.bluetooth", "com.apple.controlcenter.sound",
        "com.apple.controlcenter.focus", "com.apple.controlcenter.display", "com.apple.controlcenter.nowplaying",
        "com.apple.controlcenter.screenmirroring", "com.apple.controlcenter.airdrop", "com.apple.controlcenter.user",
    ]

    static func liveActivity(from item: AXUIElement, host: String = "com.apple.controlcenter",
                             rules: LiveActivityRules = LiveActivityRules()) -> MirroredLiveActivity? {
        let identifier = AX.identifier(item) ?? ""
        let description = AX.string(item, kAXDescriptionAttribute as String) ?? ""
        let title = AX.string(item, kAXTitleAttribute as String) ?? ""
        let help = AX.string(item, kAXHelpAttribute as String) ?? ""
        let lowerID = identifier.lowercased()
        let labels = [description, title, help]

        if let excluded = rules.excludeIdentifierContains,
           excluded.contains(where: { !$0.isEmpty && lowerID.contains($0.lowercased()) }) { return nil }
        let ruleHit = (rules.identifierContains ?? []).contains { !$0.isEmpty && lowerID.contains($0.lowercased()) }
            || (rules.labelContains ?? []).contains { needle in labels.contains { $0.localizedCaseInsensitiveContains(needle) } }
        let unknownCCItem = rules.treatUnknownControlCenterItemsAsLive == true && host == "com.apple.controlcenter"
            && !systemExtraPrefixes.contains(where: { lowerID.hasPrefix($0) })
            && labels.contains { !$0.isEmpty }
        let looksLive = ruleHit || unknownCCItem || lowerID.contains("liveactivit")
            || labels.contains { $0.localizedCaseInsensitiveContains("Live Activity") }
        guard looksLive else { return nil }
        if !ruleHit, !lowerID.contains("liveactivit"), systemExtraPrefixes.contains(where: { lowerID.hasPrefix($0) }) { return nil }

        let childTexts = AX.texts(in: item, maxDepth: 6, limit: 8)
        // Strip the generic module name; keep what's specific to this activity.
        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: "Live Activity", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,:-–·\n"))
        }
        var parts = [description, title, help].map(clean).filter { !$0.isEmpty }
        parts += childTexts.map(clean).filter { !$0.isEmpty && !parts.contains($0) }
        let head = parts.first ?? "iPhone"
        let rest = parts.dropFirst().joined(separator: " · ")
        // Activity labels are usually "App, status"; split on the first comma.
        var appName: String? = nil
        var line = head
        if let comma = head.firstIndex(of: ",") {
            appName = String(head[..<comma]).trimmingCharacters(in: .whitespaces)
            line = String(head[head.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
        }
        let id = identifier.isEmpty ? "la-\(appName ?? head)" : identifier
        return MirroredLiveActivity(
            id: id, appName: appName, title: line.isEmpty ? (appName ?? "Live Activity") : line,
            detail: rest, allText: parts, frame: nil)
    }

    /// Short text for the compact island's trailing side.
    static func compactText(_ activity: MirroredLiveActivity) -> String {
        let source = ([activity.title] + activity.allText).joined(separator: " ")
        if let match = source.range(of: #"\d{1,3}\s?(?:min|mins|m)\b"#, options: .regularExpression) {
            return String(source[match]).replacingOccurrences(of: "mins", with: "min")
        }
        if let match = source.range(of: #"\d{1,2}:\d{2}(?::\d{2})?"#, options: .regularExpression) {
            return String(source[match])
        }
        let words = activity.title.split(separator: " ").prefix(2).joined(separator: " ")
        return String(words.prefix(10))
    }

    // MARK: - Diagnostics

    /// Writes every menu-bar extra (and its AX tree) to a text file — run this
    /// while a Live Activity is visible to fine-tune recognition.
    func exportDiagnostics() -> URL {
        var out = "Hoverbird menu-bar diagnostics — \(Date())\nAX trusted: \(AXIsProcessTrusted())\n\n"
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier else { continue }
            let appElement = AX.app(pid: app.processIdentifier)
            let bars = AX.elements(appElement, "AXExtrasMenuBar")
            let isHost = Self.hostBundleIDs.contains(id) || id.lowercased().contains("activit") || id.contains("ScreenContinuity")
            guard isHost || !bars.isEmpty else { continue }
            out += "=== \(id) pid \(app.processIdentifier)\n"
            for bar in bars { AX.dump(bar, maxDepth: isHost ? 8 : 3, into: &out) }
            if isHost {
                for window in AX.elements(appElement, kAXWindowsAttribute as String) {
                    out += "  [window]\n"
                    AX.dump(window, depth: 1, maxDepth: 8, into: &out)
                }
            }
            out += "\n"
        }
        if let data = try? JSONEncoder().encode(rules), let text = String(data: data, encoding: .utf8) {
            out += "Rules in effect: \(text)\n"
        }
        out += "Recognised live activities: \(activities.map(\.allText))\n"
        out += "Screen recording permission: preflight=\(CGPreflightScreenCaptureAccess()) sck=\(ScreenCapturePermission.isGranted) err=\(ScreenCapturePermission.lastError ?? "-")\n"
        out += "Notification mirror active: \(NotificationMirror.shared.isActive)\n"
        // App names only — notification text never goes into this file.
        out += "  notifications: \(NotificationMirror.shared.recent.count) (synced \(NotificationMirror.shared.lastSynced.map { "\(Int(-$0.timeIntervalSinceNow))s ago" } ?? "never")) apps=\(Set(NotificationMirror.shared.recent.map(\.appName)).sorted())\n"
        for order in OrderTracker.shared.orders {
            out += "  order: \(order.appName) stage=\(order.stage.label) eta=\(order.eta.map { "\($0)" } ?? "-")\n"
        }
        out += "Live video: hasVideo=\(LiveVideoManager.shared.hasVideo) streamingPlatform=\(LiveVideoManager.shared.ottPlatform?.name ?? "-") nowPlaying=\(MusicManager.shared.bundleIdentifier ?? "-") playing=\(MusicManager.shared.isPlaying)\n"
        func level(_ value: Int?, _ charging: Bool) -> String { value.map { "\($0)%\(charging ? "⚡" : "")" } ?? "-" }
        for device in BluetoothBatteryMonitor.shared.devices {
            out += "Battery: \(device.name) L=\(level(device.left, device.leftCharging)) R=\(level(device.right, device.rightCharging)) case=\(level(device.caseLevel, device.caseCharging)) main=\(level(device.main, device.mainCharging)) low=\(device.lowBatteryMessage ?? "-") charging=\(device.chargingMessage ?? "-")\n"
        }
        out += "Timers: \(IslandTimerManager.shared.timers.count)  Stopwatches: \(IslandTimerManager.shared.stopwatches.count)\n"
        let net = ConnectivityMonitor.shared
        net.refreshNetwork()
        net.refreshBluetooth()
        out += "Connectivity: primary=\(net.primary) internet=\(net.internet) hotspot=\(net.isHotspot) wifi(on=\(net.wifi.poweredOn) joined=\(net.wifi.associated) ssid=\(net.wifi.ssid ?? "hidden/none") rssi=\(net.wifi.rssi.map(String.init) ?? "-") band=\(net.wifi.band ?? "-") tx=\(net.wifi.txRate.map { "\(Int($0))" } ?? "-")) interfaces=\(net.interfaces.map { "\($0.bsdName):\($0.displayName):\($0.kind)" }) bluetooth(on=\(net.bluetoothOn) devices=\(net.bluetoothDevices.map(\.name)))\n"
        out += "Clipboard items: \(ClipboardManager.shared.items.count)  Awake: \(AwakeManager.shared.isActive)\n\n"
        if let id = MusicManager.shared.bundleIdentifier,
           let player = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            out += "Now-playing app menu (\(player.localizedName ?? id)):\n"
            let appElement = AX.app(pid: player.processIdentifier)
            for barItem in AX.elements(appElement, kAXMenuBarAttribute as String).flatMap({ AX.children($0) }) {
                let menuTitle = AX.string(barItem, kAXTitleAttribute as String) ?? "?"
                let items = AX.children(barItem).flatMap { AX.children($0) }.compactMap { item -> String? in
                    guard let t = AX.string(item, kAXTitleAttribute as String) else { return nil }
                    let enabled = (AX.attribute(item, kAXEnabledAttribute as String) as? Bool) ?? true
                    return enabled ? t : "(\(t))"
                }
                out += "  \(menuTitle): \(items.prefix(14).joined(separator: " · "))\n"
            }
            out += "\n"
        }
        out += "=== Notification Center tree\n" + NotificationMirror.shared.dumpTree()
        let url = IslandPaths.appSupport.appendingPathComponent("diagnostics.txt")
        try? out.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
