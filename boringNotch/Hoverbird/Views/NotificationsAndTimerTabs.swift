//
//  LiveTabView.swift
//  Hoverbird
//
//  Everything "live" in one swipeable row: iPhone orders & Live Activities,
//  the next meeting, Timer, Stopwatch, Awake and mirrored notifications.
//

import Defaults
import SwiftUI

/// 🔔 Notifications tab: only notifications — your iPhone's order/ride updates (as
/// live cards), iPhone Live Activities, and the mirrored notification list.
struct NotificationsTabView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var orders = OrderTracker.shared
    @ObservedObject private var iphone = IPhoneLiveActivityMirror.shared

    var body: some View {
        let hasLive = !orders.orders.isEmpty || !iphone.activities.isEmpty
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(orders.orders) { order in OrderCard(order: order) }
                ForEach(iphone.activities) { activity in IPhoneActivityCard(activity: activity) }
                NotificationsCard(width: hasLive ? 330 : (vm.isCameraExpanded ? 430 : 560))
            }
            .padding(.vertical, 1)
            .padding(.horizontal, 2)
        }
        .frame(height: 128)
        .padding(.top, 2)
    }
}

/// ⏱ Timer tab: as many countdowns and stopwatches as you like, side by side
/// (and beside the camera when it's on).
struct TimerTabView: View {
    @EnvironmentObject var vm: BoringViewModel

    var body: some View {
        let compact = vm.isCameraExpanded
        HStack(spacing: 8) {
            TimersCard(compact: compact)
                .frame(maxWidth: .infinity)
            StopwatchesCard(compact: compact)
                .frame(maxWidth: .infinity)
            // Hoverbird: Pomodoro-style focus sessions.
            FocusCard()
                .frame(width: compact ? 150 : 172)
        }
        .frame(height: 128)
        .padding(.top, 2)
    }
}

// MARK: - Card chrome

struct LiveCard<Content: View>: View {
    /// nil = take the available width.
    var width: CGFloat? = 176
    var tint: Color = .white
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(10)
            .frame(width: width, alignment: .topLeading)
            .frame(maxWidth: width == nil ? .infinity : nil, minHeight: 124, maxHeight: 124, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(tint.opacity(0.09)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.06)))
    }
}

private struct CardHeader: View {
    let symbol: String
    let title: String
    var tint: Color = .white
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(tint)
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing).font(.system(size: 10, weight: .medium)).foregroundStyle(.gray).lineLimit(1)
            }
        }
    }
}

private struct PillButton: View {
    let title: String
    var symbol: String? = nil
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let symbol { Image(systemName: symbol) }
                Text(title).lineLimit(1)
            }
            .fixedSize()
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.22)))
            .foregroundStyle(tint == .white ? .white : tint)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Orders

private struct OrderCard: View {
    let order: OrderActivity

    var body: some View {
        LiveCard(width: 210, tint: order.tint) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    OrderBadge(order: order, size: 18)
                    Text(order.appName).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    if order.isFromIPhone {
                        Image(systemName: "iphone.gen3").font(.system(size: 9, weight: .semibold)).foregroundStyle(.gray)
                    }
                    Spacer(minLength: 0)
                    Button { OrderTracker.shared.dismiss(order) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.gray)
                    }
                    .buttonStyle(.plain)
                }
                StageBar(stage: order.stage, tint: order.tint)
                HStack(alignment: .firstTextBaseline) {
                    Text(order.stage.label).font(.system(size: 13, weight: .bold)).foregroundStyle(order.tint)
                    Spacer()
                    TimelineView(.everyMinute) { context in
                        Text(OrderTracker.compactText(for: order, now: context.date))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                    }
                }
                Text(order.detail.isEmpty ? order.headline : order.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
            }
        }
    }
}

private struct StageBar: View {
    let stage: OrderActivity.Stage
    let tint: Color

    var body: some View {
        HStack(spacing: 3) {
            ForEach(OrderActivity.Stage.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(s <= stage ? tint : Color.white.opacity(0.15))
                    .frame(height: 4)
            }
        }
    }
}

