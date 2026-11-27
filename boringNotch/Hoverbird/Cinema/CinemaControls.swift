//
//  CinemaControls.swift
//  Hoverbird
//
//  Player controls for streaming services. Netflix, Prime Video and most web players
//  ignore macOS Now Playing seek / mute / skip commands, so the island uses each
//  player's own keyboard shortcuts — sent to that app only, so they also work while it
//  is in the background — and presses on-screen buttons such as "Skip Intro" through
//  Accessibility, like a click would.
//
//  Shortcuts used (Netflix and Prime Video share them): ← / → 10 s, M mute, F full screen.
//  Netflix also skips the intro with S.
//

import AppKit
import ApplicationServices

@MainActor
enum CinemaControls {
    private enum Key: CGKeyCode {
        case left = 123, right = 124, m = 46, s = 1, f = 3
    }

    struct Target {
        let bundleID: String
        let pid: pid_t
        /// A browser or Safari web app: the page handles the keys.
        let isWeb: Bool
    }

    enum SkipResult { case pressed(String), sentShortcut, nothing }

    private static var lastAction: [String: Date] = [:]

    /// The app playing right now.
    static var target: Target? {
        if CinemaTheater.shared.isOpen {
            // The Theater is Hoverbird's own window: keys go to its page.
            CinemaTheater.shared.focusPage()
            return Target(bundleID: Bundle.main.bundleIdentifier ?? "", pid: getpid(), isWeb: true)
        }
        guard let id = MusicManager.shared.bundleIdentifier, !id.isEmpty,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { return nil }
        let web = OTTDetector.isBrowser(id) || id.hasPrefix("com.apple.Safari.WebApp")
        return Target(bundleID: id, pid: app.processIdentifier, isWeb: web)
    }

    /// Accessibility is what lets the island send keys and press buttons.
    static var canControl: Bool { AXIsProcessTrusted() }

    /// One press = one action, even if a click bounces.
    private static func allow(_ name: String, every interval: TimeInterval = 0.12) -> Bool {
        let now = Date()
        if let last = lastAction[name], now.timeIntervalSince(last) < interval { return false }
        lastAction[name] = now
        return true
    }

    // MARK: Actions

    /// 10 seconds back or forward.
    @discardableResult
    static func seek(forward: Bool) -> Bool {
        guard allow("seek"), canControl, let target else { return false }
        let sent = send(forward ? .right : .left, to: target.pid, arrow: true)
        // The island's time follows right away (Netflix's arrow keys move 10 s).
        if sent { CinemaNowPlaying.shared.seeked(by: forward ? 10 : -10) }
        return sent
    }

    @discardableResult
    static func toggleMute() -> Bool {
        guard allow("mute", every: 0.3), canControl, let target else { return false }
        return send(.m, to: target.pid)
    }

    /// The player's own full screen (web players), or the window's (apps).
    @discardableResult
    static func toggleFullScreen() -> Bool {
        guard allow("full", every: 0.6) else { return false }
        if CinemaTheater.shared.isOpen {
            CinemaTheater.shared.close()
            return true
        }
        guard canControl, let target else { return false }
        if target.isWeb { return send(.f, to: target.pid) }
        let app = AX.app(pid: target.pid)
        guard let value = AX.attribute(app, kAXMainWindowAttribute as String),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return send(.f, to: target.pid) }
        let window = value as! AXUIElement
        let isFull = (AX.attribute(window, "AXFullScreen") as? Bool) == true
        return AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, (!isFull) as CFBoolean) == .success
    }

    /// Presses "Skip Intro" / "Skip Recap" / "Next Episode" when the player shows one.
    static func skip() async -> SkipResult {
        guard allow("skip", every: 0.8) else { return .nothing }
        if CinemaTheater.shared.isOpen {
            if let label = await CinemaTheater.shared.skip() { return .pressed(label) }
            return .nothing
        }
        guard canControl, let target else { return .nothing }
        let pid = target.pid
        let isNetflix = LiveVideoManager.shared.ottPlatform?.name == "Netflix"
        let found = await Task.detached(priority: .userInitiated) { () -> Found? in
            let found = findSkipButton(pid: pid)
            if let found { AX.press(found.element) }
            return found
        }.value
        if let found { return .pressed(found.label) }
        if isNetflix {
            // Netflix's own shortcut (does nothing when there's no intro on screen).
            send(.s, to: pid)
            return .sentShortcut
        }
        return .nothing
    }

    // MARK: Keys

    @discardableResult
    nonisolated private static func send(_ key: Key, to pid: pid_t, arrow: Bool = false) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key.rawValue, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key.rawValue, keyDown: false) else { return false }
        // Real arrow keys carry these flags; without them some players ignore the event.
        let flags: CGEventFlags = arrow ? [.maskSecondaryFn, .maskNumericPad] : []
        down.flags = flags
        up.flags = flags
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }

    // MARK: Skip button search (off the main thread)

    private struct Found: @unchecked Sendable {
        let element: AXUIElement
        let label: String
    }

    /// Breadth-first through the player's windows, with a node and time budget so a huge
    /// page can never stall: the skip button sits near the top of the player.
    nonisolated private static func findSkipButton(pid: pid_t) -> Found? {
        // Never our own process (the Theater uses JavaScript instead): WebKit's views may only
        // be read on the main thread, and our own "Skip" button would match.
        guard pid != getpid() else { return nil }
        let app = AX.app(pid: pid)
        var roots: [AXUIElement] = []
        for name in [kAXFocusedWindowAttribute as String, kAXMainWindowAttribute as String] {
            if let value = AX.attribute(app, name), CFGetTypeID(value) == AXUIElementGetTypeID() {
                roots.append(value as! AXUIElement)
            }
        }
        roots += AX.elements(app, kAXWindowsAttribute as String)
        let deadline = Date().addingTimeInterval(1.5)
        var queue = roots
        var index = 0
        var visited = 0
        while index < queue.count, visited < 4000, Date() < deadline {
            let element = queue[index]
            index += 1
            visited += 1
            let role = AX.role(element) ?? ""
            if role == (kAXButtonRole as String) || role == "AXLink" {
                if let label = buttonLabel(element), isSkipLabel(label) {
                    return Found(element: element, label: label)
                }
                continue
            }
            queue += AX.children(element)
        }
        return nil
    }

    nonisolated private static func buttonLabel(_ element: AXUIElement) -> String? {
        if let label = AX.label(element) { return label }
        return AX.texts(in: element, maxDepth: 3, limit: 2).first
    }

    nonisolated static func isSkipLabel(_ raw: String) -> Bool {
        let label = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Seek buttons ("Skip back 10 seconds") are not what we want.
        for word in ["back", "forward", "second", "rewind"] where label.contains(word) { return false }
        return label.hasPrefix("skip") || label.hasPrefix("next episode") || label.hasPrefix("next ep")
    }
}
