//
//  LiveVideoManager.swift
//  Hoverbird
//
//  Plays the video you're watching (YouTube in a browser, IINA, VLC,
//  QuickTime, TV…) live inside the island's artwork area.
//
//  How: ScreenCaptureKit captures only the source app's window.
//   • A tiny 4 fps "detect" stream finds the part of the window that is moving
//     (the video player) — no per-site rules, works for any player.
//   • A small "play" stream captures just that rectangle at 30 fps and its
//     frames are shown via an IOSurface-backed layer (zero copies).
//   • Browsers keep windows that never draw (hidden copies, the full-screen window
//     left behind after you exit full screen), so the window is picked by title /
//     main window / on screen, and one that shows nothing — or stops drawing — is
//     swapped for the window you're actually watching in.
//  Both streams run only while the island is open on Home and media is
//  playing, so the feature costs nothing the rest of the time.
//

import AppKit
import Combine
import CoreImage
import CoreMedia
import CoreVideo
import Defaults
import ScreenCaptureKit
import SwiftUI

// MARK: - Settings

enum LiveVideoFrame: String, CaseIterable, Identifiable, Defaults.Serializable {
    case fill = "Fill artwork square"
    case wide = "Wide 16:9"
    var id: String { rawValue }
}

extension Defaults.Keys {
    static let liveVideoEnabled = Key<Bool>("liveVideoEnabled", default: true)
    static let liveVideoFrame = Key<LiveVideoFrame>("liveVideoFrame", default: .wide)
    static let liveVideoFPS = Key<Int>("liveVideoFPS", default: 30)
    /// Keep a low-rate capture ready while a video plays so it appears instantly.
    static let liveVideoPrewarm = Key<Bool>("liveVideoPrewarm", default: true)
}

// MARK: - Manager

@MainActor
final class LiveVideoManager: NSObject, ObservableObject {
    static let shared = LiveVideoManager()

    /// True once real video frames of the playing app are being shown.
    @Published private(set) var hasVideo = false
    /// Aspect ratio (w/h) of the detected video region.
    @Published private(set) var aspect: CGFloat = 16.0 / 9.0
    /// Short explanation shown over the artwork when video can't be shown.
    @Published private(set) var hint: String?
    /// Title of the window the video is captured from (e.g. "… - YouTube").
    private(set) var sourceWindowTitle: String?
    /// A DRM streaming service (Netflix, Prime Video…) is playing: no mirror, show its info instead.
    @Published private(set) var ottPlatform: OTTPlatform?
    private var ottCache: (key: String, platform: OTTPlatform?, date: Date)?
    /// Titles whose video captured as solid black (DRM) — don't try again.
    private var protectedKeys: [String] = []
    /// Titles whose video couldn't be shown (no frames came) → artwork + info instead.
    /// Retried quietly when the island opens again.
    private var failedKeys: [String: Date] = [:]

    fileprivate func setSourceWindowTitle(_ title: String?) { sourceWindowTitle = title }

    private var attachedViews = NSHashTable<LiveVideoLayerView>.weakObjects()
    private var lastSurface: IOSurfaceRef?
    /// Frame rate while the island is closed (just keeps a fresh frame ready).
    static let warmFPS = 2
    private var session: LiveVideoSession?
    private var stopTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var sessionKey: String?

    /// Apps that only play audio — never try to find a video there.
    private static let audioOnlyApps: Set<String> = [
        "com.apple.Music", "com.spotify.client", "com.apple.podcasts", "com.tidal.desktop",
        "com.deezer.deezer-desktop", "com.amazon.music", "com.audible.mac", "com.apple.iBooksX",
    ]