// MARK: - iPhone Live Activity (from the menu bar)

private struct IPhoneActivityCard: View {
    let activity: MirroredLiveActivity

    var body: some View {
        LiveCard(width: 200, tint: .cyan) {
            VStack(alignment: .leading, spacing: 6) {
                CardHeader(symbol: "iphone.gen3", title: activity.appName ?? "iPhone", tint: .cyan, trailing: "Live Activity")
                Text(activity.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if !activity.detail.isEmpty {
                    Text(activity.detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                PillButton(title: "Show", symbol: "arrow.up.forward.app", tint: .cyan) {
                    IPhoneLiveActivityMirror.shared.open(activity)
                }
            }
        }
    }
}

// MARK: - Timers

private struct TimersCard: View {
    var compact = false
    @ObservedObject private var manager = IslandTimerManager.shared
    @Default(.timerLastMinutes) private var lastMinutes

    var body: some View {
        LiveCard(width: nil, tint: .orange) {
            VStack(alignment: .leading, spacing: 6) {
                header
                if manager.timers.isEmpty {
                    presetGrid
                } else if manager.timers.count == 1, let timer = manager.timers.first {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        TimerHero(timer: timer, now: context.date)
                    }
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            VStack(spacing: 4) {
                                ForEach(manager.timers) { timer in
                                    TimerRow(timer: timer, now: context.date)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "timer").font(.system(size: 11, weight: .bold)).foregroundStyle(.orange)
            if !(compact && !manager.timers.isEmpty) {
                Text(manager.timers.count > 1 ? "Timers" : "Timer")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                    .fixedSize()
            }
            if manager.timers.count > 1 {
                Text("\(manager.timers.count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.gray)
            }
            Spacer(minLength: 4)
            if !manager.timers.isEmpty {
                // Tap another duration to run one more timer alongside.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 8.5, weight: .heavy)).foregroundStyle(.orange)
                        ForEach(IslandTimerManager.presets, id: \.self) { minutes in
                            PresetChip(minutes: minutes, small: true, highlighted: minutes == lastMinutes) {
                                withAnimation(.smooth) { manager.startTimer(minutes: minutes) }
                            }
                        }
                    }
                    .padding(.horizontal, 1)
                }
                .frame(maxWidth: compact ? 150 : 200)
                .help("Start another timer")
            }
        }
        .frame(height: 18)
    }

    private var presetGrid: some View {
        let columns = compact ? 4 : 6
        return VStack(alignment: .leading, spacing: 5) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 4) {
                ForEach(IslandTimerManager.presets, id: \.self) { minutes in
                    PresetChip(minutes: minutes, highlighted: minutes == lastMinutes) {
                        withAnimation(.smooth) { manager.startTimer(minutes: minutes) }
                    }
                }
            }
            if !compact {
                Text("Tap to start — run as many timers as you like")
                    .font(.system(size: 9.5)).foregroundStyle(.gray).lineLimit(1)
            }
        }
    }
}

private struct PresetChip: View {
    let minutes: Int
    var small = false
    var highlighted = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(minutes == 60 ? "1h" : "\(minutes)m")
                .font(.system(size: small ? 10 : 11, weight: .semibold, design: .rounded))
                .frame(minWidth: small ? 22 : nil)
                .frame(maxWidth: small ? nil : .infinity)
                .padding(.horizontal, small ? 5 : 0)
                .padding(.vertical, small ? 2.5 : 5)
                .background(RoundedRectangle(cornerRadius: small ? 7 : 8, style: .continuous)
                    .fill(Color.orange.opacity(highlighted ? 0.35 : 0.16)))
                .foregroundStyle(.white)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Small round control used in timer / stopwatch rows.
private struct RoundIconButton: View {
    var symbol: String? = nil
    var text: String? = nil
    var tint: Color = .white
    var size: CGFloat = 22
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: size * 0.42, weight: .bold))
                } else {
                    Text(text ?? "").font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                }
            }
            .foregroundStyle(tint == .white ? Color.white : tint)
            .frame(width: size, height: size)
            .background(Circle().fill(tint.opacity(tint == .white ? 0.14 : 0.24)))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct TimerControls: View {
    let timer: IslandCountdown
    var size: CGFloat = 22

    var body: some View {
        let manager = IslandTimerManager.shared
        HStack(spacing: 4) {
            if timer.isRinging {
                RoundIconButton(text: "+1", size: size, help: "One more minute") { manager.addMinute(timer.id) }
                RoundIconButton(symbol: "stop.fill", tint: .orange, size: size, help: "Stop") {
                    withAnimation(.smooth) { manager.remove(timer.id) }
                }
            } else {
                RoundIconButton(symbol: timer.isRunning ? "pause.fill" : "play.fill", tint: .orange, size: size,
                                help: timer.isRunning ? "Pause" : "Resume") { manager.togglePause(timer.id) }
                RoundIconButton(text: "+1", size: size, help: "Add a minute") { manager.addMinute(timer.id) }
                RoundIconButton(symbol: "xmark", size: size, help: "Cancel timer") {
                    withAnimation(.smooth) { manager.remove(timer.id) }
                }
            }
        }
    }
}

