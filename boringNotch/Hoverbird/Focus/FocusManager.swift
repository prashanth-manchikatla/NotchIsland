//
//  FocusManager.swift
//  Hoverbird · Focus
//
//  A Pomodoro-style focus timer: focus → short break → … → long break every N sessions,
//  with optional auto-start, a chime at each change, today's focus minutes, a day streak
//  and a 7-day history. One timer for the phase end — no ticking in the background.
//  Also: 20-20-20 eye-break reminders (only while you're actually at the Mac).
//

import AppKit
import Combine
import Defaults
import SwiftUI

extension Defaults.Keys {
    static let focusMinutes = Key<Int>("focusMinutes", default: 25)
    static let focusShortBreakMinutes = Key<Int>("focusShortBreakMinutes", default: 5)
    static let focusLongBreakMinutes = Key<Int>("focusLongBreakMinutes", default: 15)
    static let focusLongBreakEvery = Key<Int>("focusLongBreakEvery", default: 4)
    static let focusAutoStartBreaks = Key<Bool>("focusAutoStartBreaks", default: true)
    static let focusAutoStartFocus = Key<Bool>("focusAutoStartFocus", default: false)
    static let focusChime = Key<Bool>("focusChime", default: true)
    static let focusSound = Key<FocusSound>("focusSound", default: .off)
    static let focusSoundVolume = Key<Double>("focusSoundVolume", default: 0.35)
    static let focusSoundInBreaks = Key<Bool>("focusSoundInBreaks", default: false)
    /// Minutes focused per day ("yyyy-MM-dd" → minutes), last 60 days.
    static let focusHistory = Key<[String: Int]>("focusHistory", default: [:])
    static let eyeBreakReminders = Key<Bool>("eyeBreakReminders", default: false)
}

@MainActor
final class FocusManager: ObservableObject {
    static let shared = FocusManager()

    enum Phase: String { case focus, shortBreak, longBreak
        var title: String { self == .focus ? "Focus" : (self == .shortBreak ? "Break" : "Long break") }
        var tint: Color { self == .focus ? Color(red: 1, green: 0.42, blue: 0.32) : .green }
        var symbol: String { self == .focus ? "brain.head.profile" : "cup.and.saucer.fill" }
    }

    @Published private(set) var phase: Phase = .focus
    @Published private(set) var endDate: Date?
    @Published private(set) var pausedRemaining: TimeInterval?
    @Published private(set) var phaseLength: TimeInterval = 25 * 60
    /// Focus sessions finished in the current set (a long break follows every N).
    @Published private(set) var setCount = 0
    @Published private(set) var history: [String: Int] = Defaults[.focusHistory]

    private var phaseTimer: Timer?
    private var eyeTimer: Timer?

    var isRunning: Bool { endDate != nil }
    var isActive: Bool { endDate != nil || pausedRemaining != nil }

    private init() {
        applyEyeBreaks()
        Defaults.publisher(.eyeBreakReminders, options: []).sink { _ in
            Task { @MainActor in FocusManager.shared.applyEyeBreaks() }
        }.store(in: &cancellables)
    }
    private var cancellables = Set<AnyCancellable>()

    func remaining(at date: Date = Date()) -> TimeInterval {
        if let pausedRemaining { return pausedRemaining }
        guard let endDate else { return phaseLength }
        return max(0, endDate.timeIntervalSince(date))
    }

    func progress(at date: Date = Date()) -> Double {
        phaseLength > 0 ? 1 - remaining(at: date) / phaseLength : 0
    }

    // MARK: Controls

    func startFocus() { begin(.focus) }

    func toggle() {
        if isRunning { pause() } else if pausedRemaining != nil { resume() } else { begin(phase) }
    }

    func pause() {
        guard let endDate else { return }
        pausedRemaining = max(0, endDate.timeIntervalSinceNow)
        self.endDate = nil
        phaseTimer?.invalidate()
        FocusSounds.shared.stop()
    }

    func resume() {
        guard let left = pausedRemaining else { return }
        pausedRemaining = nil
        endDate = Date().addingTimeInterval(left)
        schedule()
        updateSound()
    }

    /// Ends this phase now and moves on (a skipped focus session doesn't count).
    func skip() { advance(counted: false) }

    func stop() {
        phaseTimer?.invalidate()
        endDate = nil
        pausedRemaining = nil
        phase = .focus
        phaseLength = TimeInterval(Defaults[.focusMinutes] * 60)
        setCount = 0
        FocusSounds.shared.stop()
    }

