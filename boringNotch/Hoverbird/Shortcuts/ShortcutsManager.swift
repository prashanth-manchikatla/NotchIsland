//
//  ShortcutsManager.swift
//  Hoverbird
//
//  Your Shortcuts in the island. Shortcuts made on the iPhone sync to the Mac
//  through iCloud, and the Mac's `shortcuts` tool lists and runs them.
//  Some only work on a phone (Personal Hotspot, Water Lock, cellular…): when a
//  shortcut can't run on the Mac, it runs on your iPhone through iPhone Mirroring
//  — Hoverbird opens it, goes to the iPhone's Spotlight, types the shortcut's
//  name and runs it. Shortcuts that needed the iPhone once go there directly
//  next time.
//

import AppKit
import ApplicationServices
import Defaults
import SwiftUI

struct ShortcutItem: Identifiable, Equatable, Hashable {
    let id: String   // the shortcut's identifier
    let name: String
}

extension Defaults.Keys {
    /// Identifiers of shortcuts that run on the iPhone (through iPhone Mirroring).
    static let shortcutsOnIPhone = Key<[String]>("shortcutsOnIPhone", default: [])
}

@MainActor
final class ShortcutsManager: ObservableObject {
    static let shared = ShortcutsManager()

    enum RunState: Equatable {
        case running(onIPhone: Bool)
        case done(onIPhone: Bool)
        case failed(String)
    }

    @Published private(set) var shortcuts: [ShortcutItem] = []
    @Published private(set) var loaded = false
    @Published private(set) var loadError: String?
    @Published private(set) var states: [String: RunState] = [:]
    /// Shortcuts that run on the iPhone (remembered).
    @Published private(set) var iPhoneIDs: Set<String> = Set(Defaults[.shortcutsOnIPhone])
    private var lastRefresh: Date = .distantPast
    private var clearTasks: [String: Task<Void, Never>] = [:]

    func refreshIfNeeded() {
        if Date().timeIntervalSince(lastRefresh) > 45 { refresh() }
    }

    func refresh() {
        lastRefresh = Date()
        Task.detached(priority: .utility) {
            let result = Self.shortcutsTool(["list", "--show-identifiers"], timeout: 20)
            let items = Self.parseList(result.out)
            await MainActor.run {
                let manager = ShortcutsManager.shared
                manager.loaded = true
                if result.status == 0 {
                    manager.loadError = nil
                    if items != manager.shortcuts { withAnimation(.smooth) { manager.shortcuts = items } }
                } else {
                    manager.loadError = result.err.isEmpty ? "Couldn't read your shortcuts." : result.err
                }
            }
        }
    }

    nonisolated static func parseList(_ text: String) -> [ShortcutItem] {
        text.split(separator: "\n").compactMap { raw in
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            // "Name (UUID)" — the name itself may contain parentheses.
            if line.hasSuffix(")"), let open = line.range(of: " (", options: .backwards) {
                let id = String(line[open.upperBound..<line.index(before: line.endIndex)])
                if id.count >= 32 { return ShortcutItem(id: id, name: String(line[..<open.lowerBound])) }
            }
            return ShortcutItem(id: line, name: line)
        }
    }

    func runsOnIPhone(_ item: ShortcutItem) -> Bool { iPhoneIDs.contains(item.id) }

    func setRunsOnIPhone(_ item: ShortcutItem, _ enabled: Bool) {
        if enabled { iPhoneIDs.insert(item.id) } else { iPhoneIDs.remove(item.id) }
        Defaults[.shortcutsOnIPhone] = iPhoneIDs.sorted()
    }

