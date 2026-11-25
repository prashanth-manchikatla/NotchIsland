//
//  IslandHeaderButtons.swift
//  NotchIsland
//
//  Header controls in the expanded island:
//   ☕️ Awake — click toggles; click-and-hold (or right-click) for timed options.
//   ⏱ Stopwatch — click starts/pauses; hold for lap, reset and timer presets.
//

import Defaults
import SwiftUI

// MARK: - Closure-backed NSMenu items

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, checked: Bool = false, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
        isEnabled = enabled
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { handler() }
}

@MainActor
enum IslandMenus {
    static func awakeMenu() -> NSMenu {
        let awake = AwakeManager.shared
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: awake.isActive ? "Awake · \(awake.remainingText)" : "Keep Awake", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(ClosureMenuItem("Indefinitely", symbol: "infinity", checked: awake.isActive && awake.endDate == nil) {
            awake.start(minutes: nil)
        })
        for preset in AwakeManager.presets {
            menu.addItem(ClosureMenuItem("For \(preset.label)", symbol: "clock") { awake.start(minutes: preset.minutes) })
        }
        let until = NSMenuItem(title: "Until…", action: nil, keyEquivalent: "")
        until.image = NSImage(systemSymbolName: "alarm", accessibilityDescription: nil)
        let untilMenu = NSMenu()
        for date in upcomingRoundTimes() {
            untilMenu.addItem(ClosureMenuItem(AwakeManager.timeFormatter.string(from: date)) { awake.start(until: date) })
        }
        until.submenu = untilMenu
        menu.addItem(until)
        if awake.isActive {
            menu.addItem(ClosureMenuItem("Add 30 minutes", symbol: "plus.circle") { awake.extend(minutes: 30) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Keep display on", checked: Defaults[.awakeKeepDisplayOn]) {
            Defaults[.awakeKeepDisplayOn].toggle()
        })
        menu.addItem(ClosureMenuItem("Stay awake with lid closed…", symbol: "laptopcomputer", checked: awake.lidClosedMode,
                                     enabled: !awake.isChangingLidMode) {
            Task { await awake.setLidClosedMode(!awake.lidClosedMode) }
        })
        if awake.isActive {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Turn Off", symbol: "power") { awake.stop() })
        }
        return menu
    }

    static func timerMenu() -> NSMenu {
        let timers = IslandTimerManager.shared
        // Whatever you pick, show it in the Timer tab instead of running it unseen.
        func go(_ action: @escaping () -> Void) -> () -> Void {
            return {
                action()
                withAnimation(.smooth) { BoringViewCoordinator.shared.currentView = .timers }
            }
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: "Start a Timer", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for minutes in IslandTimerManager.presets {
            menu.addItem(ClosureMenuItem(IslandTimerManager.durationLabel(minutes: minutes), symbol: "timer",
                                         handler: go { timers.startTimer(minutes: minutes) }))
        }
        if timers.timers.count > 0 {
            menu.addItem(ClosureMenuItem(timers.timers.count > 1 ? "Cancel All Timers" : "Cancel Timer", symbol: "xmark",
                                         handler: go { timers.cancelAllTimers() }))
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("New Stopwatch", symbol: "stopwatch", handler: go { timers.addStopwatch() }))
        if timers.isStopwatchActive {
            menu.addItem(ClosureMenuItem(timers.isStopwatchRunning ? "Pause Stopwatch" : "Resume Stopwatch", symbol: "playpause",
                                         handler: go { timers.togglePrimaryStopwatch() }))
            menu.addItem(ClosureMenuItem("Remove All Stopwatches", symbol: "trash", handler: go { timers.removeAllStopwatches() }))
        }
        return menu
    }

    static func lockMenu() -> NSMenu {
        let lock = MacLock.shared
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem("Lock Now", symbol: "lock.fill") { lock.lockNow() })
        for minutes in MacLock.delays {
            menu.addItem(ClosureMenuItem("Lock in \(minutes) min", symbol: "lock.rotation") { lock.lock(afterMinutes: minutes) })
        }
        if let date = lock.scheduledLock {
            menu.addItem(ClosureMenuItem("Cancel lock at \(AwakeManager.timeFormatter.string(from: date))", symbol: "xmark") {
                lock.cancelScheduledLock()
            })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Sleep Display", symbol: "moon.fill") { lock.sleepDisplay() })
        menu.addItem(ClosureMenuItem("Start Screen Saver", symbol: "sparkles.tv") { lock.startScreenSaver() })
        return menu
    }

    /// The next six whole hours (and the next half hour) for "Awake until…".
    static func upcomingRoundTimes(now: Date = Date()) -> [Date] {
        let cal = Calendar.current
        var dates: [Date] = []
        var comps = cal.dateComponents([.year, .month, .day, .hour], from: now)
        comps.minute = 30
        if let half = cal.date(from: comps), half > now.addingTimeInterval(600) { dates.append(half) }
        comps.minute = 0
        guard let thisHour = cal.date(from: comps) else { return dates }
        for h in 1...6 {
            if let d = cal.date(byAdding: .hour, value: h, to: thisHour) { dates.append(d) }
        }
        return dates.sorted()
    }

    static func popUp(_ menu: NSMenu) {
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

// MARK: - Header buttons

/// Small name tag shown under an icon while hovering (used by header buttons and tabs).
struct HoverNameTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.black.opacity(0.88)))
            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
            .fixedSize()
            .allowsHitTesting(false)
    }
}