private func timerSubtitle(_ timer: IslandCountdown) -> String {
    if timer.isRinging { return "\(timer.label) · done" }
    if timer.isPaused { return "\(timer.label) · paused" }
    if let end = timer.endDate { return "\(timer.label) · ends \(end.formatted(date: .omitted, time: .shortened))" }
    return timer.label
}

/// A single timer gets the big ring.
private struct TimerHero: View {
    let timer: IslandCountdown
    let now: Date

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                ProgressRing(progress: timer.progress(at: now),
                             tint: timer.isRunning || timer.isRinging ? .orange : .gray, lineWidth: 4)
                Text(timer.isRinging ? "Done" : IslandTimerManager.countdown(timer.remaining(at: now)))
                    .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(timer.isRinging ? .orange : .white)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
            }
            .frame(width: 62, height: 62)
            VStack(alignment: .leading, spacing: 7) {
                Text(timerSubtitle(timer))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.gray).lineLimit(1)
                TimerControls(timer: timer, size: 26)
            }
            Spacer(minLength: 0)
        }
    }
}

/// One of several timers.
private struct TimerRow: View {
    let timer: IslandCountdown
    let now: Date

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                ProgressRing(progress: timer.progress(at: now),
                             tint: timer.isRunning || timer.isRinging ? .orange : .gray, lineWidth: 2.5)
                if timer.isRinging {
                    Image(systemName: "bell.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(.orange)
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(timer.isRinging ? "Done" : IslandTimerManager.countdown(timer.remaining(at: now)))
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(timer.isRinging ? .orange : (timer.isRunning ? .white : .gray))
                    .fixedSize()
                Text(timerSubtitle(timer))
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.gray).lineLimit(1)
            }
            Spacer(minLength: 2)
            TimerControls(timer: timer)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}

// MARK: - Stopwatches

private struct StopwatchesCard: View {
    var compact = false
    @ObservedObject private var manager = IslandTimerManager.shared