    /// Tap: on the Mac, or on the iPhone if it needs the phone (remembered after the first failure).
    func run(_ item: ShortcutItem, forceMac: Bool = false, forceIPhone: Bool = false) {
        if case .running = states[item.id] { return }
        if forceIPhone || (!forceMac && runsOnIPhone(item)) {
            runOnIPhone(item)
            return
        }
        setState(item, .running(onIPhone: false))
        Task.detached(priority: .userInitiated) {
            let result = Self.shortcutsTool(["run", item.id], timeout: 180)
            await MainActor.run {
                let manager = ShortcutsManager.shared
                if result.status == 0 {
                    manager.setState(item, .done(onIPhone: false), clearAfter: 3)
                    IslandActivityHub.shared.showPill(.info(symbol: "checkmark.circle.fill", text: "Ran “\(item.name)”", tint: .green), duration: 2.2)
                } else if result.status == -2 {
                    manager.setState(item, .failed("Timed out"), clearAfter: 5)
                } else {
                    // Didn't work on the Mac (iPhone-only actions…): run it on the iPhone instead.
                    manager.setRunsOnIPhone(item, true)
                    IslandActivityHub.shared.showPill(.info(symbol: "iphone.gen3", text: "Not on Mac — running on iPhone…", tint: .cyan), duration: 2.6)
                    manager.runOnIPhone(item)
                }
            }
        }
    }

    func runOnIPhone(_ item: ShortcutItem) {
        setState(item, .running(onIPhone: true))
        Task { @MainActor in
            let outcome = await IPhoneMirroringRunner.run(shortcutNamed: item.name)
            switch outcome {
            case .sent:
                setState(item, .done(onIPhone: true), clearAfter: 4)
                IslandActivityHub.shared.showPill(.info(symbol: "iphone.gen3", text: "Ran “\(item.name)” on iPhone", tint: .cyan), duration: 2.6)
            case .unavailable(let reason):
                setState(item, .failed(reason), clearAfter: 6)
                IslandActivityHub.shared.showPill(.info(symbol: "exclamationmark.triangle.fill", text: reason, tint: .orange), duration: 4)
            }
        }
    }

    func openInShortcutsApp(_ item: ShortcutItem?) {
        if let item, let name = item.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: "shortcuts://open-shortcut?name=\(name)") {
            NSWorkspace.shared.open(url)
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func setState(_ item: ShortcutItem, _ state: RunState, clearAfter seconds: Double? = nil) {
        withAnimation(.smooth) { states[item.id] = state }
        clearTasks[item.id]?.cancel()
        guard let seconds else { return }
        clearTasks[item.id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) { _ = self?.states.removeValue(forKey: item.id) }
        }
    }

    // MARK: The `shortcuts` command-line tool

    private final class Box: @unchecked Sendable { var data = Data() }

