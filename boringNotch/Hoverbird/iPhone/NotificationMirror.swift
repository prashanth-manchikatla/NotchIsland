//
//  NotificationMirror.swift
//  Hoverbird
//
//  Keeps the island's Notifications list in step with macOS Notification Center —
//  including notifications your iPhone forwards — and feeds order/ride updates to
//  OrderTracker.
//
//  How (macOS 26): Notification Center draws its banners and its panel inside one
//  full-screen window. Every notification is an accessibility element with a stable
//  identifier, a title, a body and "Close" / "Clear All" actions, so:
//   • a new banner → island banner + list (AXObserver, nothing polls);
//   • while the Notification Center panel is open, the list is synced with it
//     (new ones added, ones you cleared there removed);
//   • clearing in the island clears the same notification in Notification Center.
//  Requires Accessibility.
//

import AppKit
import ApplicationServices
import Combine
import Defaults
import SwiftUI

struct MirroredNotification: Identifiable, Codable, Equatable {
    let id: UUID
    var appName: String
    var title: String
    var body: String
    var date: Date
    var isFromIPhone: Bool
    var bundleID: String?
    /// Notification Center's own identifier, used to clear it there too.
    var centerID: String? = nil
    /// Notification Center shows this as a stack of several notifications from one sender.
    var isStack = false
    /// Time as Notification Center shows it ("2m ago", "Yesterday") for synced items.
    var timeLabel: String? = nil
    /// Read in the island (and in Messages etc. when Notification Center offers "Mark as Read").
    var isRead = false
    /// What Notification Center lets you do with it ("Show", "Mark as Read", "Close"…).
    var actions: [String] = []

    func supports(_ action: String) -> Bool { actions.contains { $0.caseInsensitiveCompare(action) == .orderedSame } }
}

@MainActor
final class NotificationMirror: ObservableObject {
    static let shared = NotificationMirror()

    @Published private(set) var recent: [MirroredNotification] = []
    @Published private(set) var isActive = false
    @Published private(set) var lastSynced: Date?
    @Published fileprivate(set) var isSyncing = false
    /// A notification to open in the reader when the island opens (a tapped banner).
    @Published var focusedID: UUID?

    var unreadCount: Int { recent.reduce(0) { $0 + ($1.isRead ? 0 : 1) } }

    fileprivate static let ncBundleID = "com.apple.notificationcenterui"
    private var observer: AXObserver?
    fileprivate var appElement: AXUIElement?
    private var pid: pid_t = 0
    private var seenCenterIDs: Set<String> = []
    private var seenSignatures: [String: Date] = [:]
    /// Cleared from the island: never add them back from a sync.
    private var dismissedCenterIDs: Set<String> = []
    private var scanTask: Task<Void, Never>?
    private var watchdog: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var refcon: Unmanaged<NotificationMirrorRef>?
    private var syncedThisSession = false

