//
//  IslandTimerManager.swift
//  NotchIsland
//
//  iPhone-style countdown timers and stopwatches that live in the island —
//  as many of each as you like, all running side by side.
//  No polling: views redraw via TimelineView only while visible, and a single
//  one-shot Timer fires when the next countdown ends.
//

import AppKit
import Defaults
import SwiftUI

/// One countdown.
struct IslandCountdown: Identifiable, Equatable {
    let id = UUID()
    var label: String
    var total: TimeInterval
    /// Set while running.
    var endDate: Date?
    /// Set while paused.
    var pausedRemaining: TimeInterval?
    var isRinging = false
    var ringStarted: Date?

    var isRunning: Bool { endDate != nil }
    var isPaused: Bool { pausedRemaining != nil }

    func remaining(at date: Date = Date()) -> TimeInterval {
        if let endDate { return max(0, endDate.timeIntervalSince(date)) }
        return pausedRemaining ?? 0
    }

    /// 0...1 progress, for rings.
    func progress(at date: Date = Date()) -> Double {
        guard total > 0 else { return 0 }
        return isRinging ? 1 : 1 - remaining(at: date) / total
    }
}

/// One stopwatch. `laps` holds the elapsed time at each lap press, newest first.
struct IslandStopwatch: Identifiable, Equatable {
    let id = UUID()
    var number: Int
    var start: Date?
    var accumulated: TimeInterval = 0
    var laps: [TimeInterval] = []

    var isRunning: Bool { start != nil }
    var title: String { "Stopwatch \(number)" }

    func elapsed(at date: Date = Date()) -> TimeInterval {
        accumulated + (start.map { date.timeIntervalSince($0) } ?? 0)
    }

    /// Time in the lap that's running now.
    func currentLap(at date: Date = Date()) -> TimeInterval {
        elapsed(at: date) - (laps.first ?? 0)
    }

    /// Duration of each finished lap, newest first.
    var lapSplits: [TimeInterval] {
        laps.enumerated().map { index, mark in mark - (index + 1 < laps.count ? laps[index + 1] : 0) }
    }
}

@MainActor
final class IslandTimerManager: ObservableObject {
    static let shared = IslandTimerManager()

    @Published private(set) var timers: [IslandCountdown] = []
    @Published private(set) var stopwatches: [IslandStopwatch] = []

    private var endTimer: Timer?
    private var ringTasks: [UUID: Task<Void, Never>] = [:]

    static let presets: [Int] = [1, 2, 3, 5, 10, 15, 20, 25, 30, 45, 60, 90]
    static let maxTimers = 10
    static let maxStopwatches = 8

    // MARK: Summary (compact island, menus, header)

    var isRinging: Bool { timers.contains(where: \.isRinging) }
    var isTimerActive: Bool { !timers.isEmpty }
    var isTimerRunning: Bool { timers.contains(where: \.isRunning) }
    var isStopwatchActive: Bool { !stopwatches.isEmpty }
    var isStopwatchRunning: Bool { stopwatches.contains(where: \.isRunning) }

    /// The countdown the closed island shows: the next one to finish, else the first paused one.
    var primaryTimer: IslandCountdown? {
        timers.filter { $0.isRunning }.min { ($0.endDate ?? .distantFuture) < ($1.endDate ?? .distantFuture) }
            ?? timers.first { !$0.isRinging }
    }

    /// The stopwatch the closed island shows: a running one first.
    var primaryStopwatch: IslandStopwatch? {
        stopwatches.first(where: \.isRunning) ?? stopwatches.first
    }

    var activeTimerCount: Int { timers.filter { !$0.isRinging }.count }

    // MARK: - Countdowns

    func startTimer(minutes: Int) {
        startTimer(seconds: TimeInterval(minutes * 60), label: Self.durationLabel(minutes: minutes))
        Defaults[.timerLastMinutes] = minutes
    }

    func startTimer(seconds: TimeInterval, label: String? = nil) {
        guard seconds > 0 else { return }
        if timers.count >= Self.maxTimers, let oldest = timers.first(where: \.isRinging) ?? timers.first {
            remove(oldest.id)
        }
        let timer = IslandCountdown(label: label ?? Self.durationLabel(minutes: Int(seconds / 60)),
                                    total: seconds, endDate: Date().addingTimeInterval(seconds))
        timers.append(timer)
        scheduleNextEnd()
    }

    func togglePause(_ id: UUID) {
        guard let i = index(of: id) else { return }
        if let end = timers[i].endDate {
            timers[i].pausedRemaining = max(0, end.timeIntervalSinceNow)
            timers[i].endDate = nil
        } else if let remaining = timers[i].pausedRemaining {
            timers[i].pausedRemaining = nil
            timers[i].endDate = Date().addingTimeInterval(remaining)
        }
        scheduleNextEnd()
    }

    func addMinute(_ id: UUID) {
        guard let i = index(of: id) else { return }
        if timers[i].isRinging {
            // Snooze: the same timer runs one more minute.
            stopRingTask(id)
            timers[i].isRinging = false
            timers[i].ringStarted = nil
            timers[i].total = 60
            timers[i].endDate = Date().addingTimeInterval(60)
        } else if let end = timers[i].endDate {
            timers[i].endDate = end.addingTimeInterval(60)
            timers[i].total += 60
        } else if let remaining = timers[i].pausedRemaining {
            timers[i].pausedRemaining = remaining + 60
            timers[i].total += 60
        }
        scheduleNextEnd()
    }