    nonisolated static func shortcutsTool(_ arguments: [String], timeout: TimeInterval) -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let outBox = Box(), errBox = Box()
        let reading = DispatchGroup()
        do { try process.run() } catch { return (-1, "", error.localizedDescription) }
        reading.enter()
        DispatchQueue.global(qos: .utility).async { outBox.data = out.fileHandleForReading.readDataToEndOfFile(); reading.leave() }
        reading.enter()
        DispatchQueue.global(qos: .utility).async { errBox.data = err.fileHandleForReading.readDataToEndOfFile(); reading.leave() }
        if reading.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return (-2, "", "timed out")
        }
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: outBox.data, as: UTF8.self),
                String(decoding: errBox.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Looks

    static func symbol(for name: String) -> String {
        let n = name.lowercased()
        let table: [(String, String)] = [
            ("hotspot", "personalhotspot"), ("wifi", "wifi"), ("wi-fi", "wifi"), ("bluetooth", "antenna.radiowaves.left.and.right"),
            ("stolen", "lock.shield.fill"), ("security", "lock.shield.fill"), ("water", "drop.fill"), ("lock", "lock.fill"),
            ("office", "building.2.fill"), ("work", "briefcase.fill"), ("home", "house.fill"), ("order", "bag.fill"),
            ("swiggy", "takeoutbag.and.cup.and.straw.fill"), ("zomato", "takeoutbag.and.cup.and.straw.fill"), ("food", "fork.knife"),
            ("music", "music.note"), ("play", "play.fill"), ("timer", "timer"), ("alarm", "alarm.fill"), ("focus", "moon.fill"),
            ("sleep", "bed.double.fill"), ("light", "lightbulb.fill"), ("low power", "battery.25percent"), ("battery", "battery.75percent"),
            ("photo", "photo.fill"), ("camera", "camera.fill"), ("message", "message.fill"), ("call", "phone.fill"),
            ("mail", "envelope.fill"), ("note", "note.text"), ("remind", "checklist"), ("weather", "cloud.sun.fill"),
            ("car", "car.fill"), ("drive", "car.fill"), ("location", "location.fill"), ("translate", "character.bubble.fill"),
            ("screenshot", "camera.viewfinder"), ("volume", "speaker.wave.2.fill"), ("brightness", "sun.max.fill"),
            ("airplane", "airplane"), ("data", "antenna.radiowaves.left.and.right"), ("vpn", "network.badge.shield.half.filled"),
        ]
        return table.first { n.contains($0.0) }?.1 ?? "square.stack.3d.up.fill"
    }

    /// A stable Shortcuts-style colour per shortcut.
    static func color(for id: String) -> Color {
        let palette: [Color] = [
            Color(red: 0.96, green: 0.33, blue: 0.33), Color(red: 1.0, green: 0.58, blue: 0.2), Color(red: 0.98, green: 0.78, blue: 0.2),
            Color(red: 0.3, green: 0.8, blue: 0.45), Color(red: 0.2, green: 0.75, blue: 0.8), Color(red: 0.25, green: 0.55, blue: 1.0),
            Color(red: 0.45, green: 0.4, blue: 0.95), Color(red: 0.7, green: 0.42, blue: 0.95), Color(red: 0.95, green: 0.4, blue: 0.7),
        ]
        let sum = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return palette[sum % palette.count]
    }
}

// MARK: - iPhone Mirroring

/// Runs a shortcut on the iPhone: opens iPhone Mirroring, goes to the iPhone's
/// Spotlight, types the shortcut's name and runs the top result.
@MainActor
enum IPhoneMirroringRunner {
    enum Outcome { case sent, unavailable(String) }

    static let bundleID = "com.apple.ScreenContinuity"