    private init() {
        Defaults.publisher(.mirrorNotifications)
            .map(\.newValue)
            .combineLatest(NotificationCenter.default.publisher(for: .accessibilityAuthorizationChanged).map { _ in () }.prepend(()))
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled, _ in
                if enabled && AXIsProcessTrusted() { self?.start() } else { self?.stop() }
            }
            .store(in: &cancellables)
    }

    func start() {
        guard observer == nil else { return }
        attach()
        // Re-attach if Notification Center restarts (cheap check twice a minute).
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let alive = NSRunningApplication.runningApplications(withBundleIdentifier: Self.ncBundleID)
                    .contains { $0.processIdentifier == self.pid }
                if !alive { self.detach(); self.attach() }
            }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        detach()
    }

    private func attach() {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.ncBundleID).first else { return }
        pid = app.processIdentifier
        var newObserver: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let ref = Unmanaged<NotificationMirrorRef>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated { ref.mirror?.scheduleScan(reason: name) }
        }
        guard AXObserverCreate(pid, callback, &newObserver) == .success, let newObserver else { return }
        let element = AX.app(pid: pid)
        let ref = Unmanaged.passRetained(NotificationMirrorRef(self))
        refcon = ref
        for name in [kAXWindowCreatedNotification, kAXCreatedNotification, kAXLayoutChangedNotification,
                     kAXUIElementDestroyedNotification] {
            AXObserverAddNotification(newObserver, element, name as CFString, ref.toOpaque())
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .defaultMode)
        observer = newObserver
        appElement = element
        isActive = true
        // Whatever banners are on screen right now count as already seen.
        scan(silently: true)
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        appElement = nil
        refcon?.release()
        refcon = nil
        isActive = false
    }

    fileprivate func scheduleScan(reason: String) {
        // Banners animate in; coalesce bursts of AX notifications into one read.
        scanTask?.cancel()
        scanTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            self?.scan()
        }
    }

    /// Reads Notification Center right now.
    func scanNow() { scan() }

    private func scan(silently: Bool = false) {
        guard let appElement else { return }
        var cells: [AXUIElement] = []
        var panelOpen = false
        for window in AX.elements(appElement, kAXWindowsAttribute as String) {
            collect(window, depth: 0, cells: &cells, panelOpen: &panelOpen)
        }
        let notes = cells.compactMap(parse)
        if panelOpen {
            sync(with: notes)
        } else {
            for note in notes { deliver(note, silently: silently) }
        }
        let cutoff = Date().addingTimeInterval(-45)
        seenSignatures = seenSignatures.filter { $0.value > cutoff }
    }

    private func collect(_ element: AXUIElement, depth: Int, cells: inout [AXUIElement], panelOpen: inout Bool) {
        guard depth < 12 else { return }
        let identifier = AX.identifier(element) ?? ""
        if identifier == "AXNotificationListItems" || identifier == "widget-editor-button" { panelOpen = true }
        if let subrole = AX.subrole(element), subrole.hasPrefix("AXNotificationCenter") {
            cells.append(element)
            return
        }
        for child in AX.children(element) { collect(child, depth: depth + 1, cells: &cells, panelOpen: &panelOpen) }
    }

    private func parse(_ cell: AXUIElement) -> MirroredNotification? {
        let subrole = AX.subrole(cell) ?? ""
        let description = AX.string(cell, kAXDescriptionAttribute as String) ?? ""
        var title = "", body = ""
        var extras: [String] = []
        for child in AX.children(cell) where AX.role(child) == (kAXStaticTextRole as String) {
            let value = AX.string(child, kAXValueAttribute as String) ?? ""
            switch AX.identifier(child) {
            case "title": title = value
            case "body": body = value
            default: if !value.isEmpty { extras.append(value) }
            }
        }
        if title.isEmpty && body.isEmpty {
            // Older layouts: texts without identifiers, possibly nested.
            let texts = AX.texts(in: cell, maxDepth: 7, limit: 6)
            title = texts.first ?? ""
            body = texts.dropFirst().joined(separator: " ")
        }
        if title.isEmpty && body.isEmpty && !description.isEmpty {
            let parts = description.components(separatedBy: ", ")
            title = parts.dropFirst().first ?? ""
            body = parts.dropFirst(2).joined(separator: ", ")
        }
        guard !title.isEmpty || !body.isEmpty else { return nil }

        // The description reads "App, Title, Body".
        var appName = ""
        if !title.isEmpty, let range = description.range(of: ", " + title) {
            appName = String(description[..<range.lowerBound])
        } else if let comma = description.range(of: ", ") {
            appName = String(description[..<comma.lowerBound])
        }
        if body.isEmpty { body = title; title = "" }
        let fromIPhone = description.localizedCaseInsensitiveContains("iPhone")
        appName = appName.replacingOccurrences(of: " (iPhone)", with: "").trimmingCharacters(in: .whitespaces)
        if appName.isEmpty { appName = "Notification" }

        return MirroredNotification(id: UUID(), appName: appName, title: title, body: body, date: Date(),
                                    isFromIPhone: fromIPhone, bundleID: Self.bundleID(forAppNamed: appName),
                                    centerID: AX.identifier(cell), isStack: subrole.contains("Stack"),
                                    timeLabel: extras.last, actions: Self.actionNames(cell))
    }

    fileprivate static func actionNames(_ element: AXUIElement) -> [String] {
        var list: CFArray?
        guard AXUIElementCopyActionNames(element, &list) == .success, let actions = list as? [String] else { return [] }
        return actions.map { raw in raw.hasPrefix("Name:") ? String(raw.split(separator: "\n").first?.dropFirst(5) ?? "") : raw }
    }

    private func isMuted(_ appName: String) -> Bool {
        Defaults[.mutedNotificationApps].contains { $0.caseInsensitiveCompare(appName) == .orderedSame }
    }

    /// A banner just appeared.
    private func deliver(_ note: MirroredNotification, silently: Bool) {
        if let id = note.centerID {
            guard !seenCenterIDs.contains(id) else { return }
            seenCenterIDs.insert(id)
        } else {
            let signature = [note.appName, note.title, note.body].joined(separator: "|")
            guard seenSignatures[signature] == nil else { return }
            seenSignatures[signature] = Date()
        }
        guard !silently, !isMuted(note.appName) else { return }

        withAnimation(.smooth) { recent.insert(note, at: 0) }
        if recent.count > 60 { recent.removeLast(recent.count - 60) }

        let isOrder = Defaults[.orderTrackingEnabled] && OrderTracker.shared.ingest(note)
        if Defaults[.notificationsOnlyFromIPhone] && !note.isFromIPhone && !isOrder { return }
        IslandActivityHub.shared.showBanner(IslandBanner(
            appName: note.appName, bundleID: note.bundleID, title: note.title, body: note.body,
            isFromIPhone: note.isFromIPhone,
            symbol: isOrder ? OrderTracker.shared.symbol(forAppNamed: note.appName) : (note.isFromIPhone ? "iphone.gen3" : "bell.fill"),
            notificationID: note.id))
    }

    /// The Notification Center panel is open: mirror exactly what it shows.
    private func sync(with notes: [MirroredNotification]) {
        var merged: [MirroredNotification] = []
        var present = Set<String>()
        for var note in notes {
            guard let id = note.centerID, !dismissedCenterIDs.contains(id), !isMuted(note.appName) else { continue }
            if let existing = recent.first(where: { $0.centerID == id }) {
                note = MirroredNotification(id: existing.id, appName: note.appName, title: note.title, body: note.body,
                                            date: existing.date, isFromIPhone: existing.isFromIPhone || note.isFromIPhone,
                                            bundleID: note.bundleID ?? existing.bundleID, centerID: id,
                                            isStack: note.isStack, timeLabel: note.timeLabel,
                                            isRead: existing.isRead, actions: note.actions.isEmpty ? existing.actions : note.actions)
            }
            seenCenterIDs.insert(id)
            present.insert(id)
            merged.append(note)
        }
        // The panel builds long lists lazily — only trust "it's gone" for short lists.
        let mayBeTruncated = notes.count >= 14
        for item in recent where !(item.centerID.map(present.contains) ?? false) {
            if mayBeTruncated || item.centerID == nil { merged.append(item) }
        }
        if merged != recent { withAnimation(.smooth) { recent = merged } }
        lastSynced = Date()
    }

    // MARK: Clearing

    /// Clears one notification here and in Notification Center.
    func dismiss(_ note: MirroredNotification) {
        withAnimation(.smooth) { recent.removeAll { $0.id == note.id } }
        guard let id = note.centerID else { return }
        dismissedCenterIDs.insert(id)
        if Defaults[.clearNotificationsInCenter] { NotificationCenterControl.clear(ids: [id]) }
    }

    /// Clears everything here and in Notification Center.
    func clearAll() {
        dismissedCenterIDs.formUnion(recent.compactMap(\.centerID))
        withAnimation(.smooth) { recent.removeAll() }
        if Defaults[.clearNotificationsInCenter] { NotificationCenterControl.clearAll() }
    }

    func clearRecent() { clearAll() }

    /// Clears every notification from the same app (here and in Notification Center).
    func clearApp(of note: MirroredNotification) {
        let same = recent.filter { $0.appName.caseInsensitiveCompare(note.appName) == .orderedSame }
        let ids = same.compactMap(\.centerID)
        dismissedCenterIDs.formUnion(ids)
        withAnimation(.smooth) { recent.removeAll { item in same.contains { $0.id == item.id } } }
        if Defaults[.clearNotificationsInCenter], !ids.isEmpty { NotificationCenterControl.clear(ids: ids) }
    }

    /// Read / unread. "Read" is also done in Notification Center when the app supports it (Messages…).
    func setRead(_ note: MirroredNotification, _ read: Bool) {
        guard let index = recent.firstIndex(where: { $0.id == note.id }) else { return }
        withAnimation(.smooth) { recent[index].isRead = read }
        if read, let id = note.centerID, note.supports("Mark as Read") {
            NotificationCenterControl.perform(["Mark as Read"], on: [id])
        }
    }

    func markAllRead() {
        let ids = recent.filter { !$0.isRead && $0.supports("Mark as Read") }.compactMap(\.centerID)
        withAnimation(.smooth) { for index in recent.indices { recent[index].isRead = true } }
        if !ids.isEmpty { NotificationCenterControl.perform(["Mark as Read"], on: ids) }
    }

    /// Opens what the notification is about (the Messages conversation, the app…).
    func open(_ note: MirroredNotification) {
        if let index = recent.firstIndex(where: { $0.id == note.id }) { recent[index].isRead = true }
        NotificationCenterControl.open(note)
    }

    /// Stops showing this app's notifications in the island (Settings › iPhone & Notifications to undo).
    func mute(_ note: MirroredNotification) {
        var muted = Defaults[.mutedNotificationApps]
        if !muted.contains(where: { $0.caseInsensitiveCompare(note.appName) == .orderedSame }) { muted.append(note.appName) }
        Defaults[.mutedNotificationApps] = muted
        withAnimation(.smooth) { recent.removeAll { $0.appName.caseInsensitiveCompare(note.appName) == .orderedSame } }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Reading helpers

    /// A one-time code (OTP / verification code) in the message, if there is one.
    static func oneTimeCode(in text: String) -> String? {
        let lower = text.lowercased()
        let hints = ["otp", "code", "verif", "passcode", "password", "pin", "one time", "one-time", "2fa", "login", "sign in", "authenticat"]
        guard hints.contains(where: { lower.contains($0) }),
              let regex = try? NSRegularExpression(pattern: "(?<![\\d.,₹$*xX/-])\\d{4,8}(?![\\d.,/-])") else { return nil }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let code = String(text[range])
            let before = text[..<range.lowerBound].suffix(5).lowercased()
            if before.contains("rs") || before.contains("inr") || before.contains("₹") || before.contains("a/c") { continue }
            if code.count == 4, let year = Int(code), (1990...2100).contains(year) { continue }
            return code
        }
        return nil
    }

    static func firstLink(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.url
    }

    func focus(_ id: UUID?) { focusedID = id }

    /// Loads what's in Notification Center (opens its panel for a moment).
    func syncNow() { NotificationCenterControl.sync() }

    /// First time the Notifications tab shows in this session: load Notification Center's list.
    func syncIfNeeded() {
        guard isActive, !syncedThisSession else { return }
        syncedThisSession = true
        syncNow()
    }

    /// Diagnostics: the current Notification Center accessibility tree (no text content).
    func dumpTree() -> String {
        guard let appElement else { return "Notification Center not attached (Accessibility off?)" }
        var out = ""
        AX.dump(appElement, maxDepth: 4, into: &out)
        return out
    }

    private static var bundleCache: [String: String?] = [:]

    static func bundleID(forAppNamed name: String) -> String? {
        if let cached = bundleCache[name] { return cached }
        var result: String?
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) {
            result = app.bundleIdentifier
        } else {
            for dir in ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"] {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".app")
                if let bundle = Bundle(url: url), let id = bundle.bundleIdentifier { result = id; break }
            }
        }
        bundleCache[name] = result
        return result
    }
}

