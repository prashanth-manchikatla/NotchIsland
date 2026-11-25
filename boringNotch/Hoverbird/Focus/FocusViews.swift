//
//  FocusViews.swift
//  Hoverbird · Focus
//
//  The Focus card (Timer tab), its closed-island activity and Settings › Focus.
//

import Defaults
import SwiftUI

/// Timer tab card: start a focus session, or the running one with pause / skip / stop.
struct FocusCard: View {
    @ObservedObject private var focus = FocusManager.shared
    @Default(.focusMinutes) private var minutes
    @Default(.focusSound) private var sound

    var body: some View {
        LiveCard(width: nil, tint: focus.phase.tint) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: focus.phase.symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(focus.phase.tint)
                    Text(focus.isActive ? focus.phase.title : "Focus").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                    Spacer(minLength: 0)
                    if focus.isActive {
                        Text("\(min(focus.setCount + (focus.phase == .focus ? 1 : 0), max(1, Defaults[.focusLongBreakEvery])))/\(Defaults[.focusLongBreakEvery])")
                            .font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.gray)
                    }
                }
                if focus.isActive { running } else { idle }
            }
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(minutes) min").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Spacer(minLength: 0)
                Button { focus.startFocus() } label: {
                    Image(systemName: "play.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 30, height: 30).background(Circle().fill(FocusManager.Phase.focus.tint.opacity(0.85)))
                }
                .buttonStyle(.plain)
                .help("Start a \(minutes)-minute focus session")
            }
            HStack(spacing: 4) {
                Text(focus.todayMinutes > 0 ? "Today \(AIFormat.duration(TimeInterval(focus.todayMinutes * 60)))" : "Nothing yet today")
                if focus.streak > 1 { Text("· 🔥 \(focus.streak) days") }
                Spacer(minLength: 0)
                if sound != .off { Image(systemName: "waveform").help(sound.rawValue) }
            }
            .font(.system(size: 9.5, weight: .medium)).foregroundStyle(.gray).lineLimit(1)
            AISparkline(values: focus.lastWeek.map(Double.init), tint: FocusManager.Phase.focus.tint)
                .frame(height: 14)
                .help("Focus minutes, last 7 days")
        }
    }

    private var running: some View {
        HStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                ZStack {
                    ProgressRing(progress: focus.progress(at: context.date), tint: focus.phase.tint, lineWidth: 4)
                    Text(IslandTimerManager.countdown(focus.remaining(at: context.date)))
                        .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(.white)
                }
                .frame(width: 66, height: 66)
            }
            VStack(spacing: 6) {
                FocusControl(symbol: focus.isRunning ? "pause.fill" : "play.fill", help: focus.isRunning ? "Pause" : "Resume") { focus.toggle() }
                FocusControl(symbol: "forward.end.fill", help: "Skip to the next phase") { focus.skip() }
                FocusControl(symbol: "xmark", help: "Stop") { focus.stop() }
            }
        }
    }
}

private struct FocusControl: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)).foregroundStyle(.white)
                .frame(width: 24, height: 24).background(Circle().fill(Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Closed island: ring + time left, in the phase colour.
struct FocusCompactView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var focus = FocusManager.shared

    var body: some View {
        IslandCompactRow(sideWidth: 50) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                ProgressRing(progress: focus.progress(at: context.date), tint: focus.phase.tint)
                    .frame(width: max(12, vm.effectiveClosedNotchHeight - 14), height: max(12, vm.effectiveClosedNotchHeight - 14))
            }
        } trailing: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(IslandTimerManager.countdown(focus.remaining(at: context.date)))
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(focus.isRunning ? focus.phase.tint : .gray)
            }
        }
    }
}

/// The small detached bubble.
struct FocusBubble: View {
    let diameter: CGFloat
    @ObservedObject private var focus = FocusManager.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ProgressRing(progress: focus.progress(at: context.date), tint: focus.isRunning ? focus.phase.tint : .gray)
                .frame(width: diameter - 10, height: diameter - 10)
        }
    }
}

struct FocusSettingsView: View {
    @Default(.focusMinutes) private var focusMinutes
    @Default(.focusShortBreakMinutes) private var shortBreak
    @Default(.focusLongBreakMinutes) private var longBreak
    @Default(.focusLongBreakEvery) private var every
    @Default(.focusSound) private var sound
    @Default(.focusSoundVolume) private var volume

    var body: some View {
        Form {
            Section {
                Stepper("Focus: \(focusMinutes) min", value: $focusMinutes, in: 5...120, step: 5)
                Stepper("Short break: \(shortBreak) min", value: $shortBreak, in: 1...30)
                Stepper("Long break: \(longBreak) min", value: $longBreak, in: 5...60, step: 5)
                Stepper("Long break after every \(every) sessions", value: $every, in: 2...8)
                Defaults.Toggle("Start breaks automatically", key: .focusAutoStartBreaks)
                Defaults.Toggle("Start the next focus session automatically", key: .focusAutoStartFocus)
                Defaults.Toggle("Chime when a phase ends", key: .focusChime)
            } header: {
                Text("Focus timer")
            } footer: {
                Text("Start it from the Timer tab. The closed island shows the ring and time left; your focus minutes and day streak are kept for 60 days on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Sound", selection: $sound) { ForEach(FocusSound.allCases) { Text($0.rawValue).tag($0) } }
                    .onChange(of: sound) { FocusManager.shared.soundSettingsChanged() }
                LabeledSlider(title: "Volume", value: $volume, range: 0.05...1, step: 0.05, unit: "")
                    .onChange(of: volume) { FocusManager.shared.soundSettingsChanged() }
                Defaults.Toggle("Keep playing during breaks", key: .focusSoundInBreaks)
            } header: {
                Text("Focus sounds")
            } footer: {
                Text("Generated on your Mac, no downloads. Brown noise is deep and soft; Ocean adds slow swells.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Defaults.Toggle("Remind me to rest my eyes every 20 minutes (20-20-20)", key: .eyeBreakReminders)
            } header: {
                Text("Eye breaks")
            } footer: {
                Text("Every 20 minutes of screen time: look at something 20 feet away for 20 seconds. Skipped when you're away from the Mac or on a focus break.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Focus")
    }
}