    static func run(shortcutNamed name: String) async -> Outcome {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return .unavailable("iPhone Mirroring isn't available on this Mac")
        }
        guard AXIsProcessTrusted() else { return .unavailable("Allow Accessibility for Hoverbird to use iPhone Mirroring") }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)

        // Wait for the iPhone's screen (up to ~15 s while it connects).
        var app: NSRunningApplication?
        var alreadyUp = false
        for attempt in 0..<75 {
            app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
            if let app, windowReady(app) {
                alreadyUp = attempt == 0
                break
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard let app, windowReady(app) else {
            return .unavailable("iPhone Mirroring didn't connect — lock your iPhone and keep it nearby")
        }
        app.activate()
        try? await Task.sleep(for: .milliseconds(alreadyUp ? 350 : 1800))

        // Home Screen, then Spotlight (menu items if present, else ⌘1 / ⌘3).
        if !pressMenuItem(in: app, titled: "Home Screen") { keyStroke(0x12, flags: .maskCommand) }
        try? await Task.sleep(for: .milliseconds(700))
        if !pressMenuItem(in: app, titled: "Spotlight") { keyStroke(0x14, flags: .maskCommand) }
        try? await Task.sleep(for: .milliseconds(900))

        type(name)
        try? await Task.sleep(for: .milliseconds(1300))
        keyStroke(0x24) // Return runs the top result
        return .sent
    }

    private static func windowReady(_ app: NSRunningApplication) -> Bool {
        let element = AX.app(pid: app.processIdentifier)
        return AX.elements(element, kAXWindowsAttribute as String).contains { window in
            guard let size = AX.size(window) else { return false }
            return size.width >= 200 && size.height >= 300
        }
    }

    private static func pressMenuItem(in app: NSRunningApplication, titled title: String) -> Bool {
        let element = AX.app(pid: app.processIdentifier)
        func find(_ node: AXUIElement, _ depth: Int) -> AXUIElement? {
            guard depth < 5 else { return nil }
            if AX.role(node) == (kAXMenuItemRole as String),
               (AX.string(node, kAXTitleAttribute as String) ?? "").caseInsensitiveCompare(title) == .orderedSame {
                return node
            }
            for child in AX.children(node) { if let hit = find(child, depth + 1) { return hit } }
            return nil
        }
        for bar in AX.elements(element, kAXMenuBarAttribute as String) {
            if let item = find(bar, 0) {
                AX.press(item)
                return true
            }
        }
        return false
    }

    private static func keyStroke(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    /// Types with real key codes (US layout) — iPhone Mirroring forwards physical keys.
    private static func type(_ text: String) {
        for character in text {
            guard let (key, shifted) = keyMap[character] else { continue }
            keyStroke(key, flags: shifted ? .maskShift : [])
            usleep(14_000)
        }
    }

    private static let keyMap: [Character: (CGKeyCode, Bool)] = {
        var map: [Character: (CGKeyCode, Bool)] = [:]
        let letters: [(Character, CGKeyCode)] = [
            ("a", 0x00), ("s", 0x01), ("d", 0x02), ("f", 0x03), ("h", 0x04), ("g", 0x05), ("z", 0x06), ("x", 0x07),
            ("c", 0x08), ("v", 0x09), ("b", 0x0B), ("q", 0x0C), ("w", 0x0D), ("e", 0x0E), ("r", 0x0F), ("y", 0x10),
            ("t", 0x11), ("o", 0x1F), ("u", 0x20), ("i", 0x22), ("p", 0x23), ("l", 0x25), ("j", 0x26), ("k", 0x28),
            ("n", 0x2D), ("m", 0x2E),
        ]
        for (character, key) in letters {
            map[character] = (key, false)
            map[Character(character.uppercased())] = (key, true)
        }
        let digits: [(Character, CGKeyCode)] = [("1", 0x12), ("2", 0x13), ("3", 0x14), ("4", 0x15), ("6", 0x16),
                                                ("5", 0x17), ("9", 0x19), ("7", 0x1A), ("8", 0x1C), ("0", 0x1D)]
        for (character, key) in digits { map[character] = (key, false) }
        let shiftedDigits: [(Character, CGKeyCode)] = [("!", 0x12), ("@", 0x13), ("#", 0x14), ("$", 0x15), ("^", 0x16),
                                                       ("%", 0x17), ("(", 0x19), ("&", 0x1A), ("*", 0x1C), (")", 0x1D)]
        for (character, key) in shiftedDigits { map[character] = (key, true) }
        let symbols: [(Character, CGKeyCode, Bool)] = [
            (" ", 0x31, false), ("-", 0x1B, false), ("_", 0x1B, true), ("=", 0x18, false), ("+", 0x18, true),
            ("[", 0x21, false), ("{", 0x21, true), ("]", 0x1E, false), ("}", 0x1E, true), (";", 0x29, false),
            (":", 0x29, true), ("'", 0x27, false), ("’", 0x27, false), ("\"", 0x27, true), (",", 0x2B, false),
            ("<", 0x2B, true), (".", 0x2F, false), (">", 0x2F, true), ("/", 0x2C, false), ("?", 0x2C, true),
            ("\\", 0x2A, false), ("|", 0x2A, true), ("`", 0x32, false), ("~", 0x32, true),
        ]
        for (character, key, shifted) in symbols { map[character] = (key, shifted) }
        return map
    }()
}
