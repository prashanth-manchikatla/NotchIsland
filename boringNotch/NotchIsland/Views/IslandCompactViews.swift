//
//  IslandCompactViews.swift
//  NotchIsland
//
//  Compact presentations shown while the island is closed — content hugs the
//  camera housing on both sides exactly like the iPhone 17 Dynamic Island.
//

import Defaults
import SwiftUI

// MARK: - Layout around the notch

struct IslandCompactRow<Leading: View, Trailing: View>: View {
    @EnvironmentObject var vm: BoringViewModel
    var sideWidth: CGFloat? = nil
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        let h = vm.effectiveClosedNotchHeight
        let side = max(sideWidth ?? 0, h - 12)
        HStack(spacing: 8) {
            leading()
                .frame(width: side, height: max(0, h - 8), alignment: .leading)
            Color.clear
                .frame(width: max(0, vm.closedNotchSize.width - 6))
            trailing()
                .frame(width: side, height: max(0, h - 8), alignment: .trailing)
        }
        .frame(height: h)
    }
}

// MARK: - Primary compact activity

struct IslandCompactActivityView: View {
    let activity: IslandCompactActivity
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var capture = CaptureManager.shared
    @ObservedObject private var timers = IslandTimerManager.shared
    @ObservedObject private var awake = AwakeManager.shared
    @ObservedObject private var orders = OrderTracker.shared
    @ObservedObject private var iphone = IPhoneLiveActivityMirror.shared
    @ObservedObject private var calendar = UpcomingEventMonitor.shared
    @ObservedObject private var hub = IslandActivityHub.shared

    private var iconSize: CGFloat { max(12, vm.effectiveClosedNotchHeight - 16) }

