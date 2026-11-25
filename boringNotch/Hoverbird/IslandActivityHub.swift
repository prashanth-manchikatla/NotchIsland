//
//  IslandActivityHub.swift
//  Hoverbird
//
//  Decides what the compact (closed) island shows, iPhone-style:
//  one primary activity wraps around the notch and, when something else is
//  also live, a secondary "minimal" bubble floats to its right.
//

import AppKit
import Combine
import Defaults
import SwiftUI

// MARK: - Transient pills & banners

struct IslandPill: Identifiable, Equatable {
    enum Kind: Equatable {
        case awake(on: Bool, detail: String)
        case copied(String)
        case captureSaved(URL, isVideo: Bool)
        case device(name: String, symbol: String, battery: String?)
        case audioOutput(name: String, symbol: String)
        case info(symbol: String, text: String, tint: Color)
        /// A download finished (tap the island → Shelf).
        case download(URL)
    }

    let id = UUID()
    let kind: Kind
    let duration: TimeInterval
}

struct IslandBanner: Identifiable, Equatable {
    let id = UUID()
    var appName: String
    var bundleID: String?
    var title: String
    var body: String
    var isFromIPhone: Bool
    var symbol: String?
    var date = Date()
    /// The mirrored notification behind this banner (tap → open it in the island).
    var notificationID: UUID? = nil

    static func == (lhs: IslandBanner, rhs: IslandBanner) -> Bool { lhs.id == rhs.id }

    var icon: NSImage? {
        guard let bundleID else { return nil }
        return AppIconAsNSImage(for: bundleID)
    }
}

enum IslandCompactActivity: Equatable {
    case recording
    case cameraRecording
    case recordingCountdown(Int)
    case timerRinging
    case pill(IslandPill)
    case banner(IslandBanner)
    case timer
    case order(UUID)
    case iPhoneActivity(String)
    case calendarSoon(String)
    case stopwatch
    case monitor
    /// An AI agent waiting for you (permission / a question). Payload: agent id.
    case aiAttention(String)
    /// AI agents working.
    case aiWorking
    /// 📌 AI usage readout.
    case aiUsage
    /// The microphone is muted while an app is using it (you're in a call).
    case micMuted
    /// A focus session or break is running / paused.
    case focus
    case awake
    case music
}

// MARK: - Hub

@MainActor
final class IslandActivityHub: ObservableObject {
    static let shared = IslandActivityHub()

    @Published private(set) var pill: IslandPill?
    @Published private(set) var banner: IslandBanner?
    /// What the compact island shows (nil → fall back to boring.notch's own states).
    @Published private(set) var primary: IslandCompactActivity?
    /// Optional detached bubble to the right of the island.
    @Published private(set) var secondary: IslandCompactActivity?