    private override init() {
        super.init()
        let music = MusicManager.shared
        Publishers.CombineLatest3(music.$isPlaying, music.$songTitle, Defaults.publisher(.liveVideoEnabled).map(\.newValue))
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.evaluate() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .screenCapturePermissionChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &cancellables)
        Task { await ScreenCapturePermission.probe() }
    }

    // MARK: View attachment (the island is open on Home)

    func attach(_ view: LiveVideoLayerView) {
        attachedViews.add(view)
        // Show the most recent frame immediately — no waiting for capture to start.
        if let lastSurface { view.show(lastSurface) }
        evaluate()
        session?.relocateSoon()
    }

    func detach(_ view: LiveVideoLayerView) {
        attachedViews.remove(view)
        evaluate()
    }

    fileprivate func deliver(_ surface: IOSurfaceRef) {
        lastSurface = surface
        if let key = sessionKey, failedKeys[key] != nil { failedKeys[key] = nil }
        for view in attachedViews.allObjects {
            view.show(surface)
        }
        if !hasVideo {
            withAnimation(.easeInOut(duration: 0.35)) { hasVideo = true }
        }
    }

    fileprivate func setHint(_ text: String?) {
        if hint != text { withAnimation(.easeInOut(duration: 0.25)) { hint = text } }
    }

    fileprivate func updateAspect(_ value: CGFloat) {
        if abs(value - aspect) > 0.02 { aspect = value }
    }

    // MARK: Lifecycle

    private func evaluate() {
        let music = MusicManager.shared
        let bundleID = music.bundleIdentifier ?? ""
        let visible = !attachedViews.allObjects.isEmpty
        let key = bundleID + "|" + music.songTitle
        // Streaming services are DRM-protected (capture is black): show their info instead.
        let platform = streamingPlatform(bundleID: bundleID, key: key)
        if platform != ottPlatform {
            withAnimation(.easeInOut(duration: 0.25)) { ottPlatform = platform }
        }
        if platform != nil, session != nil {
            stopTask?.cancel()
            stopSession()
        }
        // Video that didn't work: show the artwork; try again only when the island opens.
        let retryAllowed = failedKeys[key].map { visible && Date().timeIntervalSince($0) >= 8 } ?? true
        let eligible = Defaults[.liveVideoEnabled]
            && music.isPlaying
            && !bundleID.isEmpty
            && !Self.audioOnlyApps.contains(bundleID)
            && bundleID != Bundle.main.bundleIdentifier // our own Theater: never capture ourselves
            && platform == nil
            && (retryAllowed || sessionKey == key)
            && ScreenCapturePermission.isGranted
        let wanted = eligible && (visible || Defaults[.liveVideoPrewarm])

        if wanted {
            stopTask?.cancel()
            stopTask = nil
            if session == nil || sessionKey != key {
                startSession(bundleID: bundleID, title: music.songTitle, key: key)
            }
            session?.setFrameRate(visible ? Defaults[.liveVideoFPS] : Self.warmFPS, visible: visible)
        } else if session != nil, stopTask == nil {
            // Grace period so quick open/close, pauses or track changes don't thrash.
            let grace: Double = music.isPlaying ? 1.5 : 10
            stopTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(grace))
                guard !Task.isCancelled else { return }
                self?.stopSession()
            }
        }
    }

    private func streamingPlatform(bundleID: String, key: String) -> OTTPlatform? {
        guard !bundleID.isEmpty, !Self.audioOnlyApps.contains(bundleID) else { return nil }
        // Hoverbird Cinema: video playing in our own full-screen Theater.
        if bundleID == Bundle.main.bundleIdentifier {
            return CinemaTheater.shared.isOpen ? CinemaTheater.shared.platform : nil
        }
        if protectedKeys.contains(key) {
            let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
            return OTTPlatform(name: app.map { "\($0) · protected" } ?? "Protected video", tint: .gray, detectedByBlackFrames: true)
        }
        if let cache = ottCache, cache.key == key, Date().timeIntervalSince(cache.date) < 20 { return cache.platform }
        let music = MusicManager.shared
        let platform = OTTDetector.detect(bundleID: bundleID, title: music.songTitle, artist: music.artistName, album: music.album)
        ottCache = (key, platform, Date())
        return platform
    }

    /// No video frames arrived (player not found, window not drawing…): show the artwork.
    fileprivate func markFailed(key: String) {
        failedKeys[key] = Date()
        if failedKeys.count > 60 {
            failedKeys = failedKeys.filter { Date().timeIntervalSince($0.value) < 3600 }
        }
        if sessionKey == key {
            stopTask?.cancel()
            stopSession()
        }
    }

    /// The captured video stayed solid black: it's DRM-protected, fall back to the info view.
    fileprivate func markProtected(key: String) {
        guard !protectedKeys.contains(key) else { return }
        protectedKeys.append(key)
        if protectedKeys.count > 40 { protectedKeys.removeFirst() }
        ottCache = nil
        evaluate()
    }

    private func startSession(bundleID: String, title: String, key: String) {
        session?.stop()
        session = nil
        hasVideo = false
        sessionKey = key
        let newSession = LiveVideoSession(manager: self)
        session = newSession
        let visible = !attachedViews.allObjects.isEmpty
        Task { @MainActor in
            let ok = await newSession.start(bundleID: bundleID, title: title, key: key,
                                            fps: visible ? Defaults[.liveVideoFPS] : Self.warmFPS)
            if !ok, self.session === newSession {
                self.session = nil
                self.sessionKey = nil
                self.failedKeys[key] = Date()
            }
        }
    }

    private func stopSession() {
        stopTask = nil
        hint = nil
        session?.stop()
        session = nil
        sessionKey = nil
        lastSurface = nil
        if hasVideo { withAnimation(.easeInOut(duration: 0.3)) { hasVideo = false } }
        for view in attachedViews.allObjects { view.clear() }
    }

    /// Bring the window that is playing to the front.
    func activateSource() {
        guard let bundleID = MusicManager.shared.bundleIdentifier,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return }
        app.activate()
    }
}

// MARK: - One capture session (detect + play streams for one window)