    private func begin(_ next: Phase) {
        phase = next
        let minutes: Int
        switch next {
        case .focus: minutes = Defaults[.focusMinutes]
        case .shortBreak: minutes = Defaults[.focusShortBreakMinutes]
        case .longBreak: minutes = Defaults[.focusLongBreakMinutes]
        }
        phaseLength = TimeInterval(max(1, minutes) * 60)
        pausedRemaining = nil
        endDate = Date().addingTimeInterval(phaseLength)
        schedule()
        updateSound()
    }

    private func schedule() {
        phaseTimer?.invalidate()
        guard let endDate else { return }
        let t = Timer(fire: endDate, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { FocusManager.shared.advance(counted: true) }
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        phaseTimer = t
    }

    private func advance(counted: Bool) {
        phaseTimer?.invalidate()
        let finished = phase
        if finished == .focus {
            if counted { record(minutes: Int((phaseLength / 60).rounded())) }
            setCount += 1
            let long = setCount % max(1, Defaults[.focusLongBreakEvery]) == 0
            let next: Phase = long ? .longBreak : .shortBreak
            announce(counted ? "Focus done · \(long ? "long break" : "take \(Defaults[.focusShortBreakMinutes]) min")" : "Focus skipped", next: next)
            if Defaults[.focusAutoStartBreaks] { begin(next) } else { park(next) }
        } else {
            if finished == .longBreak { setCount = 0 }
            announce("Break over · back to focus", next: .focus)
            if Defaults[.focusAutoStartFocus] { begin(.focus) } else { park(.focus) }
        }
    }

    /// Ready but not running (waits for you to press start).
    private func park(_ next: Phase) {
        phase = next
        endDate = nil
        let minutes = next == .focus ? Defaults[.focusMinutes] : (next == .shortBreak ? Defaults[.focusShortBreakMinutes] : Defaults[.focusLongBreakMinutes])
        phaseLength = TimeInterval(max(1, minutes) * 60)
        pausedRemaining = phaseLength
        FocusSounds.shared.stop()
    }

    private func announce(_ text: String, next: Phase) {
        if Defaults[.focusChime] { NSSound(named: next == .focus ? "Hero" : "Glass")?.play() }
        IslandActivityHub.shared.showPill(.info(symbol: next.symbol, text: text, tint: next.tint), duration: 3.5)
    }

    private func updateSound() {
        let sound = Defaults[.focusSound]
        if isRunning, sound != .off, phase == .focus || Defaults[.focusSoundInBreaks] {
            FocusSounds.shared.play(sound, volume: Float(Defaults[.focusSoundVolume]))
        } else {
            FocusSounds.shared.stop()
        }
    }

    /// Settings changed the sound / volume while running.
    func soundSettingsChanged() { updateSound() }

    // MARK: Stats

    private static let dayKey: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()

    private func record(minutes: Int) {
        let key = Self.dayKey.string(from: Date())
        history[key, default: 0] += minutes
        let cutoff = Self.dayKey.string(from: Date().addingTimeInterval(-60 * 86_400))
        history = history.filter { $0.key >= cutoff }
        Defaults[.focusHistory] = history
    }

    var todayMinutes: Int { history[Self.dayKey.string(from: Date())] ?? 0 }

    /// Days in a row with focus time (today counts once you've focused; otherwise up to yesterday).
    var streak: Int {
        var day = Date()
        if history[Self.dayKey.string(from: day)] == nil { day = day.addingTimeInterval(-86_400) }
        var count = 0
        while (history[Self.dayKey.string(from: day)] ?? 0) > 0 {
            count += 1
            day = day.addingTimeInterval(-86_400)
        }
        return count
    }

    /// Minutes for the last 7 days, oldest first.
    var lastWeek: [Int] {
        (0..<7).reversed().map { history[Self.dayKey.string(from: Date().addingTimeInterval(-Double($0) * 86_400))] ?? 0 }
    }

    // MARK: 20-20-20

    private func applyEyeBreaks() {
        eyeTimer?.invalidate()
        guard Defaults[.eyeBreakReminders] else { return }
        let t = Timer(timeInterval: 20 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { FocusManager.shared.eyeBreak() }
        }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        eyeTimer = t
    }

    private func eyeBreak() {
        // Only if you've been at the Mac in the last minute and not on a break already.
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle < 60, !(isRunning && phase != .focus) else { return }
        IslandActivityHub.shared.showPill(.info(symbol: "eye", text: "Look 20 feet away for 20 seconds", tint: .cyan), duration: 6)
    }
}