    private var pillTask: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Recompute whenever any live source changes (coalesced to one pass per runloop turn).
        let sources: [AnyPublisher<Void, Never>] = [
            AwakeManager.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            IslandTimerManager.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            CaptureManager.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            WebcamManager.shared.$isRecording.map { _ in () }.eraseToAnyPublisher(),
            OrderTracker.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            IPhoneLiveActivityMirror.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            UpcomingEventMonitor.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            MusicManager.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.awakeShowIndicator).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.monitorInIsland).map { _ in () }.eraseToAnyPublisher(),
            AIUsageStore.shared.$attention.map { _ in () }.eraseToAnyPublisher(),
            AIUsageStore.shared.$workingAgents.map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.aiUsageInIsland).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.aiWorkingInIsland).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.aiAttentionInIsland).map { _ in () }.eraseToAnyPublisher(),
            FocusManager.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            MicCameraMonitor.shared.$isMuted.map { _ in () }.eraseToAnyPublisher(),
            MicCameraMonitor.shared.$micInUse.map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.micMutedIndicator).map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(sources)
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] in self?.recompute() }
            .store(in: &cancellables)

        // Awake on/off → brief pill.
        AwakeManager.shared.$lastEvent
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] event in
                guard Defaults[.awakeShowPill] else { return }
                switch event {
                case .started(let detail): self?.showPill(.awake(on: true, detail: detail), duration: 2.4)
                case .ended(let detail): self?.showPill(.awake(on: false, detail: detail), duration: 2.8)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: Transients

    func showPill(_ kind: IslandPill.Kind, duration: TimeInterval = 2.5) {
        let pill = IslandPill(kind: kind, duration: duration)
        withAnimation(Defaults[.islandMotionStyle].interactive) { self.pill = pill }
        recompute()
        pillTask?.cancel()
        pillTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self, self.pill?.id == pill.id else { return }
            withAnimation(Defaults[.islandMotionStyle].interactive) { self.pill = nil }
            self.recompute()
        }
    }

    func dismissPill() {
        pillTask?.cancel()
        withAnimation(Defaults[.islandMotionStyle].interactive) { pill = nil }
        recompute()
    }

    func showBanner(_ banner: IslandBanner) {
        withAnimation(Defaults[.islandMotionStyle].open) { self.banner = banner }
        recompute()
        bannerTask?.cancel()
        let seconds = max(2, Defaults[.notificationBannerSeconds])
        bannerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.banner?.id == banner.id else { return }
            withAnimation(Defaults[.islandMotionStyle].close) { self.banner = nil }
            self.recompute()
        }
    }

    func dismissBanner() {
        bannerTask?.cancel()
        withAnimation(Defaults[.islandMotionStyle].close) { banner = nil }
        recompute()
    }

    /// Keeps a banner on screen while the pointer is over it.
    func holdBanner(_ hold: Bool) {
        guard let banner else { return }
        bannerTask?.cancel()
        guard !hold else { return }
        bannerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.banner?.id == banner.id else { return }
            withAnimation(Defaults[.islandMotionStyle].close) { self.banner = nil }
            self.recompute()
        }
    }

    // MARK: Priority

    func recompute() {
        var live: [IslandCompactActivity] = []
        let capture = CaptureManager.shared
        let timers = IslandTimerManager.shared

        if let n = capture.countdown { live.append(.recordingCountdown(n)) }
        if capture.isRecording { live.append(.recording) }
        if WebcamManager.shared.isRecording { live.append(.cameraRecording) }
        if timers.isRinging { live.append(.timerRinging) }
        if let pill { live.append(.pill(pill)) }
        if let banner { live.append(.banner(banner)) }
        let mic = MicCameraMonitor.shared
        if mic.isMuted && mic.micInUse && Defaults[.micMutedIndicator] { live.append(.micMuted) }
        let ai = AIUsageStore.shared
        if let agent = ai.attention, Defaults[.aiAttentionInIsland] { live.append(.aiAttention(agent.id)) }
        if timers.activeTimerCount > 0 { live.append(.timer) }
        if FocusManager.shared.isActive { live.append(.focus) }
        if let order = OrderTracker.shared.primaryOrder { live.append(.order(order.id)) }
        if let la = IPhoneLiveActivityMirror.shared.primary { live.append(.iPhoneActivity(la.id)) }
        if let soon = UpcomingEventMonitor.shared.upcoming { live.append(.calendarSoon(soon.id)) }
        if timers.isStopwatchActive { live.append(.stopwatch) }
        if !ai.workingAgents.isEmpty, Defaults[.aiWorkingInIsland] { live.append(.aiWorking) }
        if Defaults[.monitorInIsland] { live.append(.monitor) }
        if Defaults[.aiUsageInIsland], ai.snapshot.generated != .distantPast { live.append(.aiUsage) }

        let musicLive = MusicManager.shared.isPlaying || !MusicManager.shared.isPlayerIdle
        let awakeLive = AwakeManager.shared.isActive && Defaults[.awakeShowIndicator]

        var newPrimary: IslandCompactActivity?
        var newSecondary: IslandCompactActivity?

        if let first = live.first {
            newPrimary = first
            // Secondary: next persistent activity, then music, then awake.
            let persistent = live.dropFirst().first { activity in
                switch activity {
                case .pill, .banner, .recordingCountdown: return false
                default: return true
                }
            }
            if case .pill = first, let persistent { newSecondary = persistent }
            else if case .banner = first, let persistent { newSecondary = persistent }
            else if let persistent { newSecondary = persistent }
            else if musicLive { newSecondary = .music }
            else if awakeLive { newSecondary = .awake }
        } else if musicLive {
            newPrimary = nil // boring.notch's own music live activity is primary
            newSecondary = awakeLive ? .awake : nil
        } else if awakeLive {
            newPrimary = .awake
        }

        // Transient pills/banners never become the bubble.
        if case .pill = newSecondary { newSecondary = nil }
        if case .banner = newSecondary { newSecondary = nil }

        if newPrimary != primary || newSecondary != secondary {
            withAnimation(Defaults[.islandMotionStyle].interactive) {
                primary = newPrimary
                secondary = newSecondary
            }
        }
    }
}

// MARK: - Keep the island open while one of its menus is showing

@MainActor
final class IslandInteractionLock: ObservableObject {
    static let shared = IslandInteractionLock()
    @Published private(set) var menuOpen = false
    /// Hoverbird is driving Notification Center (sync / clear) — keep the island open.
    @Published var automationActive = false
    private var observers: [Any] = []

    private init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { IslandInteractionLock.shared.menuOpen = true } })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                // Give the click that dismissed the menu time to land first.
                try? await Task.sleep(for: .milliseconds(250))
                IslandInteractionLock.shared.menuOpen = false
            }
        })
    }

    var isLocked: Bool { menuOpen || automationActive }
}