/// Weak box handed to the C callback.
final class NotificationMirrorRef {
    weak var mirror: NotificationMirror?
    init(_ mirror: NotificationMirror) { self.mirror = mirror }
}

// MARK: - Driving Notification Center (sync / clear)

/// Opens the Notification Center panel for a moment (via the menu bar clock), does the
/// work through its accessibility actions, and puts it away again. Jobs run one at a time.
@MainActor
enum NotificationCenterControl {
    private static var jobs: [() async -> Void] = []
    private static var running = false

    static func clear(ids: [String]) {
        perform(["Close", "Clear All", "Clear"], on: ids)
    }

    /// Runs Notification Center actions ("Mark as Read", "Close"…) on these notifications.
    static func perform(_ actionNames: [String], on ids: [String]) {
        enqueue {
            await withPanel { app in
                for id in ids {
                    guard let cell = cells(in: app).first(where: { AX.identifier($0) == id }) else { continue }
                    _ = perform(cell, anyOf: actionNames)
                    try? await Task.sleep(for: .milliseconds(160))
                }
            }
        }
    }

    /// Opens what a notification is about (Notification Center's own "open"), else its app.
    static func open(_ note: MirroredNotification) {
        enqueue {
            var opened = false
            if let id = note.centerID {
                await withPanel { app in
                    if let cell = cells(in: app).first(where: { AX.identifier($0) == id }) {
                        opened = perform(cell, anyOf: ["Show", "AXPress"])
                    }
                }
            }
            if !opened, let bundleID = note.bundleID ?? NotificationMirror.bundleID(forAppNamed: note.appName),
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }

    static func clearAll() {
        enqueue {
            await withPanel { app in
                // A section-wide "Clear All" button first, then whatever is left one by one.
                for _ in 0..<3 {
                    guard let button = buttons(in: app).first(where: {
                        (AX.string($0, kAXDescriptionAttribute as String) ?? "").localizedCaseInsensitiveContains("Clear All")
                    }) else { break }
                    AX.press(button)
                    try? await Task.sleep(for: .milliseconds(250))
                }
                for _ in 0..<80 {
                    guard let cell = cells(in: app).first else { break }
                    guard perform(cell, anyOf: ["Clear All", "Close", "Clear"]) else { break }
                    try? await Task.sleep(for: .milliseconds(140))
                }
            }
        }
    }

    static func sync() {
        enqueue {
            NotificationMirror.shared.isSyncing = true
            await withPanel { _ in NotificationMirror.shared.scanNow() }
            NotificationMirror.shared.isSyncing = false
        }
    }

    private static func enqueue(_ job: @escaping () async -> Void) {
        jobs.append(job)
        guard !running else { return }
        running = true
        Task { @MainActor in
            while !jobs.isEmpty {
                let next = jobs.removeFirst()
                await next()
            }
            running = false
        }
    }

    private static func withPanel(_ body: (AXUIElement) async -> Void) async {
        guard AXIsProcessTrusted(),
              let nc = NSRunningApplication.runningApplications(withBundleIdentifier: NotificationMirror.ncBundleID).first else { return }
        let app = AX.app(pid: nc.processIdentifier)
        IslandInteractionLock.shared.automationActive = true
        defer {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                IslandInteractionLock.shared.automationActive = false
            }
        }
        let wasOpen = panelIsOpen(app)
        var clock: AXUIElement?
        if !wasOpen {
            guard let item = clockItem() else { return }
            clock = item
            AX.press(item)
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(70))
                if panelIsOpen(app) { break }
            }
            try? await Task.sleep(for: .milliseconds(180)) // let the list fill in
        }
        await body(app)
        if !wasOpen, let clock {
            try? await Task.sleep(for: .milliseconds(150))
            // Put it away again — unless it closed by itself (opening a notification does that).
            if panelIsOpen(app) { AX.press(clock) }
        }
    }

    private static func clockItem() -> AXUIElement? {
        guard let cc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first else { return nil }
        let app = AX.app(pid: cc.processIdentifier)
        for bar in AX.elements(app, "AXExtrasMenuBar") {
            for item in AX.children(bar) where (AX.identifier(item) ?? "").localizedCaseInsensitiveContains("clock") {
                return item
            }
        }
        return nil
    }

    private static func panelIsOpen(_ app: AXUIElement) -> Bool {
        func find(_ element: AXUIElement, _ depth: Int) -> Bool {
            guard depth < 7 else { return false }
            let id = AX.identifier(element) ?? ""
            if id == "AXNotificationListItems" || id == "widget-editor-button" { return true }
            return AX.children(element).contains { find($0, depth + 1) }
        }
        return AX.elements(app, kAXWindowsAttribute as String).contains { find($0, 0) }
    }

    private static func cells(in app: AXUIElement) -> [AXUIElement] {
        var out: [AXUIElement] = []
        func walk(_ element: AXUIElement, _ depth: Int) {
            guard depth < 12 else { return }
            if let subrole = AX.subrole(element), subrole.hasPrefix("AXNotificationCenter") {
                out.append(element)
                return
            }
            for child in AX.children(element) { walk(child, depth + 1) }
        }
        for window in AX.elements(app, kAXWindowsAttribute as String) { walk(window, 0) }
        return out
    }

    private static func buttons(in app: AXUIElement) -> [AXUIElement] {
        var out: [AXUIElement] = []
        func walk(_ element: AXUIElement, _ depth: Int) {
            guard depth < 8 else { return }
            if AX.role(element) == (kAXButtonRole as String) { out.append(element) }
            for child in AX.children(element) { walk(child, depth + 1) }
        }
        for window in AX.elements(app, kAXWindowsAttribute as String) { walk(window, 0) }
        return out
    }

    /// Runs a (possibly custom) accessibility action such as "Close" or "Clear All".
    private static func perform(_ element: AXUIElement, anyOf names: [String]) -> Bool {
        var list: CFArray?
        guard AXUIElementCopyActionNames(element, &list) == .success, let actions = list as? [String] else { return false }
        for wanted in names {
            for raw in actions {
                let name = raw.hasPrefix("Name:") ? String(raw.split(separator: "\n").first?.dropFirst(5) ?? "") : raw
                if name.caseInsensitiveCompare(wanted) == .orderedSame {
                    return AXUIElementPerformAction(element, raw as CFString) == .success
                }
            }
        }
        return false
    }
}
