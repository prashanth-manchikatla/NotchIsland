//
//  CinemaMode.swift
//  Hoverbird
//
//  Cinema mode: while a video plays full screen (Netflix, Prime Video, YouTube…)
//  the island stays a plain black notch and holds notification banners, then shows
//  "3 notifications while you watched" when you leave full screen. Urgent things — a
//  ringing timer, a recording, a nearly empty battery — still come through.
//
//  Event-driven: it re-checks only when full-screen Spaces or Now Playing change.
//

import AppKit
import Combine
import Defaults
import SwiftUI

/// VLC-style picture modes for full-screen video (see CinemaPicture).
enum CinemaPictureMode: String, CaseIterable, Identifiable, Defaults.Serializable {
    case fit = "Fit"
    case fill = "Fill"
    case smart = "Smart"
    case stretch = "Stretch"
    var id: String { rawValue }

    var help: String {
        switch self {
        case .fit: return "The whole picture, as it was made (black bars where the shape differs)"
        case .fill: return "Zoom until the screen is covered — trims the sides"
        case .smart: return "Cover the screen with the smallest change — trims a little and makes the picture a little taller"
        case .stretch: return "Cover the screen without trimming — the picture gets taller"
        }
    }

    /// Fit → Fill → Smart → Stretch → Fit (the Theater's A key).
    var next: CinemaPictureMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

extension Defaults.Keys {
    static let cinemaModeEnabled = Key<Bool>("cinemaModeEnabled", default: true)
    /// Hold notification banners while a video is full screen.
    static let cinemaHoldNotifications = Key<Bool>("cinemaHoldNotifications", default: true)
    /// "N notifications while you watched" when you leave full screen.
    static let cinemaSummary = Key<Bool>("cinemaSummary", default: true)
    /// Opening the island during a full-screen video lands on the player.
    static let cinemaOpenToPlayer = Key<Bool>("cinemaOpenToPlayer", default: true)
    /// Smart by default: the whole screen with the smallest change to the picture (your choice).
    static let cinemaPictureMode = Key<CinemaPictureMode>("cinemaPictureMode", default: .smart)
    /// Extra zoom on top of the picture mode (1.0 … 1.5), for movies with black bars inside the video.
    static let cinemaZoom = Key<Double>("cinemaZoom", default: 1.0)
}

@MainActor
final class CinemaMode: ObservableObject {
    static let shared = CinemaMode()

    /// A video is playing full screen.
    @Published private(set) var isActive = false
    /// Banners that arrived while it was active.
    @Published private(set) var held: [IslandBanner] = []

    /// The app that went full screen (stays the same if Now Playing switches meanwhile).
    private var activeBundleID: String?
    private var cancellables = Set<AnyCancellable>()

    /// Video players that aren't browsers or streaming apps.
    private static let videoApps: Set<String> = [
        "org.videolan.vlc", "com.colliderli.iina", "io.mpv", "com.apple.QuickTimePlayerX", "com.apple.TV",
        "com.firecore.infuse", "tv.plex.desktop", "com.plexapp.plexmediaplayer", "com.movist.MovistPro",
        "com.elmedia.player", "net.jellyfin.jellyfin-media-player", "com.stremio.stremio",
    ]

    private init() {
        let music = MusicManager.shared
        let sources: [AnyPublisher<Void, Never>] = [
            FullscreenMediaDetector.shared.$fullScreenApps.map { _ in () }.eraseToAnyPublisher(),
            music.$bundleIdentifier.map { _ in () }.eraseToAnyPublisher(),
            music.$isPlaying.map { _ in () }.eraseToAnyPublisher(),
            LiveVideoManager.shared.$ottPlatform.map { _ in () }.eraseToAnyPublisher(),
            CinemaTheater.shared.$isOpen.map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.cinemaModeEnabled).map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(sources)
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] in self?.evaluate() }
            .store(in: &cancellables)
    }

    /// Called at launch so the subscriptions exist before the first full-screen video.
    func start() {}

    static func isVideoSource(_ bundleID: String) -> Bool {
        if videoApps.contains(bundleID) || OTTDetector.isBrowser(bundleID) { return true }
        if bundleID.hasPrefix("com.apple.Safari.WebApp") { return true }
        if LiveVideoManager.shared.ottPlatform != nil, MusicManager.shared.bundleIdentifier == bundleID { return true }
        let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
        return OTTDetector.platform(forApp: bundleID, appName: name) != nil
    }

    private func evaluate() {
        let music = MusicManager.shared
        let fullScreen = FullscreenMediaDetector.shared.fullScreenApps
        var active = false
        var bundle: String?
        if Defaults[.cinemaModeEnabled] {
            if CinemaTheater.shared.isOpen {
                // Hoverbird's own full-screen Theater.
                active = true
                bundle = Bundle.main.bundleIdentifier
            } else if isActive, let id = activeBundleID, id != Bundle.main.bundleIdentifier, fullScreen.contains(id) {
                // Stays on while that app is full screen — paused, between episodes, credits…
                active = true
                bundle = id
            } else if let id = music.bundleIdentifier, !id.isEmpty, music.isPlaying,
                      fullScreen.contains(id), Self.isVideoSource(id) {
                active = true
                bundle = id
            }
        }
        guard active != isActive else { return }
        activeBundleID = bundle
        isActive = active
        if active {
            held = []
            if !CinemaTheater.shared.isOpen { CinemaPicture.shared.cinemaStarted() }
        } else {
            showSummary()
        }
    }

    // MARK: Held notifications

    func shouldHold(_ banner: IslandBanner) -> Bool {
        isActive && Defaults[.cinemaHoldNotifications]
    }

    func hold(_ banner: IslandBanner) {
        held.append(banner)
        if held.count > 99 { held.removeFirst(held.count - 99) }
    }

    private func showSummary() {
        let banners = held
        held = []
        guard !banners.isEmpty, Defaults[.cinemaSummary] else { return }
        let summary: IslandBanner
        if banners.count == 1, let only = banners.first {
            summary = only
        } else {
            var apps: [String] = []
            for banner in banners where !apps.contains(banner.appName) { apps.append(banner.appName) }
            let shown = apps.prefix(3).joined(separator: ", ")
            let more = apps.count > 3 ? " and \(apps.count - 3) more" : ""
            summary = IslandBanner(appName: "While you watched", bundleID: nil,
                                   title: "\(banners.count) notifications",
                                   body: "From \(shown)\(more) · tap to read",
                                   isFromIPhone: banners.contains { $0.isFromIPhone },
                                   symbol: "bell.badge.fill")
        }
        // Let the island finish leaving full screen first.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            IslandActivityHub.shared.showBanner(summary, force: true)
        }
    }
}

extension IslandCompactActivity {
    /// Still shown around the notch while a video is full screen.
    var showsOverFullScreen: Bool {
        switch self {
        case .recording, .cameraRecording, .recordingCountdown, .timerRinging: return true
        case .pill(let pill): return pill.urgent
        default: return false
        }
    }
}