final class LiveVideoSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Last known player rectangle (window-relative) per app + window size, so the
    /// video keeps working when its window is on another Space.
    private static var cropCache: [String: CGRect] = {
        // Survives restarts: [key: "x,y,w,h"]
        let stored = UserDefaults.standard.dictionary(forKey: "Hoverbird.videoCropCache") as? [String: String] ?? [:]
        return stored.compactMapValues { NSRectFromString($0) == .zero ? nil : NSRectFromString($0) }
    }() {
        didSet {
            UserDefaults.standard.set(cropCache.mapValues { NSStringFromRect($0) }, forKey: "Hoverbird.videoCropCache")
        }
    }
    private static let cacheLock = NSLock()
    /// Windows that just showed nothing at all — hidden copies, the full-screen window a
    /// browser keeps after you leave full screen, minimized windows — are tried last for a while.
    private static var deadWindows: [CGWindowID: Date] = [:]
    private var cacheKey = ""
    private var bundleID = ""
    /// Start of the playing title, lowercased (browsers put it in the window title).
    private var titleNeedle = ""
    // Windows to try, best first, and the app's main window when they were ranked (queue-confined).
    private var candidates: [SCWindow] = []
    private var candidateIndex = 0
    private var pickedWithMainID: CGWindowID?
    private var repicks = 0
    private var lastRepick: Date = .distantPast
    private var watchTimer: DispatchSourceTimer?
    private var rememberedGeneration = -1

    private static func goodWindowID(for bundleID: String) -> CGWindowID? {
        let stored = UserDefaults.standard.dictionary(forKey: "Hoverbird.videoWindows") as? [String: Int]
        return stored?[bundleID].map { CGWindowID($0) }
    }

    private static func rememberGoodWindow(_ id: CGWindowID, for bundleID: String) {
        var stored = UserDefaults.standard.dictionary(forKey: "Hoverbird.videoWindows") as? [String: Int] ?? [:]
        guard stored[bundleID] != Int(id) else { return }
        stored[bundleID] = Int(id)
        UserDefaults.standard.set(stored, forKey: "Hoverbird.videoWindows")
    }

    private static func forgetGoodWindow(_ id: CGWindowID, for bundleID: String) {
        var stored = UserDefaults.standard.dictionary(forKey: "Hoverbird.videoWindows") as? [String: Int] ?? [:]
        guard stored[bundleID] == Int(id) else { return }
        stored[bundleID] = nil
        UserDefaults.standard.set(stored, forKey: "Hoverbird.videoWindows")
    }

    private static func markDead(_ id: CGWindowID) {
        cacheLock.withLock {
            let now = Date()
            deadWindows = deadWindows.filter { now.timeIntervalSince($0.value) < 30 }
            deadWindows[id] = now
        }
    }

    private static func isDead(_ id: CGWindowID) -> Bool {
        cacheLock.withLock { deadWindows[id].map { Date().timeIntervalSince($0) < 30 } ?? false }
    }

    private static func clearDead(_ id: CGWindowID) {
        _ = cacheLock.withLock { deadWindows.removeValue(forKey: id) }
    }

    /// The app's main window as a window-server ID: where you're watching (also for windows
    /// on other Spaces). Accessibility IPC — never on the main thread.
    private static func mainWindowID(pid: pid_t) -> CGWindowID? {
        let app = AX.app(pid: pid)
        guard let main = AX.elements(app, kAXMainWindowAttribute as String).first
                ?? AX.elements(app, kAXFocusedWindowAttribute as String).first else { return nil }
        return AX.windowID(of: main)
    }

    /// Size, layer and title of one window (a cheap window-server lookup).
    private static func windowInfo(_ id: CGWindowID) -> (size: CGSize, layer: Int, title: String)? {
        guard let entry = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
        return (rect.size, entry[kCGWindowLayer as String] as? Int ?? 0, entry[kCGWindowName as String] as? String ?? "")
    }

    private static func candidateWindows(in content: SCShareableContent, bundleID: String) -> [SCWindow] {
        content.windows.filter {
            $0.owningApplication?.bundleIdentifier == bundleID && $0.windowLayer == 0
                && $0.frame.width >= 240 && $0.frame.height >= 160
        }
    }

    /// Local file players (no DRM).
    private static let localPlayers: Set<String> = ["com.colliderli.iina", "org.videolan.vlc", "com.apple.QuickTimePlayerX",
                                                    "com.firecore.infuse", "io.mpv", "com.movist.MovistPro", "com.Eltima.ElmediaPlayer"]

    private static let browserPrefixes = ["com.apple.Safari", "com.google.Chrome", "com.brave.Browser", "company.thebrowser",
                                          "com.microsoft.edgemac", "org.mozilla.firefox", "com.operasoftware", "com.vivaldi",
                                          "com.kagi.kagimacOS", "app.zen-browser"]
    private var isBrowser: Bool { Self.browserPrefixes.contains { bundleID.hasPrefix($0) } }

    private weak var manager: LiveVideoManager?
    private let queue = DispatchQueue(label: "Hoverbird.LiveVideo", qos: .userInitiated)
    // Stream references and the per-window bookkeeping are touched from the main
    // thread, the capture queue and Tasks, so they live behind a lock.
    private let lock = NSLock()
    private var _detectStream: SCStream?
    private var _playStream: SCStream?
    private var _stopped = false
    /// Bumped whenever another window is picked; work started for an older pick is dropped.
    private var _generation = 0
    /// Complete frames the current window has sent, and since when it has been reporting
    /// "suspended" (not drawing at all).
    private var _windowCompleteFrames = 0
    private var _deadSince: Date?
    private var _checkedGeneration = -1
    private var _playStartingGeneration: Int?
    private var _pendingPlayConfig: SCStreamConfiguration?
    private var detectStream: SCStream? {
        get { lock.withLock { _detectStream } }
        set { lock.withLock { _detectStream = newValue } }
    }
    private var playStream: SCStream? {
        get { lock.withLock { _playStream } }
        set { lock.withLock { _playStream = newValue } }
    }
    private var stopped: Bool {
        get { lock.withLock { _stopped } }
        set { lock.withLock { _stopped = newValue } }
    }
    private var generation: Int { lock.withLock { _generation } }
    private var window: SCWindow?
    private var tuning = IslandTuning()
    private var debug = false
    private var deliveredFrames = 0
    private var detectFrames = 0
    private var droppedFrames = 0
    private var windowSize: CGSize = .zero
    private var detectSize: (w: Int, h: Int) = (0, 0)
    private var fps = 30

    // DRM detection (queue-confined): protected video is captured as solid black.
    private var sessionKey = ""
    private var checksBlackFrames = true
    private var blackSince: Date?
    private var lastBlackCheck: Date = .distantPast
    private var reportedProtected = false

    // Motion analysis state (queue-confined)
    private var prevLuma: [UInt8] = []
    private var heat: [UInt8] = []
    private var analyzedFrames = 0
    private var currentCrop: CGRect?
    private var pendingCrop: CGRect?
    private var pendingHits = 0

    init(manager: LiveVideoManager) {
        self.manager = manager
    }

    @MainActor
    func start(bundleID: String, title: String, key: String, fps: Int) async -> Bool {
        self.fps = max(1, min(60, fps))
        self.sessionKey = key
        // YouTube and local players are never DRM-protected; dark scenes must not switch them off.
        checksBlackFrames = !(title.lowercased().contains("youtube") || bundleID.lowercased().contains("youtube")
                              || Self.localPlayers.contains(bundleID))
        scheduleGiveUp()
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return false }
        // Never run the DRM (black video) check on YouTube — also when it plays in Picture in Picture.
        let youTubeNeedle = String(title.prefix(24)).lowercased()
        let appName = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName?.lowercased() ?? ""
        if appName.contains("youtube") || content.windows.contains(where: { w in
            guard w.owningApplication?.bundleIdentifier == bundleID else { return false }
            let t = (w.title ?? "").lowercased()
            return t.contains("youtube") && (youTubeNeedle.isEmpty || t.contains(youTubeNeedle))
        }) {
            checksBlackFrames = false
        }

        if IslandTuning.current.liveVideoDebug ?? false {
            var lines = "windows for \(bundleID) / PiP:\n"
            for w in content.windows where w.owningApplication?.bundleIdentifier == bundleID
                || w.owningApplication?.bundleIdentifier == "com.apple.PIPAgent"
                || (w.title ?? "").lowercased().contains("picture") {
                lines += "   [\(w.owningApplication?.bundleIdentifier ?? "?")] id=\(w.windowID) layer=\(w.windowLayer) onScreen=\(w.isOnScreen) active=\(w.isActive) frame=\(w.frame) title=\"\(w.title ?? "")\"\n"
            }
            IslandDebugLog.write("livevideo-debug.txt", lines, reset: true)
        }

        // 1. Picture in Picture keeps drawing even when the browser is hidden — use it directly.
        let pip = content.windows.filter { w in
            let owner = w.owningApplication?.bundleIdentifier ?? ""
            let title = (w.title ?? "").lowercased()
            let isPiP = owner == "com.apple.PIPAgent" || (owner == bundleID && title.contains("picture in picture"))
            return isPiP && w.isOnScreen && w.frame.width >= 120 && w.frame.height >= 68
        }.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        if let pip {
            isPiP = true
            self.window = pip
            windowSize = pip.frame.size
            debug = IslandTuning.current.liveVideoDebug ?? false
            if debug { IslandDebugLog.write("livevideo-debug.txt", "using Picture in Picture window \(pip.frame) owner=\(pip.owningApplication?.bundleIdentifier ?? "?")", reset: true) }
            currentCrop = CGRect(origin: .zero, size: windowSize)
            applyCrop(CGRect(origin: .zero, size: windowSize), fullWindow: true)
            return true
        }

        // 2. Otherwise watch the app's own window and find the moving player area.
        let windows = Self.candidateWindows(in: content, bundleID: bundleID)
        guard !windows.isEmpty else { return false }
        self.bundleID = bundleID
        titleNeedle = String(title.prefix(24)).lowercased()
        tuning = IslandTuning.current
        debug = tuning.liveVideoDebug ?? false
        if debug { IslandDebugLog.write("livevideo-debug.txt", "start app=\(bundleID) title=\"\(title)\" candidates=\(windows.count)") }
        let (ranked, mainID) = await rank(windows)
        queue.sync {
            candidates = ranked
            candidateIndex = 0
            pickedWithMainID = mainID
        }
        return await begin(on: ranked[0], generation: 0)
    }

    /// Best window first: one showing this video's title, the app's main window (where
    /// you're watching), on screen, active, then the one that worked last time. Windows
    /// that just showed nothing go last.
    private func rank(_ windows: [SCWindow]) async -> (windows: [SCWindow], mainID: CGWindowID?) {
        let needle = titleNeedle
        let remembered = Self.goodWindowID(for: bundleID)
        var mainID: CGWindowID?
        if let pid = windows.first?.owningApplication?.processID {
            mainID = await Task.detached(priority: .userInitiated) { Self.mainWindowID(pid: pid) }.value
        }
        let anyTitleMatch = !needle.isEmpty && windows.contains { ($0.title ?? "").lowercased().contains(needle) }
        func score(_ w: SCWindow) -> Double {
            let t = (w.title ?? "").lowercased()
            let titleMatch = !needle.isEmpty && t.contains(needle)
            var value = 0.0
            if titleMatch { value += 60 }
            // Where you're watching — unless another window shows this video's title.
            if w.windowID == mainID, titleMatch || !anyTitleMatch { value += 45 }
            if w.isOnScreen { value += 30 }
            if w.isActive { value += 15 }
            if w.windowID == remembered { value += 20 }
            if t.isEmpty { value -= 25 }
            if Self.isDead(w.windowID) { value -= 150 }
            return value + Double(w.frame.width * w.frame.height) / 10_000_000
        }
        let scored = windows.map { ($0, score($0)) }.sorted { $0.1 > $1.1 }
        if debug {
            let lines = scored.map { "   id=\($0.0.windowID) score=\(Int($0.1)) onScreen=\($0.0.isOnScreen) frame=\($0.0.frame) \"\($0.0.title ?? "")\"" }
            IslandDebugLog.write("livevideo-debug.txt", "candidates (main window \(mainID.map { String($0) } ?? "?")):\n" + lines.joined(separator: "\n"))
        }
        return (scored.map(\.0), mainID)
    }

    /// Starts watching one window: Accessibility (the player's exact frame) → where the
    /// player was last time → motion detection. A window that sends no picture is swapped
    /// for the next candidate within ~1.5 s (noteStreamStarted).
    private func begin(on window: SCWindow, generation: Int) async -> Bool {
        guard !stopped, self.generation == generation else { return false }
        let size = window.frame.size
        let key = "\(bundleID)|\(Int(size.width))x\(Int(size.height))"
        let dw = 256
        let dh = max(64, Int((CGFloat(dw) * size.height / max(1, size.width)).rounded())) & ~1
        let detectConfig: SCStreamConfiguration = queue.sync {
            self.window = window
            windowSize = size
            cacheKey = key
            detectSize = (dw, dh)
            return detectConfiguration(visible: islandVisible)
        }
        let chosenTitle = window.title
        if (chosenTitle ?? "").lowercased().contains("youtube") { checksBlackFrames = false }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.manager?.setSourceWindowTitle(chosenTitle) }
        }
        if debug {
            IslandDebugLog.write("livevideo-debug.txt",
                "watching id=\(window.windowID) \"\(chosenTitle ?? "")\" frame=\(window.frame) onScreen=\(window.isOnScreen) (pick \(generation))")
        }

        // Precise path: ask the browser's accessibility tree where the player is.
        if let pid = window.owningApplication?.processID, await startAXTracking(pid: pid, window: window, generation: generation) {
            return true
        }
        guard !stopped, self.generation == generation else { return false }
        // Next best: where the player was last time we could see it (then keep refining below).
        if let cached = Self.cacheLock.withLock({ Self.cropCache[key] }) {
            let fullPage = isBrowser && cached.width > size.width * 0.92 && cached.height > size.height * 0.85
            if fullPage {
                Self.cacheLock.withLock { Self.cropCache[key] = nil }
            } else {
                if debug { IslandDebugLog.write("livevideo-debug.txt", "using remembered player position \(cached)") }
                queue.async { [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.currentCrop = cached
                    self.applyCrop(cached)
                }
            }
        }

        // Fallback: detect stream — whole window, tiny, 4 fps — finds the moving area.
        let detect = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: detectConfig, delegate: self)
        // Register before starting so the very first (full) frame isn't dropped.
        let registered = lock.withLock { () -> Bool in
            guard !_stopped, _generation == generation else { return false }
            _detectStream = detect
            return true
        }
        guard registered else { return false }
        do {
            try detect.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await detect.startCapture()
        } catch {
            lock.withLock { if _detectStream === detect { _detectStream = nil } }
            if debug { IslandDebugLog.write("livevideo-debug.txt", "detect stream failed: \(error.localizedDescription)") }
            queue.async { [weak self] in self?.windowIsDead(generation: generation, reason: "can't be captured") }
            return true
        }
        if stopped || self.generation != generation {
            try? await detect.stopCapture()
            return false
        }
        noteStreamStarted(generation: generation)
        scheduleDrawingWatchdog(generation: generation)
        return true
    }

    private func detectConfiguration(visible: Bool) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = detectSize.w
        config.height = detectSize.h
        config.minimumFrameInterval = CMTime(value: 1, timescale: visible ? 4 : 1)
        config.showsCursor = false
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.scalesToFit = true
        config.preservesAspectRatio = true
        return config
    }

    // MARK: Picking the right window

    /// A stream on the current window is running: check that it really sends pictures.
    private func noteStreamStarted(generation: Int) {
        let first = lock.withLock { () -> Bool in
            guard _generation == generation, _checkedGeneration != generation else { return false }
            _checkedGeneration = generation
            return true
        }
        guard first else { return }
        queue.async { [weak self] in self?.updateWatchTimer() }
        // A window that can draw sends its first complete frame right away — even a paused video.
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.stopped else { return }
            let complete: Int? = self.lock.withLock { self._generation == generation ? self._windowCompleteFrames : nil }
            guard complete == 0 else { return }
            self.windowIsDead(generation: generation, reason: "sent no picture")
        }
    }

    /// Queue: the watched window draws nothing (a hidden copy, the full-screen window left
    /// behind after leaving full screen, minimized…). Try it last for a while and move on.
    private func windowIsDead(generation: Int, reason: String) {
        guard !stopped, let window, self.generation == generation else { return }
        Self.markDead(window.windowID)
        Self.forgetGoodWindow(window.windowID, for: bundleID)
        if debug { IslandDebugLog.write("livevideo-debug.txt", "window id=\(window.windowID) \(reason)") }
        if let next = candidates.indices.dropFirst(candidateIndex + 1).first(where: { !Self.isDead(candidates[$0].windowID) }) {
            candidateIndex = next
            switchTo(candidates[next], from: generation)
        } else {
            repick(from: generation, reason: reason)
        }
    }

    /// Queue: stop watching the current window and start on `next`.
    private func switchTo(_ next: SCWindow, from generation: Int) {
        guard let newGeneration = claimNewPick(from: generation) else { return }
        Task { [weak self] in
            _ = await self?.begin(on: next, generation: newGeneration)
        }
    }

    /// Queue: pick again from a fresh window list — the window stopped drawing, or you're
    /// now watching in another window of the app (entered or left full screen…).
    private func repick(from generation: Int, reason: String) {
        guard !stopped, !isPiP, self.generation == generation else { return }
        let wait = 2.5 - Date().timeIntervalSince(lastRepick)
        if wait > 0 {
            queue.asyncAfter(deadline: .now() + wait) { [weak self] in self?.repick(from: generation, reason: reason) }
            return
        }
        guard repicks < 8 else {
            giveUp(reason: "the window keeps changing")
            return
        }
        guard let newGeneration = claimNewPick(from: generation) else { return }
        lastRepick = Date()
        repicks += 1
        if debug { IslandDebugLog.write("livevideo-debug.txt", "picking the window again (\(reason))") }
        let bundleID = self.bundleID
        Task { [weak self] in
            guard let self else { return }
            let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            guard !self.stopped, self.generation == newGeneration else { return }
            let (ranked, mainID) = await self.rank(content.map { Self.candidateWindows(in: $0, bundleID: bundleID) } ?? [])
            guard !self.stopped, self.generation == newGeneration else { return }
            guard let best = ranked.first, !Self.isDead(best.windowID) else {
                self.giveUp(reason: reason)
                return
            }
            self.queue.sync {
                self.candidates = ranked
                self.candidateIndex = 0
                self.pickedWithMainID = mainID
            }
            _ = await self.begin(on: best, generation: newGeneration)
        }
    }

    /// Queue: retire the current window's streams and state; returns the new pick's number.
    private func claimNewPick(from generation: Int) -> Int? {
        let claimed: (Int, SCStream?, SCStream?)? = lock.withLock {
            guard !_stopped, _generation == generation else { return nil }
            _generation += 1
            _windowCompleteFrames = 0
            _deadSince = nil
            _playStartingGeneration = nil
            _pendingPlayConfig = nil
            defer { _detectStream = nil; _playStream = nil }
            return (_generation, _detectStream, _playStream)
        }
        guard let claimed else { return nil }
        let (newGeneration, oldDetect, oldPlay) = claimed
        Task {
            try? await oldDetect?.stopCapture()
            try? await oldPlay?.stopCapture()
        }
        axTimer?.cancel()
        axTimer = nil
        axPID = 0
        axElement = nil
        currentCrop = nil
        pendingCrop = nil
        pendingHits = 0
        prevLuma = []
        heat = []
        analyzedFrames = 0
        droppedFrames = 0
        window = nil
        return newGeneration
    }

    /// No window shows the video: the island shows the artwork and info instead.
    private func giveUp(reason: String) {
        let key = sessionKey
        if debug { IslandDebugLog.write("livevideo-debug.txt", "no window shows the video (\(reason)) — showing the artwork instead") }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.manager?.markFailed(key: key) }
        }
    }

    /// Queue: while the island is open, check every 2 s that the video is still where we look.
    private func updateWatchTimer() {
        watchTimer?.cancel()
        watchTimer = nil
        guard islandVisible, !isPiP, !stopped else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.watchWindow() }
        timer.resume()
        watchTimer = timer
    }

    /// Queue: follow the video when its window stops drawing, or when you move to another
    /// window of the app (entering or leaving full screen, another browser window…).
    private func watchWindow() {
        guard !stopped, !isPiP, let window else { return }
        let generation = self.generation
        if let since = lock.withLock({ _deadSince }), Date().timeIntervalSince(since) >= 1.5 {
            windowIsDead(generation: generation, reason: "stopped drawing")
            return
        }
        guard let pid = window.owningApplication?.processID,
              let main = Self.mainWindowID(pid: pid), main != window.windowID, main != pickedWithMainID,
              !Self.isDead(main), let info = Self.windowInfo(main),
              info.layer == 0, info.size.width >= 240, info.size.height >= 160,
              titleNeedle.isEmpty || info.title.lowercased().contains(titleNeedle) else { return }
        repick(from: generation, reason: "now watching in window id=\(main)")
    }

    private var axPID: pid_t = 0
    private var axTimer: DispatchSourceTimer?
    private var axElement: AXUIElement?
    private var axWindowFrame: CGRect = .zero
    private var isPiP = false
    private var islandVisible = false
    private var axWindowTitle: String?

    /// Switch between the warm (closed) and live (open) frame rate.
    func setFrameRate(_ newFPS: Int, visible: Bool) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            let visibilityChanged = visible != self.islandVisible
            self.islandVisible = visible
            if visibilityChanged {
                self.rescheduleAXTimer()
                self.updateWatchTimer()
                if let detect = self.detectStream {
                    let config = self.detectConfiguration(visible: visible)
                    Task { try? await detect.updateConfiguration(config) }
                }
                // Just opened: catch up on anything that changed while it was closed.
                if visible { self.watchWindow() }
            }
            guard newFPS != self.fps else { return }
            if self.debug { IslandDebugLog.write("livevideo-debug.txt", "frame rate \(self.fps) -> \(newFPS) (island \(visible ? "open" : "closed"))") }
            self.fps = newFPS
            if let crop = self.currentCrop, self.playStream != nil {
                self.applyCrop(crop, fullWindow: self.isPiP)
            }
        }
    }

    /// Re-check where the player is right away (e.g. the island just opened).
    func relocateSoon() {
        queue.async { [weak self] in self?.relocateAX() }
    }

    private func rescheduleAXTimer() {
        guard axTimer != nil || axPID != 0 else { return }
        axTimer?.cancel()
        let interval: Double = islandVisible ? 3 : 30
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.relocateAX() }
        timer.resume()
        axTimer = timer
    }

    /// Cheap path: re-read the known player element's frame (2 IPCs). Full search only if it vanished.
    private func relocateAX() {
        guard !stopped, axPID != 0 else { return }
        if let element = axElement, let pos = AX.position(element), let size = AX.size(element), size.width >= 80 {
            applyAXFrame(CGRect(origin: pos, size: size), windowFrame: axWindowFrame)
            return
        }
        guard let found = VideoElementLocator.locate(pid: axPID, windowFrame: axWindowFrame, windowTitle: axWindowTitle) else { return }
        axElement = found.element
        applyAXFrame(found.frame, windowFrame: axWindowFrame)
    }

    /// Locates the player via Accessibility; keeps following it every few seconds.
    private func startAXTracking(pid: pid_t, window: SCWindow, generation: Int) async -> Bool {
        let windowFrame = window.frame
        // The tree walk does IPC to the browser — keep it off the main thread.
        let title = window.title
        let logger: (String) -> Void = { [debug] line in if debug { IslandDebugLog.write("livevideo-debug.txt", line) } }
        let found = await Task.detached(priority: .userInitiated) {
            VideoElementLocator.locate(pid: pid, windowFrame: windowFrame, windowTitle: title, log: logger)
        }.value
        guard let found, !stopped, self.generation == generation else {
            if debug && found == nil { IslandDebugLog.write("livevideo-debug.txt", "accessibility: no video element found, using motion detection") }
            return false
        }
        if debug { IslandDebugLog.write("livevideo-debug.txt", "accessibility: \"\(found.label)\" at \(found.frame)") }
        queue.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.axPID = pid
            self.axElement = found.element
            self.axWindowFrame = windowFrame
            self.axWindowTitle = title
            self.applyAXFrame(found.frame, windowFrame: windowFrame)
            self.rescheduleAXTimer()
        }
        return true
    }

    private func applyAXFrame(_ frame: CGRect, windowFrame: CGRect) {
        var crop = CGRect(x: frame.minX - windowFrame.minX, y: frame.minY - windowFrame.minY,
                          width: frame.width, height: frame.height).integral
        crop = crop.intersection(CGRect(origin: .zero, size: windowFrame.size))
        guard crop.width >= 80, crop.height >= 45 else { return }
        if let current = currentCrop, Self.iou(current, crop) > 0.92 { return }
        currentCrop = crop
        Self.cacheLock.withLock { Self.cropCache[cacheKey] = crop }
        if debug { IslandDebugLog.write("livevideo-debug.txt", "crop (accessibility) \(crop)") }
        applyCrop(crop)
    }

    /// Motion detection found nothing yet: a window that isn't repainting (e.g. a hidden
    /// snapshot copy) is swapped for the next candidate.
    private func scheduleDrawingWatchdog(generation: Int) {
        queue.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, !self.stopped, self.generation == generation, self.currentCrop == nil else { return }
            let stalled = self.analyzedFrames <= 2
            if self.debug {
                IslandDebugLog.write("livevideo-debug.txt", "watchdog: analyzed=\(self.analyzedFrames) idle=\(self.droppedFrames) stalled=\(stalled)")
            }
            if stalled {
                self.windowIsDead(generation: generation, reason: "isn't repainting")
            } else {
                // Keep looking; if nothing shows up, the give-up timer falls back to the artwork.
                self.scheduleDrawingWatchdog(generation: generation)
            }
        }
    }

    /// No frames after 8 s → the island shows the artwork and the info instead.
    private func scheduleGiveUp() {
        queue.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, !self.stopped, self.deliveredFrames == 0 else { return }
            let key = self.sessionKey
            if self.debug { IslandDebugLog.write("livevideo-debug.txt", "no video frames after 8 s — showing the artwork instead") }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.manager?.markFailed(key: key) }
            }
        }
    }

    func stop() {
        let (d, p): (SCStream?, SCStream?) = lock.withLock {
            _stopped = true
            defer { _detectStream = nil; _playStream = nil }
            return (_detectStream, _playStream)
        }
        queue.async { [weak self] in
            self?.axTimer?.cancel()
            self?.axTimer = nil
            self?.watchTimer?.cancel()
            self?.watchTimer = nil
        }
        Task {
            try? await d?.stopCapture()
            try? await p?.stopCapture()
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !stopped, sampleBuffer.isValid else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        let statusRaw = attachments?.first?[.status] as? Int
        let status = statusRaw.flatMap { SCFrameStatus(rawValue: $0) }
        guard status == .complete, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            droppedFrames += 1
            // "Suspended"/"blank": the window isn't drawing at all (hidden, minimized, the
            // full-screen copy left behind…). "Idle" only means nothing changed on screen.
            if status == .suspended || status == .blank || status == .idle {
                let notDrawing = status != .idle
                lock.withLock {
                    guard stream === _playStream || stream === _detectStream else { return }
                    if notDrawing {
                        if _deadSince == nil { _deadSince = Date() }
                    } else {
                        _deadSince = nil
                    }
                }
            }
            if debug && (droppedFrames == 1 || droppedFrames % 50 == 0) {
                IslandDebugLog.write("livevideo-debug.txt", "non-complete frame #\(droppedFrames) status=\(statusRaw.map(String.init) ?? "nil") attachments=\(attachments == nil ? "nil" : "ok")")
            }
            return
        }

        let (isPlay, isDetect, generation) = lock.withLock { () -> (Bool, Bool, Int) in
            let play = stream === _playStream, detect = stream === _detectStream
            if play || detect {
                _windowCompleteFrames += 1
                _deadSince = nil
            }
            return (play, detect, _generation)
        }
        if isPlay {
            guard let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
            deliveredFrames += 1
            checkProtected(pixelBuffer)
            if rememberedGeneration != generation {
                // This window really shows the video: start with it next time.
                rememberedGeneration = generation
                if !isPiP, !bundleID.isEmpty, let window {
                    Self.rememberGoodWindow(window.windowID, for: bundleID)
                    Self.clearDead(window.windowID)
                }
            }
            if deliveredFrames == 1 {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.manager?.setHint(nil) }
                }
            }
            if debug && (deliveredFrames == 1 || deliveredFrames == 300) {
                IslandDebugLog.write("livevideo-debug.txt", "play frames delivered: \(deliveredFrames) (\(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer)))")
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped else { return }
                MainActor.assumeIsolated { self.manager?.deliver(surface) }
            }
        } else if isDetect {
            detectFrames += 1
            if debug && (detectFrames == 1 || detectFrames == 20) {
                IslandDebugLog.write("livevideo-debug.txt", "detect frame #\(detectFrames) \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer)) fmt=\(CVPixelBufferGetPixelFormatType(pixelBuffer))")
            }
            analyze(pixelBuffer)
        } else if debug && detectFrames == 0 {
            IslandDebugLog.write("livevideo-debug.txt", "frame from unknown stream (not yet registered)")
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // The window went away or can't be captured any more: find where the video is now.
        let current = lock.withLock { () -> Int? in
            guard !_stopped, stream === _playStream || stream === _detectStream else { return nil }
            return _generation
        }
        guard let current else { return }
        if debug { IslandDebugLog.write("livevideo-debug.txt", "capture stopped: \(error.localizedDescription)") }
        queue.async { [weak self] in self?.windowIsDead(generation: current, reason: "stopped (\(error.localizedDescription))") }
    }

    // MARK: DRM (solid black) detection

    /// Samples a grid of pixels twice a second; ~4 s of (almost) black while playing = protected video.
    private func checkProtected(_ pb: CVPixelBuffer) {
        guard checksBlackFrames, !reportedProtected else { return }
        let now = Date()
        guard now.timeIntervalSince(lastBlackCheck) >= 0.5 else { return }
        lastBlackCheck = now
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let width = CVPixelBufferGetWidth(pb), height = CVPixelBufferGetHeight(pb)
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        guard width > 16, height > 16 else { return }
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        // Protected video captures as black, but the page's own controls, captions and
        // watermarks still draw on top — so "almost all black", not "all black".
        var dark = 0, total = 0
        for gy in 1...9 {
            let row = ptr + (height * gy / 10) * rowBytes
            for gx in 1...15 {
                let p = row + (width * gx / 16) * 4
                total += 1
                if max(p[0], p[1], p[2]) <= 14 { dark += 1 }
            }
        }
        guard dark * 100 >= total * 92 else {
            blackSince = nil
            return
        }
        if let since = blackSince {
            guard now.timeIntervalSince(since) >= 4 else { return }
            reportedProtected = true
            let key = sessionKey
            if debug { IslandDebugLog.write("livevideo-debug.txt", "video stayed black for 4 s — DRM-protected, showing info instead") }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.manager?.markProtected(key: key) }
            }
        } else {
            blackSince = now
        }
    }

    // MARK: Motion detection

    private func analyze(_ pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let width = CVPixelBufferGetWidth(pb), height = CVPixelBufferGetHeight(pb)
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        let gw = width / 2, gh = height / 2
        let count = gw * gh
        if prevLuma.count != count {
            prevLuma = [UInt8](repeating: 0, count: count)
            heat = [UInt8](repeating: 0, count: count)
            analyzedFrames = 0
        }
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let motionThreshold = tuning.liveVideoMotionThreshold ?? 14
        for gy in 0..<gh {
            let row = ptr + (gy * 2) * rowBytes
            for gx in 0..<gw {
                let p = row + (gx * 2) * 4 // BGRA
                let b: Int = Int(p[0]) * 29
                let g: Int = Int(p[1]) * 150
                let r: Int = Int(p[2]) * 77
                let luma = UInt8(truncatingIfNeeded: (r + g + b) >> 8)
                let i = gy * gw + gx
                let diff = abs(Int(luma) - Int(prevLuma[i]))
                var h = Int(heat[i])
                h -= h >> 4 // slow decay: integrates ~4 s of motion
                if diff > motionThreshold && analyzedFrames > 0 { h = min(255, h + 48) }
                heat[i] = UInt8(h)
                prevLuma[i] = luma
            }
        }
        analyzedFrames += 1
        if debug && (analyzedFrames == 1 || analyzedFrames == 3) {
            Self.savePNG(pb, name: "livevideo-frame\(analyzedFrames).png")
        }
        if debug && analyzedFrames % 8 == 0 && currentCrop == nil {
            var hot = 0, maxHeat = 0
            for v in heat { if v > (tuning.liveVideoHeatThreshold ?? 60) { hot += 1 }; maxHeat = max(maxHeat, Int(v)) }
            IslandDebugLog.write("livevideo-debug.txt", "analysis #\(analyzedFrames): hot cells \(hot)/\(heat.count) maxHeat \(maxHeat) grid \(gw)x\(gh)")
        }
        guard analyzedFrames >= 3,
              let gridRect = Self.hotRegion(heat: heat, gw: gw, gh: gh, threshold: UInt8(clamping: tuning.liveVideoHeatThreshold ?? 60)) else { return }

        // Grid → window points (the detect frame is the whole window scaled to fit).
        let sx = windowSize.width / CGFloat(gw), sy = windowSize.height / CGFloat(gh)
        var crop = CGRect(x: gridRect.minX * sx, y: gridRect.minY * sy,
                          width: gridRect.width * sx, height: gridRect.height * sy).integral
        crop = crop.intersection(CGRect(origin: .zero, size: windowSize))
        if tuning.liveVideoFlipY == true {
            crop.origin.y = windowSize.height - crop.maxY
        }
        guard crop.width >= 80, crop.height >= 45 else { return }
        // Subtitles and progress bars move too — ignore strip-shaped or tiny regions.
        let aspect = crop.width / crop.height
        guard aspect > 0.75, aspect < 2.6, crop.width >= windowSize.width * 0.18 else { return }
        // In a browser, the whole window changing means a page change, not the video.
        if isBrowser, crop.width > windowSize.width * 0.92, crop.height > windowSize.height * 0.85 { return }

        if let current = currentCrop {
            let inter = current.intersection(crop)
            let interArea = inter.isNull ? 0 : inter.width * inter.height
            let cropArea = crop.width * crop.height, currentArea = current.width * current.height
            if Self.iou(current, crop) > 0.8 { pendingHits = 0; return }
            // A smaller moving area inside the current one (e.g. only a face moved): keep the bigger frame.
            if interArea > cropArea * 0.85 { pendingHits = 0; return }
            // The moving area grew around the current one: take the bigger frame right away.
            let grew = interArea > currentArea * 0.85 && cropArea > currentArea * 1.1
            if !grew {
                // Moved somewhere else (scrolling, layout change): only switch after it's consistent.
                if let pending = pendingCrop, Self.iou(pending, crop) > 0.8 { pendingHits += 1 } else { pendingCrop = crop; pendingHits = 1 }
                guard pendingHits >= 3 else { return }
            }
        }
        pendingCrop = nil
        pendingHits = 0
        currentCrop = crop
        // Remember a convincing 16:9-ish player for instant start next time.
        let a = crop.width / crop.height
        if a > 1.55, a < 1.95, crop.width >= windowSize.width * 0.35 {
            Self.cacheLock.withLock { Self.cropCache[cacheKey] = crop }
        }
        if debug { IslandDebugLog.write("livevideo-debug.txt", "crop \(crop) in window \(windowSize) (grid \(gridRect))") }
        applyCrop(crop)
    }

    private func applyCrop(_ crop: CGRect, fullWindow: Bool = false) {
        let outW = 384
        let outH = max(120, min(384, Int((CGFloat(outW) * crop.height / crop.width).rounded()))) & ~1
        let config = SCStreamConfiguration()
        if !fullWindow { config.sourceRect = crop }
        config.width = outW
        config.height = outH
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.showsCursor = false
        config.queueDepth = 4
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.scalesToFit = true
        config.preservesAspectRatio = true
        let aspect = crop.width / crop.height
        let generation = self.generation
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.manager?.updateAspect(aspect) }
        }
        Task { [weak self] in
            guard let self, !self.stopped, self.generation == generation, let window = self.window else { return }
            // One play stream per window; a crop found while it is starting is applied right after.
            enum Step { case update(SCStream), wait, create }
            let step: Step = self.lock.withLock {
                if self._playStartingGeneration == generation {
                    self._pendingPlayConfig = config
                    return .wait
                }
                if let play = self._playStream { return .update(play) }
                self._playStartingGeneration = generation
                return .create
            }
            switch step {
            case .wait:
                return
            case .update(let play):
                try? await play.updateConfiguration(config)
                return
            case .create:
                break
            }
            let play = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: self)
            // Registered before starting so its first frame counts as "this window draws".
            let registered = self.lock.withLock { () -> Bool in
                guard !self._stopped, self._generation == generation else { return false }
                self._playStream = play
                return true
            }
            guard registered else { return }
            do {
                try play.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                try await play.startCapture()
            } catch {
                self.lock.withLock {
                    if self._playStream === play { self._playStream = nil }
                    if self._playStartingGeneration == generation { self._playStartingGeneration = nil }
                }
                if self.debug { IslandDebugLog.write("livevideo-debug.txt", "play stream failed: \(error.localizedDescription)") }
                self.queue.async { [weak self] in self?.windowIsDead(generation: generation, reason: "can't be captured") }
                return
            }
            let pending: SCStreamConfiguration? = self.lock.withLock {
                guard self._playStartingGeneration == generation else { return nil }
                defer { self._playStartingGeneration = nil; self._pendingPlayConfig = nil }
                return self._pendingPlayConfig
            }
            if self.stopped || self.generation != generation {
                try? await play.stopCapture()
                return
            }
            self.noteStreamStarted(generation: generation)
            if let pending { try? await play.updateConfiguration(pending) }
        }
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func savePNG(_ pb: CVPixelBuffer, name: String) {
        let image = CIImage(cvPixelBuffer: pb)
        guard let cg = ciContext.createCGImage(image, from: image.extent) else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: IslandPaths.appSupportPath.appendingPathComponent(name))
        }
    }

    /// Bounding box of the dominant moving area in the heat map (grid units).
    static func hotRegion(heat: [UInt8], gw: Int, gh: Int, threshold: UInt8 = 60) -> CGRect? {
        var cols = [Int](repeating: 0, count: gw)
        var total = 0
        for y in 0..<gh {
            for x in 0..<gw where heat[y * gw + x] > threshold {
                cols[x] += 1
                total += 1
            }
        }
        guard total >= max(30, gw * gh / 200) else { return nil }
        guard let (x0, x1) = longestRun(cols, threshold: max(2, (cols.max() ?? 0) / 4), gap: 2) else { return nil }
        var rows = [Int](repeating: 0, count: gh)
        for y in 0..<gh {
            for x in x0...x1 where heat[y * gw + x] > threshold { rows[y] += 1 }
        }
        guard let (y0, y1) = longestRun(rows, threshold: max(2, (rows.max() ?? 0) / 4), gap: 2) else { return nil }
        let w = x1 - x0 + 1, h = y1 - y0 + 1
        guard w >= 10, h >= 6, w * h >= gw * gh * 3 / 100 else { return nil }
        return CGRect(x: x0, y: y0, width: w, height: h)
    }

    private static func longestRun(_ values: [Int], threshold: Int, gap: Int) -> (Int, Int)? {
        var best: (Int, Int)?
        var start: Int?
        var lastHit = -10
        for (i, v) in values.enumerated() {
            if v >= threshold {
                if start == nil || i - lastHit > gap + 1 { start = i }
                lastHit = i
                if let s = start, (best == nil || (i - s) > (best!.1 - best!.0)) { best = (s, i) }
            }
        }
        return best
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        let inter = i.width * i.height
        return inter / (a.width * a.height + b.width * b.height - inter)
    }
}

// MARK: - Layer-backed view that shows the frames

final class LiveVideoLayerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ surface: IOSurfaceRef) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = surface
        CATransaction.commit()
    }

    func clear() {
        layer?.contents = nil
    }

    var gravity: CALayerContentsGravity = .resizeAspectFill {
        didSet { layer?.contentsGravity = gravity }
    }
}

struct LiveVideoView: NSViewRepresentable {
    var fill: Bool

    func makeNSView(context: Context) -> LiveVideoLayerView {
        let view = LiveVideoLayerView(frame: .zero)
        view.gravity = fill ? .resizeAspectFill : .resizeAspect
        LiveVideoManager.shared.attach(view)
        return view
    }

    func updateNSView(_ view: LiveVideoLayerView, context: Context) {
        view.gravity = fill ? .resizeAspectFill : .resizeAspect
    }

    static func dismantleNSView(_ view: LiveVideoLayerView, coordinator: ()) {
        LiveVideoManager.shared.detach(view)
    }
}