    var body: some View {
        LiveCard(width: nil, tint: .orange) {
            VStack(alignment: .leading, spacing: 6) {
                header
                if manager.stopwatches.isEmpty {
                    emptyState
                } else if manager.stopwatches.count == 1, let stopwatch = manager.stopwatches.first {
                    TimelineView(.periodic(from: .now, by: stopwatch.isRunning ? 0.1 : 30)) { context in
                        StopwatchHero(stopwatch: stopwatch, now: context.date, compact: compact)
                    }
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        TimelineView(.periodic(from: .now, by: manager.isStopwatchRunning ? 0.1 : 30)) { context in
                            VStack(spacing: 4) {
                                ForEach(manager.stopwatches) { stopwatch in
                                    StopwatchRow(stopwatch: stopwatch, now: context.date)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "stopwatch").font(.system(size: 11, weight: .bold)).foregroundStyle(.orange)
            Text(manager.stopwatches.count > 1 ? "Stopwatches" : "Stopwatch")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            if manager.stopwatches.count > 1 {
                Text("\(manager.stopwatches.count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.gray)
            }
            Spacer(minLength: 4)
            if !manager.stopwatches.isEmpty, manager.stopwatches.count < IslandTimerManager.maxStopwatches {
                Button { withAnimation(.smooth) { _ = manager.addStopwatch() } } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "plus").font(.system(size: 8.5, weight: .heavy))
                        Text("New").font(.system(size: 10, weight: .semibold))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(Color.orange.opacity(0.22)))
                    .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("Start another stopwatch")
            }
        }
        .frame(height: 18)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("0:00.0")
                .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
            HStack(spacing: 6) {
                PillButton(title: "Start", symbol: "play.fill", tint: .orange) {
                    withAnimation(.smooth) { _ = manager.addStopwatch() }
                }
                Text("Run several at once").font(.system(size: 9.5)).foregroundStyle(.gray).lineLimit(1)
            }
        }
    }
}

private struct StopwatchControls: View {
    let stopwatch: IslandStopwatch
    var size: CGFloat = 22

    var body: some View {
        let manager = IslandTimerManager.shared
        HStack(spacing: 4) {
            RoundIconButton(symbol: stopwatch.isRunning ? "pause.fill" : "play.fill", tint: .orange, size: size,
                            help: stopwatch.isRunning ? "Pause" : "Start") { manager.toggleStopwatch(stopwatch.id) }
            if stopwatch.isRunning {
                RoundIconButton(symbol: "flag.fill", size: size, help: "Lap") { manager.lap(stopwatch.id) }
            } else {
                RoundIconButton(symbol: "arrow.counterclockwise", size: size, help: "Reset") {
                    manager.resetStopwatch(stopwatch.id)
                }
            }
            RoundIconButton(symbol: "xmark", size: size, help: "Remove stopwatch") {
                withAnimation(.smooth) { manager.removeStopwatch(stopwatch.id) }
            }
        }
    }
}

private func stopwatchDetail(_ stopwatch: IslandStopwatch, now: Date, includeName: Bool) -> String {
    var parts: [String] = []
    if stopwatch.laps.isEmpty {
        if includeName { parts.append(stopwatch.title) }
        if !stopwatch.isRunning { parts.append(stopwatch.elapsed(at: now) > 0 ? "paused" : "ready") }
    } else {
        // The running lap first so it survives truncation in narrow rows.
        parts.append("Lap \(stopwatch.laps.count + 1) \(IslandTimerManager.clock(stopwatch.currentLap(at: now), showTenths: true))")
        if includeName { parts.append("#\(stopwatch.number)") }
        if !stopwatch.isRunning { parts.append("paused") }
    }
    return parts.joined(separator: " · ")
}

/// A single stopwatch gets the big readout plus its laps.
private struct StopwatchHero: View {
    let stopwatch: IslandStopwatch
    let now: Date
    var compact = false

    var body: some View {
        let splits = stopwatch.lapSplits
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(IslandTimerManager.clock(stopwatch.elapsed(at: now), showTenths: true))
                        .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(stopwatch.isRunning ? .white : .gray)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(stopwatchDetail(stopwatch, now: now, includeName: false).capitalizedFirst)
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit()).foregroundStyle(.gray).lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: 2)
                if !splits.isEmpty {
                    LapList(splits: splits, limit: compact ? 2 : 3)
                }
            }
            Spacer(minLength: 0)
            StopwatchControls(stopwatch: stopwatch, size: 26)
        }
    }
}

/// Recent laps, newest first; best lap green, slowest red (like the iPhone Clock app).
private struct LapList: View {
    let splits: [TimeInterval]
    var limit = 3