struct HeaderCircleButton<Label: View>: View {
    var title: String? = nil
    let help: String
    let tap: () -> Void
    var menu: (() -> NSMenu)? = nil
    @ViewBuilder var label: () -> Label
    @State private var hovering = false
    @State private var suppressTap = false

    var body: some View {
        Capsule()
            .fill(Color.white.opacity(hovering ? 0.14 : 0.0001))
            .frame(width: 26, height: 28)
            .overlay { label() }
            .overlay(alignment: .bottom) {
                if hovering, let title {
                    HoverNameTag(text: title)
                        .offset(y: 17)
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .top)))
                }
            }
            .zIndex(hovering ? 5 : 0)
            .contentShape(Capsule())
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
            .onLongPressGesture(minimumDuration: 0.35) {
                guard let menu else { return }
                suppressTap = true
                IslandMenus.popUp(menu()) // blocks until the menu closes
                // The menu usually swallows the mouse-up; re-arm taps shortly after.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { suppressTap = false }
            }
            .simultaneousGesture(TapGesture().onEnded {
                if suppressTap { suppressTap = false } else { tap() }
            })
            .contextMenu {
                if menu != nil {
                    Button("Show options") { if let menu { IslandMenus.popUp(menu()) } }
                }
            }
            .help(help)
    }
}

struct AwakeHeaderButton: View {
    @ObservedObject private var awake = AwakeManager.shared

    var body: some View {
        HeaderCircleButton(
            title: "Coffee",
            help: awake.isActive ? "Keeping your Mac awake (\(awake.remainingText)) — click to stop, hold for options"
                                 : "Keep Mac awake — click to start, hold for timed options",
            tap: { awake.toggle() },
            menu: { IslandMenus.awakeMenu() }
        ) {
            Image(systemName: awake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                .foregroundStyle(awake.isActive ? .orange : .white)
                .imageScale(.medium)
                .symbolEffect(.bounce, value: awake.isActive)
        }
    }
}

struct TimerHeaderButton: View {
    @ObservedObject private var timers = IslandTimerManager.shared

    var body: some View {
        HeaderCircleButton(
            help: "Timer & stopwatch — click to open, hold for quick timers",
            tap: { withAnimation(.smooth) { BoringViewCoordinator.shared.currentView = .timers } },
            menu: { IslandMenus.timerMenu() }
        ) {
            Image(systemName: timers.isTimerActive ? "timer.circle.fill" : "timer")
                .foregroundStyle(timers.isStopwatchRunning || timers.isTimerActive ? .orange : .white)
                .imageScale(.medium)
        }
    }
}

struct LockHeaderButton: View {
    @ObservedObject private var lock = MacLock.shared

    var body: some View {
        HeaderCircleButton(
            title: "Lock",
            help: lock.scheduledLock == nil ? "Lock your Mac — hold for lock timer, display sleep, screen saver"
                                            : "Lock scheduled — hold to change or cancel",
            tap: { lock.lockNow() },
            menu: { IslandMenus.lockMenu() }
        ) {
            Image(systemName: lock.scheduledLock == nil ? "lock" : "lock.rotation")
                .foregroundStyle(lock.scheduledLock == nil ? .white : .orange)
                .imageScale(.medium)
        }
    }
}

struct CameraHeaderButton: View {
    @EnvironmentObject var vm: BoringViewModel

    var body: some View {
        HeaderCircleButton(title: "Camera", help: vm.isCameraExpanded ? "Turn the mirror off" : "Mirror (camera)", tap: { vm.toggleCameraPreview() }) {
            Image(systemName: vm.isCameraExpanded ? "web.camera.fill" : "web.camera")
                .foregroundStyle(vm.isCameraExpanded ? .green : .white)
                .imageScale(.medium)
        }
    }
}