    var body: some View {
        Group {
            switch activity {
            case .recordingCountdown(let n):
                IslandCompactRow(sideWidth: 34) {
                    recordDot
                } trailing: {
                    Text("\(n)")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.red)
                        .contentTransition(.numericText(countsDown: true))
                }
            case .recording:
                IslandCompactRow(sideWidth: 44) {
                    recordDot
                } trailing: {
                    Button { capture.stopRecording() } label: {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(IslandTimerManager.clock(context.date.timeIntervalSince(capture.recordingStart ?? context.date)))
                                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                                .foregroundStyle(.red)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Stop recording")
                }
            case .cameraRecording:
                IslandCompactRow(sideWidth: 56) {
                    HStack(spacing: 5) {
                        recordDot
                        Image(systemName: "web.camera.fill").font(.system(size: iconSize - 3, weight: .semibold)).foregroundStyle(.white)
                    }
                } trailing: {
                    Button { WebcamManager.shared.stopRecording() } label: {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(IslandTimerManager.clock(context.date.timeIntervalSince(WebcamManager.shared.recordingStart ?? context.date)))
                                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                                .foregroundStyle(.red)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Stop the camera video")
                }
            case .timerRinging:
                IslandCompactRow(sideWidth: 40) {
                    Image(systemName: "timer")
                        .font(.system(size: iconSize, weight: .semibold))
                        .foregroundStyle(.orange)
                        .symbolEffect(.bounce, options: .repeating, value: timers.isRinging)
                } trailing: {
                    Button { timers.stopRinging() } label: {
                        Text("Done").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                }
            case .pill(let pill):
                pillView(pill)
            case .banner(let banner):
                IslandBannerView(banner: banner)
            case .timer:
                if let timer = timers.primaryTimer {
                    let extra = timers.activeTimerCount - 1
                    IslandCompactRow(sideWidth: extra > 0 ? 58 : 44) {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            ProgressRing(progress: timer.progress(at: context.date), tint: timer.isRunning ? .orange : .gray)
                                .frame(width: iconSize, height: iconSize)
                        }
                    } trailing: {
                        HStack(spacing: 3) {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(IslandTimerManager.countdown(timer.remaining(at: context.date)))
                                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                                    .foregroundStyle(timer.isRunning ? .orange : .gray)
                            }
                            if extra > 0 {
                                Text("+\(extra)")
                                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                                    .foregroundStyle(.orange.opacity(0.75))
                            }
                        }
                    }
                }
            case .order(let id):
                if let order = orders.orders.first(where: { $0.id == id }) {
                    IslandCompactRow(sideWidth: 56) {
                        OrderBadge(order: order, size: iconSize + 2)
                    } trailing: {
                        TimelineView(.everyMinute) { context in
                            Text(OrderTracker.compactText(for: order, now: context.date))
                                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                                .foregroundStyle(order.tint)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                }
            case .iPhoneActivity(let id):
                if let la = iphone.activities.first(where: { $0.id == id }) {
                    IslandCompactRow(sideWidth: 56) {
                        HStack(spacing: 4) {
                            Image(systemName: "iphone.gen3")
                                .font(.system(size: iconSize - 2, weight: .semibold))
                                .foregroundStyle(.cyan)
                            if let app = la.appName {
                                Text(app.prefix(1)).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.white)
                            }
                        }
                    } trailing: {
                        Text(IPhoneLiveActivityMirror.compactText(la))
                            .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.cyan)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
            case .calendarSoon:
                if let event = calendar.upcoming {
                    IslandCompactRow(sideWidth: 50) {
                        Image(systemName: "calendar")
                            .font(.system(size: iconSize, weight: .semibold))
                            .foregroundStyle(event.color)
                    } trailing: {
                        TimelineView(.everyMinute) { context in
                            Text(Self.eventCountdown(event, now: context.date))
                                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                                .foregroundStyle(event.color)
                                .lineLimit(1)
                        }
                    }
                }
            case .stopwatch:
                if let stopwatch = timers.primaryStopwatch {
                    let extra = timers.stopwatches.count - 1
                    IslandCompactRow(sideWidth: extra > 0 ? 60 : 48) {
                        Image(systemName: "stopwatch.fill")
                            .font(.system(size: iconSize, weight: .semibold))
                            .foregroundStyle(stopwatch.isRunning ? .orange : .gray)
                    } trailing: {
                        HStack(spacing: 3) {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(IslandTimerManager.clock(stopwatch.elapsed(at: context.date)))
                                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                                    .foregroundStyle(stopwatch.isRunning ? .orange : .gray)
                            }
                            if extra > 0 {
                                Text("+\(extra)")
                                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                                    .foregroundStyle(.orange.opacity(0.75))
                            }
                        }
                    }
                }
            case .awake:
                IslandCompactRow(sideWidth: 44) {
                    Image(systemName: "cup.and.saucer.fill")
                        .font(.system(size: iconSize, weight: .semibold))
                        .foregroundStyle(.orange)
                } trailing: {
                    TimelineView(.everyMinute) { _ in
                        Text(awake.remainingText)
                            .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.orange)
                    }
                }
            case .monitor:
                MonitorCompactView()
            case .aiAttention:
                AICompactView(kind: .attention)
            case .aiWorking:
                AICompactView(kind: .working)
            case .aiUsage:
                AICompactView(kind: .usage)
            case .focus:
                FocusCompactView()
            case .micMuted:
                IslandCompactRow(sideWidth: 52) {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: iconSize, weight: .semibold))
                        .foregroundStyle(.red)
                } trailing: {
                    Text("Muted").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.red)
                }
            case .music:
                EmptyView()
            }
        }
        .transition(.blurReplace.combined(with: .opacity))
    }

    private var recordDot: some View {
        Circle()
            .fill(.red)
            .frame(width: 9, height: 9)
            .phaseAnimator([1.0, 0.35]) { view, phase in
                view.opacity(phase)
            } animation: { _ in .easeInOut(duration: 0.8) }
    }

    @ViewBuilder
    private func pillView(_ pill: IslandPill) -> some View {
        switch pill.kind {
        case .awake(let on, let detail):
            IslandCompactWithDetail(detail: detail, tint: on ? .orange : .gray) {
                IslandCompactRow(sideWidth: 40) {
                    Image(systemName: on ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .font(.system(size: iconSize, weight: .semibold))
                        .foregroundStyle(on ? .orange : .gray)
                        .symbolEffect(.bounce, value: pill.id)
                } trailing: {
                    Text(on ? "On" : "Off")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(on ? .orange : .gray)
                }
            }
        case .copied:
            IslandCompactRow(sideWidth: 52) {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: iconSize - 1, weight: .semibold))
                    .foregroundStyle(.white)
            } trailing: {
                Text("Copied").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.85))
            }
        case .captureSaved(let url, let isVideo):
            IslandCompactRow(sideWidth: 52) {
                CaptureThumbnail(url: url, isVideo: isVideo)
                    .frame(width: iconSize + 6, height: iconSize + 2)
            } trailing: {
                Button { NSWorkspace.shared.open(url) } label: {
                    Text("Saved").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.green)
                }
                .buttonStyle(.plain)
            }
        case .device(let name, let symbol, _) where symbol.hasPrefix("airpod") || symbol.hasPrefix("beats") || name.localizedCaseInsensitiveContains("airpods"):
            EarbudsConnectedIsland(name: name)
        case .device(let name, let symbol, let battery):
            IslandCompactWithDetail(detail: battery.map { "\(name) · \($0)" } ?? name, tint: .white) {
                IslandCompactRow(sideWidth: 64) {
                    Image(systemName: symbol)
                        .font(.system(size: iconSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.bounce, value: pill.id)
                } trailing: {
                    Text("Connected").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.green)
                }
            }
        case .audioOutput(let name, let symbol):
            IslandCompactWithDetail(detail: "Now playing on \(name)", tint: .white) {
                IslandCompactRow(sideWidth: 40) {
                    Image(systemName: symbol)
                        .font(.system(size: iconSize, weight: .semibold))
                        .foregroundStyle(.white)
                } trailing: {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: iconSize - 2))
                        .foregroundStyle(.blue)
                }
            }
        case .download(let url):
            IslandCompactWithDetail(detail: "Downloaded \(url.lastPathComponent)", tint: .white) {
                IslandCompactRow(sideWidth: 30) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(width: iconSize + 4, height: iconSize + 4)
                } trailing: {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: iconSize - 1, weight: .semibold)).foregroundStyle(.blue)
                }
            }
        case .info(let symbol, let text, let tint):
            IslandCompactWithDetail(detail: text, tint: tint) {
                IslandCompactRow(sideWidth: 30) {
                    Image(systemName: symbol).font(.system(size: iconSize, weight: .semibold)).foregroundStyle(tint)
                } trailing: {
                    EmptyView()
                }
            }
        }
    }

    static func eventCountdown(_ event: UpcomingEvent, now: Date) -> String {
        let minutes = Int((event.start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "Now" }
        return "in \(minutes)m"
    }
}