    var body: some View {
        let best = splits.count > 1 ? splits.min() : nil
        let worst = splits.count > 1 ? splits.max() : nil
        VStack(alignment: .trailing, spacing: 1) {
            ForEach(Array(splits.prefix(limit).enumerated()), id: \.offset) { index, split in
                HStack(spacing: 4) {
                    Text("Lap \(splits.count - index)").foregroundStyle(.gray)
                    Text(IslandTimerManager.clock(split, showTenths: true))
                        .foregroundStyle(split == best ? Color.green : (split == worst ? Color.red : Color.white.opacity(0.8)))
                }
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                .lineLimit(1)
                .fixedSize()
            }
            if splits.count > limit {
                Text("+\(splits.count - limit) more").font(.system(size: 8.5)).foregroundStyle(.gray)
            }
        }
    }
}

/// One of several stopwatches.
private struct StopwatchRow: View {
    let stopwatch: IslandStopwatch
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text(IslandTimerManager.clock(stopwatch.elapsed(at: now), showTenths: true))
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(stopwatch.isRunning ? .white : .gray)
                    .fixedSize()
                Text(stopwatchDetail(stopwatch, now: now, includeName: true))
                    .font(.system(size: 9, weight: .medium).monospacedDigit()).foregroundStyle(.gray).lineLimit(1)
            }
            Spacer(minLength: 2)
            StopwatchControls(stopwatch: stopwatch)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Notifications

private struct NotificationsCard: View {
    var width: CGFloat = 250
    @ObservedObject private var mirror = NotificationMirror.shared
    @Default(.mirrorNotifications) private var enabled
    @State private var selectedID: UUID?
    @State private var unreadOnly = false

    var body: some View {
        LiveCard(width: width, tint: .blue) {
            ZStack(alignment: .topLeading) {
                if let id = selectedID, let note = mirror.recent.first(where: { $0.id == id }) {
                    NotificationDetail(note: note) { withAnimation(.smooth(duration: 0.28)) { selectedID = nil } }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    list
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
        }
        .onAppear {
            mirror.syncIfNeeded()
            takeFocus()
        }
        .onChange(of: mirror.focusedID) { takeFocus() }
        .onChange(of: mirror.recent) {
            // It was cleared (here or in Notification Center): back to the list.
            if let id = selectedID, !mirror.recent.contains(where: { $0.id == id }) {
                withAnimation(.smooth) { selectedID = nil }
            }
        }
    }

    /// A tapped banner opens straight into its message.
    private func takeFocus() {
        guard let id = mirror.focusedID else { return }
        mirror.focusedID = nil
        if mirror.recent.contains(where: { $0.id == id }) { withAnimation(.smooth) { selectedID = id } }
    }

    private var list: some View {
        let unread = mirror.unreadCount
        let items = mirror.recent.filter { !unreadOnly || !$0.isRead }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                CardHeader(symbol: "bell.badge.fill", title: "Notifications", tint: .blue,
                           trailing: mirror.recent.isEmpty ? nil : (unread > 0 ? "\(unread) unread" : "\(mirror.recent.count)"))
                if !mirror.recent.isEmpty {
                    HeaderChip(title: unreadOnly ? "Unread" : "All", symbol: unreadOnly ? "circle.fill" : "line.3.horizontal.decrease",
                               active: unreadOnly, help: "Show only unread notifications") { withAnimation(.smooth) { unreadOnly.toggle() } }
                    if unread > 0 {
                        HeaderChip(title: "Mark all read", symbol: "envelope.open", help: "Mark every notification as read") { mirror.markAllRead() }
                    }
                }
                if enabled && mirror.isActive {
                    Button { mirror.syncNow() } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(mirror.isSyncing ? Color.blue : Color.gray)
                            .rotationEffect(.degrees(mirror.isSyncing ? 360 : 0))
                            .animation(mirror.isSyncing ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .easeOut(duration: 0.2),
                                       value: mirror.isSyncing)
                    }
                    .buttonStyle(.plain)
                    .help("Sync with Notification Center")
                }
                if !mirror.recent.isEmpty {
                    HeaderChip(title: "Clear All", symbol: "xmark", help: "Clear every notification — here and in Notification Center") { mirror.clearAll() }
                }
            }
            if !enabled {
                Text("Notification mirroring is off.").font(.system(size: 11)).foregroundStyle(.gray)
            } else if !mirror.isActive {
                Text("Allow Accessibility for Hoverbird to mirror notifications (incl. your iPhone's).")
                    .font(.system(size: 11)).foregroundStyle(.gray).lineLimit(3)
                PillButton(title: "Open Settings", symbol: "gearshape", tint: .blue) {
                    XPCHelperClient.shared.requestAccessibilityAuthorization()
                }
            } else if items.isEmpty {
                if mirror.isSyncing {
                    HStack(spacing: 8) {
                        BirdActivityIndicator(size: 16)
                        Text("Syncing with Notification Center…").font(.system(size: 11)).foregroundStyle(.gray)
                    }
                    .frame(maxWidth: .infinity, minHeight: 100)
                } else if unreadOnly && !mirror.recent.isEmpty {
                    BirdEmptyState(title: "All caught up", detail: "No unread notifications.")
                } else {
                    BirdEmptyState(title: "No notifications", detail: "New ones — including your iPhone's — appear here.")
                }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(items.prefix(50)) { note in
                            NotificationRow(note: note) { withAnimation(.smooth(duration: 0.28)) { selectedID = note.id } }
                                .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .trailing).combined(with: .opacity)))
                        }
                    }
                }
            }
        }
    }
}