    /// Cancels a countdown (or silences it if it's ringing).
    func remove(_ id: UUID) {
        stopRingTask(id)
        timers.removeAll { $0.id == id }
        scheduleNextEnd()
    }

    func cancelAllTimers() {
        for id in ringTasks.keys { stopRingTask(id) }
        timers.removeAll()
        scheduleNextEnd()
    }

    /// Silences every ringing timer ("Done" in the closed island).
    func stopRinging() {
        for timer in timers where timer.isRinging { remove(timer.id) }
    }

    private func index(of id: UUID) -> Int? { timers.firstIndex { $0.id == id } }

    private func stopRingTask(_ id: UUID) {
        ringTasks[id]?.cancel()
        ringTasks[id] = nil
    }

    /// One wake-up for whichever running countdown ends first.
    private func scheduleNextEnd() {
        endTimer?.invalidate()
        endTimer = nil
        guard let next = timers.compactMap(\.endDate).min() else { return }
        let timer = Timer(fire: max(next, Date()), interval: 0, repeats: false) { _ in
            Task { @MainActor in IslandTimerManager.shared.fireDueTimers() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        endTimer = timer
    }

    private func fireDueTimers() {
        let now = Date().addingTimeInterval(0.06)
        for i in timers.indices {
            guard let end = timers[i].endDate, end <= now else { continue }
            timers[i].endDate = nil
            timers[i].pausedRemaining = nil
            timers[i].isRinging = true
            timers[i].ringStarted = Date()
            ring(timers[i].id)
        }
        scheduleNextEnd()
    }

    private func ring(_ id: UUID) {
        stopRingTask(id)
        ringTasks[id] = Task { @MainActor [weak self] in
            for _ in 0..<4 {
                if Task.isCancelled { return }
                if Defaults[.timerPlaySound] { NSSound(named: "Glass")?.play() }
                try? await Task.sleep(for: .seconds(1.2))
            }
            // Leave the "done" state up a little longer, then clear it.
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let self else { return }
            self.ringTasks[id] = nil
            withAnimation(.smooth) { self.timers.removeAll { $0.id == id && $0.isRinging } }
        }
    }

    // MARK: - Stopwatches

    /// Adds a new stopwatch (running).
    @discardableResult
    func addStopwatch(start: Bool = true) -> UUID? {
        guard stopwatches.count < Self.maxStopwatches else { return nil }
        let number = (stopwatches.map(\.number).max() ?? 0) + 1
        let stopwatch = IslandStopwatch(number: number, start: start ? Date() : nil)
        stopwatches.append(stopwatch)
        return stopwatch.id
    }

    func toggleStopwatch(_ id: UUID) {
        guard let i = stopwatches.firstIndex(where: { $0.id == id }) else { return }
        if let start = stopwatches[i].start {
            stopwatches[i].accumulated += Date().timeIntervalSince(start)
            stopwatches[i].start = nil
        } else {
            stopwatches[i].start = Date()
        }
    }

    func lap(_ id: UUID) {
        guard let i = stopwatches.firstIndex(where: { $0.id == id }), stopwatches[i].isRunning else { return }
        stopwatches[i].laps.insert(stopwatches[i].elapsed(), at: 0)
        if stopwatches[i].laps.count > 99 { stopwatches[i].laps.removeLast() }
    }

    /// Back to zero (stays in the list).
    func resetStopwatch(_ id: UUID) {
        guard let i = stopwatches.firstIndex(where: { $0.id == id }) else { return }
        stopwatches[i].start = nil
        stopwatches[i].accumulated = 0
        stopwatches[i].laps = []
    }

    func removeStopwatch(_ id: UUID) {
        stopwatches.removeAll { $0.id == id }
    }

    /// Menu helpers: act on the stopwatch shown in the closed island.
    func togglePrimaryStopwatch() {
        if let primary = primaryStopwatch { toggleStopwatch(primary.id) } else { addStopwatch() }
    }

    func removeAllStopwatches() { stopwatches.removeAll() }

    // MARK: - Formatting

    nonisolated static func clock(_ interval: TimeInterval, showTenths: Bool = false) -> String {
        let total = Int(max(0, interval).rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        var text = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        if showTenths {
            let tenths = min(9, Int((max(0, interval) - Double(total)) * 10))
            text += ".\(tenths)"
        }
        return text
    }

    /// Countdown text rounds up so "0:00" only shows when the timer is done.
    nonisolated static func countdown(_ interval: TimeInterval) -> String {
        clock(interval.rounded(.up))
    }

    nonisolated static func durationLabel(minutes: Int) -> String {
        if minutes >= 60, minutes % 60 == 0 { return "\(minutes / 60) hr" }
        if minutes > 60 { return "\(minutes / 60) hr \(minutes % 60) min" }
        return "\(max(1, minutes)) min"
    }
}