/// A compact row plus a one-line caption underneath (the island grows down a little).
struct IslandCompactWithDetail<Row: View>: View {
    let detail: String
    let tint: Color
    @ViewBuilder var row: () -> Row

    var body: some View {
        VStack(spacing: 2) {
            row()
            Text(detail)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(tint == .white ? .white.opacity(0.85) : tint)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 300)
                .padding(.bottom, 8)
        }
    }
}

// MARK: - Notification banner (grows out of the island)

struct IslandBannerView: View {
    let banner: IslandBanner
    @EnvironmentObject var vm: BoringViewModel
    @State private var hovering = false

    var body: some View {
        // Centered so the row's gap stays exactly over the camera housing.
        VStack(alignment: .center, spacing: 4) {
            IslandCompactRow(sideWidth: 60) {
                icon
            } trailing: {
                HStack(spacing: 4) {
                    if banner.isFromIPhone {
                        Image(systemName: "iphone.gen3").font(.system(size: 10, weight: .semibold))
                    }
                    Text("now").font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.55))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(banner.appName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                if !banner.title.isEmpty {
                    Text(banner.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                Text(banner.body)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 330, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.bottom, 12)
        }
        .contentShape(Rectangle())
        .onHover { h in
            hovering = h
            IslandActivityHub.shared.holdBanner(h)
        }
    }

    @ViewBuilder
    private var icon: some View {
        let size = max(14, vm.effectiveClosedNotchHeight - 12)
        if let image = banner.icon {
            Image(nsImage: image).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: banner.symbol ?? "bell.fill")
                .font(.system(size: size - 6, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(.white.opacity(0.15)))
        }
    }
}

// MARK: - Minimal bubble (second live activity)

struct IslandMinimalBubble: View {
    let activity: IslandCompactActivity
    let diameter: CGFloat
    @ObservedObject private var music = MusicManager.shared
    @ObservedObject private var timers = IslandTimerManager.shared
    @ObservedObject private var orders = OrderTracker.shared
    @ObservedObject private var calendar = UpcomingEventMonitor.shared

    var body: some View {
        ZStack {
            Circle().fill(.black)
            content
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.08), lineWidth: 0.5))
    }