/// Small capsule button for card headers.
private struct HeaderChip: View {
    let title: String
    var symbol: String? = nil
    var active = false
    var help: String = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let symbol { Image(systemName: symbol).font(.system(size: 7.5, weight: .bold)) }
                Text(title).font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(active ? Color.blue.opacity(0.35) : Color.white.opacity(hovering ? 0.18 : 0.11)))
            .foregroundStyle(.white.opacity(0.92))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct NotificationIcon: View {
    let note: MirroredNotification
    var size: CGFloat = 16

    var body: some View {
        if let id = note.bundleID, let icon = AppIconAsNSImage(for: id) {
            Image(nsImage: icon).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: note.isFromIPhone ? "iphone.gen3" : "bell.fill")
                .font(.system(size: size * 0.62)).foregroundStyle(.gray).frame(width: size, height: size)
        }
    }
}

private func timeText(_ note: MirroredNotification) -> Text {
    if let label = note.timeLabel { return Text(label) }
    return Text(note.date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
}

private struct NotificationRow: View {
    let note: MirroredNotification
    let open: () -> Void
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        let code = NotificationMirror.oneTimeCode(in: note.title + " " + note.body)
        HStack(alignment: .top, spacing: 7) {
            ZStack(alignment: .topLeading) {
                NotificationIcon(note: note)
                if !note.isRead {
                    Circle().fill(Color.blue).frame(width: 6, height: 6).offset(x: -4, y: -3)
                }
            }
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(note.title.isEmpty ? note.appName : "\(note.appName) · \(note.title)")
                        .font(.system(size: 10.5, weight: note.isRead ? .medium : .bold))
                        .foregroundStyle(.white.opacity(note.isRead ? 0.75 : 1))
                        .lineLimit(1)
                    if note.isStack {
                        Image(systemName: "square.stack.fill").font(.system(size: 8)).foregroundStyle(.gray)
                            .help("More notifications from this sender in Notification Center")
                    }
                }
                Text(note.body).font(.system(size: 10)).foregroundStyle(.white.opacity(note.isRead ? 0.55 : 0.75)).lineLimit(2)
            }
            Spacer(minLength: 4)
            if let code {
                Button {
                    NotificationMirror.shared.copy(code)
                    withAnimation(.smooth) { copied = true }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 7.5, weight: .bold))
                        Text(copied ? "Copied" : code).font(.system(size: 9.5, weight: .bold, design: .rounded).monospacedDigit())
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.green.opacity(0.25)))
                    .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .help("Copy the code")
            }
            VStack(alignment: .trailing, spacing: 3) {
                timeText(note).font(.system(size: 9)).foregroundStyle(.gray).lineLimit(1)
                Button { NotificationMirror.shared.dismiss(note) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.white.opacity(hovering ? 0.9 : 0.55))
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.white.opacity(hovering ? 0.18 : 0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Clear this notification")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(hovering ? 0.09 : 0.04)))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .help("Open to read")
    }
}

