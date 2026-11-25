//
//  MacLock.swift
//  Hoverbird
//
//  🔒 Lock the Mac from the island: immediately, after a delay, or just put the
//  display to sleep / start the screen saver.
//

import AppKit
import SwiftUI

@MainActor
final class MacLock: ObservableObject {
    static let shared = MacLock()

    /// When a delayed lock is scheduled.
    @Published private(set) var scheduledLock: Date?
    private var lockTimer: Timer?

    static let delays: [Int] = [1, 5, 15, 30]

    func lockNow() {
        cancelScheduledLock()
        IslandPinState.shared.pinned = false
        NotificationCenter.default.post(name: .islandCloseAll, object: nil)
        // Let the island finish closing so it isn't frozen open on the lock screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { Self.lockScreen() }
    }

    func lock(afterMinutes minutes: Int) {
        cancelScheduledLock()
        let fire = Date().addingTimeInterval(TimeInterval(minutes * 60))
        scheduledLock = fire
        let timer = Timer(fire: fire, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { MacLock.shared.lockNow() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        lockTimer = timer
        IslandActivityHub.shared.showPill(.info(symbol: "lock.fill", text: "Locking in \(minutes) min", tint: .white), duration: 2.2)
    }

    func cancelScheduledLock() {
        lockTimer?.invalidate()
        lockTimer = nil
        if scheduledLock != nil { scheduledLock = nil }
    }

    func sleepDisplay() {
        NotificationCenter.default.post(name: .islandCloseAll, object: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        try? process.run()
    }

    func startScreenSaver() {
        NotificationCenter.default.post(name: .islandCloseAll, object: nil)
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// The same immediate lock as ⌃⌘Q.
    private static func lockScreen() {
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
           let symbol = dlsym(handle, "SACLockScreenImmediate") {
            typealias LockFn = @convention(c) () -> Int32
            _ = unsafeBitCast(symbol, to: LockFn.self)()
            return
        }
        // Fallback: press ⌃⌘Q (needs Accessibility).
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: false)
        down?.flags = [.maskControl, .maskCommand]
        up?.flags = [.maskControl, .maskCommand]
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