    @ViewBuilder
    private var content: some View {
        let icon = diameter * 0.5
        switch activity {
        case .music:
            Image(nsImage: music.albumArt)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: diameter - 8, height: diameter - 8)
                .clipShape(Circle())
                .rotationEffect(.degrees(music.isPlaying ? 360 : 0))
                .animation(music.isPlaying ? .linear(duration: 12).repeatForever(autoreverses: false) : .default, value: music.isPlaying)
        case .timer:
            if let timer = timers.primaryTimer {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ProgressRing(progress: timer.progress(at: context.date), tint: timer.isRunning ? .orange : .gray)
                        .frame(width: diameter - 10, height: diameter - 10)
                }
            }
        case .stopwatch:
            Image(systemName: "stopwatch.fill").font(.system(size: icon, weight: .semibold)).foregroundStyle(.orange)
        case .awake:
            Image(systemName: "cup.and.saucer.fill").font(.system(size: icon - 1, weight: .semibold)).foregroundStyle(.orange)
        case .cameraRecording:
            Circle().fill(.red).frame(width: diameter * 0.35, height: diameter * 0.35)
        case .recording, .recordingCountdown:
            Circle().fill(.red).frame(width: diameter * 0.35, height: diameter * 0.35)
        case .order(let id):
            if let order = orders.orders.first(where: { $0.id == id }) {
                Image(systemName: OrderTracker.symbol(for: order.category))
                    .font(.system(size: icon - 2, weight: .semibold)).foregroundStyle(order.tint)
            }
        case .iPhoneActivity:
            Image(systemName: "iphone.gen3").font(.system(size: icon, weight: .semibold)).foregroundStyle(.cyan)
        case .calendarSoon:
            Image(systemName: "calendar").font(.system(size: icon - 1, weight: .semibold))
                .foregroundStyle(calendar.upcoming?.color ?? .blue)
        case .timerRinging:
            Image(systemName: "timer").font(.system(size: icon, weight: .semibold)).foregroundStyle(.orange)
        case .monitor:
            MonitorBubbleView(diameter: diameter)
        case .aiAttention:
            AIBubbleView(kind: .attention, diameter: diameter)
        case .aiWorking:
            AIBubbleView(kind: .working, diameter: diameter)
        case .aiUsage:
            AIBubbleView(kind: .usage, diameter: diameter)
        case .micMuted:
            Image(systemName: "mic.slash.fill").font(.system(size: icon - 2, weight: .semibold)).foregroundStyle(.red)
        case .focus:
            FocusBubble(diameter: diameter)
        case .pill, .banner:
            EmptyView()
        }
    }
}

// MARK: - Small building blocks

struct ProgressRing: View {
    let progress: Double
    let tint: Color
    var lineWidth: CGFloat = 2.5

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, 1 - progress))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

struct OrderBadge: View {
    let order: OrderActivity
    let size: CGFloat

    var body: some View {
        if let bundleID = order.bundleID, let icon = AppIconAsNSImage(for: bundleID) {
            Image(nsImage: icon).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: OrderTracker.symbol(for: order.category))
                .font(.system(size: size * 0.62, weight: .semibold))
                .foregroundStyle(order.tint)
                .frame(width: size, height: size)
                .background(Circle().fill(order.tint.opacity(0.18)))
        }
    }
}

struct CaptureThumbnail: View {
    let url: URL
    let isVideo: Bool
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: isVideo ? "video.fill" : "photo.fill").foregroundStyle(.white.opacity(0.8))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .task(id: url) {
            guard !isVideo else { return }
            image = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 96,
                      ] as CFDictionary) else { return nil as NSImage? }
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }.value
        }
    }
}