/// The whole message, with what you can do with it.
private struct NotificationDetail: View {
    let note: MirroredNotification
    let back: () -> Void
    @ObservedObject private var mirror = NotificationMirror.shared
    @State private var copied: String?

    var body: some View {
        let text = note.title + " " + note.body
        let code = NotificationMirror.oneTimeCode(in: text)
        let link = NotificationMirror.firstLink(in: note.body)
        let sameApp = mirror.recent.filter { $0.appName.caseInsensitiveCompare(note.appName) == .orderedSame }.count
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Button(action: back) {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold))
                        Text("Back").font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(.blue)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back to the list (nothing changes)")
                NotificationIcon(note: note, size: 15)
                Text(note.appName).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                if note.isFromIPhone {
                    Image(systemName: "iphone.gen3").font(.system(size: 9)).foregroundStyle(.gray)
                }
                Spacer(minLength: 4)
                if !note.isRead {
                    Text("Unread").font(.system(size: 9, weight: .bold)).foregroundStyle(.blue)
                }
                timeText(note).font(.system(size: 9.5)).foregroundStyle(.gray).lineLimit(1)
                Button {
                    mirror.dismiss(note)
                    back()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.red)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.red.opacity(0.18)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Delete this notification (also from Notification Center)")
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 3) {
                    if !note.title.isEmpty {
                        Text(note.title).font(.system(size: 12.5, weight: .bold)).foregroundStyle(.white)
                    }
                    Text(note.body)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                    if note.isStack {
                        Text("More from \(note.appName) are grouped in Notification Center — Open to see them.")
                            .font(.system(size: 9.5)).foregroundStyle(.gray)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    PillButton(title: "Open", symbol: "arrow.up.forward.app", tint: .blue) { mirror.open(note) }
                    PillButton(title: note.isRead ? "Unread" : "Mark Read", symbol: note.isRead ? "envelope.badge" : "envelope.open") {
                        mirror.setRead(note, !note.isRead)
                    }
                    if let code {
                        PillButton(title: copied == code ? "Copied" : "Copy \(code)", symbol: "number", tint: .green) {
                            mirror.copy(code)
                            withAnimation(.smooth) { copied = code }
                        }
                    }
                    PillButton(title: copied == "text" ? "Copied" : "Copy", symbol: "doc.on.doc") {
                        mirror.copy(note.title.isEmpty ? note.body : "\(note.title)\n\(note.body)")
                        withAnimation(.smooth) { copied = "text" }
                    }
                    if let link {
                        PillButton(title: "Open Link", symbol: "link") { NSWorkspace.shared.open(link) }
                    }
                    if sameApp > 1 {
                        PillButton(title: "Clear all \(sameApp)", symbol: "xmark.circle") {
                            mirror.clearApp(of: note)
                            back()
                        }
                        .help("Clear all \(sameApp) notifications from \(note.appName)")
                    }
                    PillButton(title: "Mute app", symbol: "bell.slash") {
                        mirror.mute(note)
                        back()
                    }
                    .help("Stop showing \(note.appName) notifications in the island (undo in Settings)")
                    PillButton(title: "Delete", symbol: "trash", tint: .red) {
                        mirror.dismiss(note)
                        back()
                    }
                }
                .padding(.horizontal, 1)
            }
            .frame(height: 22)
        }
    }
}
