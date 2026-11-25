//
//  AwakeManager.swift
//  NotchIsland
//
//  "Keep Awake" (a.k.a. Caffeine): stops the Mac from idle-sleeping, either
//  indefinitely, for a duration, or until a time. Optional "lid closed" mode
//  disables sleep entirely via `pmset disablesleep` (needs an admin password),
//  with safety nets: automatic restore when Awake ends, a low-battery cutoff,
//  and crash recovery on next launch.
//

import AppKit
import Combine
import Defaults
import IOKit.pwr_mgt
import SwiftUI

@MainActor
final class AwakeManager: ObservableObject {
    static let shared = AwakeManager()

    enum Event: Equatable {
        case started(String)
        case ended(String)
    }

    @Published private(set) var isActive = false
    /// nil while active = indefinitely.
    @Published private(set) var endDate: Date?
    @Published private(set) var lidClosedMode = false
    @Published private(set) var isChangingLidMode = false
    /// Last on/off transition; drives the brief pill in the closed island.
    @Published private(set) var lastEvent: Event?
    @Published private(set) var lastEventDate: Date = .distantPast

    private var assertionID: IOPMAssertionID = 0
    private var hasAssertion = false
    private var endTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    static let presets: [(label: String, minutes: Int)] = [
        ("15 minutes", 15), ("30 minutes", 30), ("1 hour", 60),
        ("2 hours", 120), ("4 hours", 240), ("8 hours", 480),
    ]

    private init() {
        // Re-create the assertion if the "keep display on" preference changes mid-session.
        Defaults.publisher(.awakeKeepDisplayOn, options: [])
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isActive else { return }
                    self.releaseAssertion()
                    self.createAssertion()
                }
            }
            .store(in: &cancellables)

        // Low-battery safety net.
        BatteryStatusViewModel.shared.$levelBattery
            .combineLatest(BatteryStatusViewModel.shared.$isPluggedIn)
            .receive(on: RunLoop.main)
            .sink { [weak self] level, pluggedIn in
                guard let self, self.isActive, !pluggedIn, level > 0 else { return }
                let cutoff = Float(Defaults[.awakeLowBatteryCutoff])
                if cutoff > 0, level <= cutoff {
                    self.stop(reason: "Battery low — your Mac can sleep again")
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    /// Click on the cup: toggles indefinitely.
    func toggle() {
        if isActive { stop() } else { start(minutes: nil) }
    }

    /// Start (or retime) Awake. `minutes == nil` keeps the Mac awake until turned off.
    func start(minutes: Int?) {
        let end = minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) }
        start(until: end)
    }

    func start(until date: Date?) {
        if let date, date <= Date() { return }
        if !hasAssertion { createAssertion() }
        endDate = date
        isActive = true
        scheduleEnd()
        announce(.started(date.map { "Until \(Self.timeFormatter.string(from: $0))" } ?? "Keeping your Mac awake"))
        if Defaults[.awakeLidClosedDefault] && !lidClosedMode {
            Task { await setLidClosedMode(true) }
        }
    }

    func stop(reason: String = "Your Mac can sleep again") {
        guard isActive else { return }
        endTimer?.invalidate()
        endTimer = nil
        releaseAssertion()
        isActive = false
        endDate = nil
        announce(.ended(reason))
        if lidClosedMode {
            Task { await setLidClosedMode(false) }
        }
    }

    /// Adds time to a running timed session (or converts an indefinite one).
    func extend(minutes: Int) {
        let base = max(endDate ?? Date(), Date())
        start(until: base.addingTimeInterval(TimeInterval(minutes * 60)))
    }

    var remainingText: String {
        guard isActive else { return "Off" }
        guard let endDate else { return "On" }
        return Self.shortRemaining(until: endDate)
    }

    static func shortRemaining(until date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        if seconds >= 3600 {
            let h = seconds / 3600, m = (seconds % 3600) / 60
            return m == 0 ? "\(h)h" : "\(h)h \(m)m"
        }
        if seconds >= 60 { return "\((seconds + 59) / 60)m" }
        return "\(seconds)s"
    }

    // MARK: - Lid closed mode (pmset disablesleep)

    /// Keeps the Mac running with the lid shut, even on battery. Requires an admin password.
    func setLidClosedMode(_ enabled: Bool) async {
        guard !isChangingLidMode else { return }
        isChangingLidMode = true
        defer { isChangingLidMode = false }
        let ok = await Self.runPrivileged("/usr/bin/pmset -a disablesleep \(enabled ? 1 : 0)")
        if ok {
            lidClosedMode = enabled
            Defaults[.awakeLidSleepDisabledByUs] = enabled
            if enabled && !isActive { start(minutes: nil) }
        }
    }

    /// Called at launch: if a previous run left lid-sleep disabled, offer to restore it.
    func recoverLidSleepIfNeeded() {
        guard Defaults[.awakeLidSleepDisabledByUs], !isActive else { return }
        guard Self.isSleepDisabledBySystem() else {
            Defaults[.awakeLidSleepDisabledByUs] = false
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Let your Mac sleep with the lid closed again?"
        alert.informativeText = "NotchIsland's Awake turned off lid-close sleep in an earlier session, and it is still off. Restoring it needs your administrator password."
        alert.addButton(withTitle: "Restore Sleep")
        alert.addButton(withTitle: "Keep It Off")
        if alert.runModal() == .alertFirstButtonReturn {
            Task {
                if await Self.runPrivileged("/usr/bin/pmset -a disablesleep 0") {
                    Defaults[.awakeLidSleepDisabledByUs] = false
                }
            }
        }
    }

    /// Best-effort restore when the app quits.
    func prepareForTermination() {
        releaseAssertion()
        if lidClosedMode || Defaults[.awakeLidSleepDisabledByUs] {
            // Synchronous: we're quitting. The password prompt appears if needed.
            let script = NSAppleScript(source: "do shell script \"/usr/bin/pmset -a disablesleep 0\" with administrator privileges")
            var error: NSDictionary?
            if script?.executeAndReturnError(&error) != nil {
                Defaults[.awakeLidSleepDisabledByUs] = false
            }
        }
    }

    // MARK: - Internals

    private func createAssertion() {
        let type = (Defaults[.awakeKeepDisplayOn]
            ? kIOPMAssertionTypePreventUserIdleDisplaySleep
            : kIOPMAssertionTypePreventUserIdleSystemSleep) as CFString
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type, IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "NotchIsland Awake" as CFString, &id)
        if result == kIOReturnSuccess {
            assertionID = id
            hasAssertion = true
        }
    }

    private func releaseAssertion() {
        guard hasAssertion else { return }
        IOPMAssertionRelease(assertionID)
        hasAssertion = false
        assertionID = 0
    }

    private func scheduleEnd() {
        endTimer?.invalidate()
        endTimer = nil
        guard let endDate else { return }
        let timer = Timer(fire: endDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stop(reason: "Awake ended — your Mac can sleep again") }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        endTimer = timer
    }

    private func announce(_ event: Event) {
        lastEvent = event
        lastEventDate = Date()
    }

    private static func runPrivileged(_ command: String) async -> Bool {
        do {
            try await AppleScriptHelper.executeVoid("do shell script \"\(command)\" with administrator privileges")
            return true
        } catch {
            return false
        }
    }

    static func isSleepDisabledBySystem() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return output.split(separator: "\n").contains { line in
                line.contains("SleepDisabled") && line.trimmingCharacters(in: .whitespaces).hasSuffix("1")
            }
        } catch {
            return false
        }
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
}
