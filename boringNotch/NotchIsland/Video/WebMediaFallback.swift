//
//  WebMediaFallback.swift
//  NotchIsland
//
//  Many web players (YouTube single videos, especially in Safari web apps) don't
//  register "next/previous track" with macOS Now Playing, so the system command
//  is ignored. When that happens, press the player's own Next/Previous button
//  through Accessibility, or send YouTube's keyboard shortcut to that app.
//

import AppKit
import ApplicationServices

enum WebMediaFallback {
    enum Direction { case next, previous }

    private static var buttonCache: [String: AXUIElement] = [:]
    private static let cacheLock = NSLock()

    /// Returns true if something was triggered.
    @discardableResult
    static func perform(_ direction: Direction, bundleID: String, isYouTube: Bool = false) -> Bool {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return false }
        let pid = app.processIdentifier
        // YouTube (in any browser or as a web app): its own shortcuts are instant and reliable.
        if isYouTube || (app.localizedName ?? "").localizedCaseInsensitiveContains("youtube") {
            if direction == .next { return sendShortcut(.next, pid: pid) }
            // Previous video = one page back (also correct inside playlists).
            if goBack(pid: pid) { return true }
            return sendShortcut(.previous, pid: pid)
        }
        // Other players: reuse the button we found last time (one IPC), else search once.
        let key = "\(pid)|\(direction == .next ? "next" : "prev")"
        if let cached = cacheLock.withLock({ buttonCache[key] }) {
            if AXUIElementPerformAction(cached, kAXPressAction as CFString) == .success { return true }
            cacheLock.withLock { buttonCache[key] = nil }
        }
        if let button = findPlayerButton(direction, pid: pid) {
            cacheLock.withLock { buttonCache[key] = button }
            if AXUIElementPerformAction(button, kAXPressAction as CFString) == .success { return true }
        }
        switch direction {
        case .next:
            return sendShortcut(direction, pid: app.processIdentifier)
        case .previous:
            if goBack(pid: pid) { return true }
            return sendShortcut(.previous, pid: pid)
        }
    }

    /// Browser "Back": the app's History › Back menu item (works in the background and from
    /// other Spaces), else the window's Back toolbar button, else ⌘[.
    static func goBack(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        // The window's own Back button — reachable through AXMainWindow even when the
        // window is on another desktop, and pressable without bringing the app forward.
        for window in reachableWindows(app) {
            if let back = findToolbarButton(in: window, identifier: "BackButton", labels: ["go back", "back"]),
               AXUIElementPerformAction(back, kAXPressAction as CFString) == .success {
                return true
            }
        }
        for barItem in AX.elements(app, kAXMenuBarAttribute as String).flatMap({ AX.children($0) }) {
            for menu in AX.children(barItem) {
                for item in AX.children(menu) {
                    let title = (AX.string(item, kAXTitleAttribute as String) ?? "").lowercased()
                    let identifier = (AX.identifier(item) ?? "").lowercased()
                    let enabled = (AX.attribute(item, kAXEnabledAttribute as String) as? Bool) ?? true
                    if title == "back" || identifier.contains("goback"), enabled,
                       AXUIElementPerformAction(item, kAXPressAction as CFString) == .success {
                        return true
                    }
                }
            }
        }
        for window in reachableWindows(app) {
            if let back = findButton(in: window, labels: ["back", "go back"]),
               AXUIElementPerformAction(back, kAXPressAction as CFString) == .success {
                return true
            }
        }
        return sendKey(33, flags: .maskCommand, pid: pid)
    }

    /// AXWindows only lists windows on the current desktop; main/focused window work everywhere.
    static func reachableWindows(_ app: AXUIElement) -> [AXUIElement] {
        var result = AX.elements(app, kAXMainWindowAttribute as String)
        result += AX.elements(app, kAXFocusedWindowAttribute as String)
        result += AX.elements(app, kAXWindowsAttribute as String)
        return result
    }

    private static func findToolbarButton(in window: AXUIElement, identifier: String, labels: [String]) -> AXUIElement? {
        for toolbar in AX.children(window) where AX.role(toolbar) == (kAXToolbarRole as String) {
            if let hit = findButton(in: toolbar, labels: labels, identifier: identifier, maxDepth: 4) { return hit }
        }
        return findButton(in: window, labels: labels, identifier: identifier, maxDepth: 3)
    }

    /// Shallow search (toolbars live near the top of the window's tree).
    private static func findButton(in root: AXUIElement, labels: [String], identifier: String? = nil, maxDepth: Int = 5) -> AXUIElement? {
        func walk(_ e: AXUIElement, _ depth: Int) -> AXUIElement? {
            guard depth <= maxDepth else { return nil }
            if AX.role(e) == (kAXButtonRole as String) {
                if let identifier, AX.identifier(e) == identifier { return e }
                let label = (AX.label(e) ?? "").lowercased()
                if labels.contains(label) { return e }
            }
            if AX.role(e) == "AXWebArea" { return nil }
            for child in AX.children(e) { if let hit = walk(child, depth + 1) { return hit } }
            return nil
        }
        return walk(root, 0)
    }

    /// True if the app has a normal window on the current Space (so activating it won't switch Spaces).
    static func hasWindowOnCurrentSpace(pid: pid_t) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return list.contains { info in
            (info[kCGWindowOwnerPID as String] as? Int32) == pid && (info[kCGWindowLayer as String] as? Int) == 0
        }
    }

    /// Real browser Back for a background app: bring it forward for a moment, press
    /// Go › Back (enabled while active), then hand focus back. Never switches Spaces.
    @MainActor
    static func backViaQuickActivation(bundleID: String) async -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              hasWindowOnCurrentSpace(pid: app.processIdentifier) else { return false }
        let previous = NSWorkspace.shared.frontmostApplication
        app.activate()
        for _ in 0..<15 where !app.isActive { try? await Task.sleep(for: .milliseconds(20)) }
        let pid = app.processIdentifier
        let ok = await Task.detached { goBack(pid: pid) }.value
        try? await Task.sleep(for: .milliseconds(90))
        if let previous, previous.processIdentifier != app.processIdentifier { previous.activate() }
        return ok
    }

    /// Fresh playback position straight from the adapter (not an extrapolated estimate).
    static func currentPosition() -> Double? {
        guard let scriptURL = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let frameworkPath = Bundle.main.privateFrameworksPath?.appending("/MediaRemoteAdapter.framework") else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, frameworkPath, "get", "--now"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (json["elapsedTimeNow"] as? Double) ?? (json["elapsedTime"] as? Double)
    }

    /// Restart a YouTube video reliably: "0" (+ flush), verify with fresh state, retry.
    /// If YouTube is on this desktop, a split-second focus switch makes it certain.
    @MainActor
    static func restartYouTube(bundleID: String) async -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return false }
        let pid = app.processIdentifier
        if hasWindowOnCurrentSpace(pid: pid) {
            let previous = NSWorkspace.shared.frontmostApplication
            app.activate()
            for _ in 0..<12 where !app.isActive { try? await Task.sleep(for: .milliseconds(15)) }
            _ = sendKey(29, flags: [], pid: pid)
            flush(pid: pid)
            try? await Task.sleep(for: .milliseconds(60))
            if let previous, previous.processIdentifier != pid { previous.activate() }
            return true
        }
        for attempt in 0..<3 {
            _ = sendKey(29, flags: [], pid: pid)
            flush(pid: pid)
            try? await Task.sleep(for: .milliseconds(attempt == 0 ? 450 : 350))
            let position = await Task.detached { currentPosition() }.value
            if let position, position < 3 { return true }
        }
        return false
    }

    /// A harmless Shift tap: background apps sometimes only handle the previous key once
    /// another event arrives.
    static func flush(pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: false)
        down?.flags = .maskShift
        up?.flags = []
        down?.postToPid(pid)
        up?.postToPid(pid)
    }

    /// YouTube seeking with its own keys (works in the background):
    /// 0 = start, 1…9 = 10…90 %, J / L = −/+10 s.
    static func seekYouTube(from current: Double, to target: Double, duration: Double, bundleID: String) -> Bool {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return false }
        let pid = app.processIdentifier
        let digitKeys: [CGKeyCode] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25] // 0…9
        if target < 1.5 {
            return sendKey(digitKeys[0], flags: [], pid: pid)
        }
        var position = current
        let delta = target - current
        if abs(delta) > 45, duration > 0 {
            // Big jump: nearest 10 % mark first.
            let tenth = max(0, min(9, Int((target / duration * 10).rounded(.down))))
            _ = sendKey(digitKeys[tenth], flags: [], pid: pid)
            position = Double(tenth) * duration / 10
        }
        let remaining = target - position
        let presses = min(6, Int((abs(remaining) + 2) / 10))
        let key: CGKeyCode = remaining > 0 ? 37 : 38 // L / J
        for _ in 0..<presses {
            _ = sendKey(key, flags: [], pid: pid)
            usleep(40_000)
        }
        return true
    }

    private static func sendKey(_ keyCode: CGKeyCode, flags: CGEventFlags, pid: pid_t) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return false }
        down.flags = flags
        up.flags = flags
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }

    private static let attributes = [kAXRoleAttribute, kAXDescriptionAttribute, kAXTitleAttribute,
                                     kAXChildrenAttribute, kAXEnabledAttribute] as CFArray

    private static func findPlayerButton(_ direction: Direction, pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let prefixes = direction == .next ? ["next", "skip to next", "play next"] : ["previous", "prev", "skip to previous"]

        var stack = reachableWindows(app)
        var visited = 0
        while let element = stack.popLast(), visited < 6000 {
            visited += 1
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
                  let list = values as? [Any], list.count == 5 else { continue }
            let role = list[0] as? String ?? ""
            let label = ((list[1] as? String ?? "") + " " + (list[2] as? String ?? "")).trimmingCharacters(in: .whitespaces).lowercased()
            if role == "AXButton" || role == "AXLink" {
                if prefixes.contains(where: { label.hasPrefix($0) }), (list[4] as? Bool) != false {
                    return element
                }
                continue
            }
            if ["AXStaticText", "AXImage", "AXTextField", "AXCheckBox"].contains(role) { continue }
            if let children = list[3] as? [AXUIElement] { stack.append(contentsOf: children.reversed()) }
        }
        return nil
    }

    /// YouTube: Shift+N = next video, Shift+P = previous video (playlists).
    private static func sendShortcut(_ direction: Direction, pid: pid_t) -> Bool {
        let keyCode: CGKeyCode = direction == .next ? 45 : 35 // "n" / "p"
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return false }
        down.flags = .maskShift
        up.flags = .maskShift
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }
}
