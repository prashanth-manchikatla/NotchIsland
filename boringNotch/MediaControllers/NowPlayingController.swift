//
//  NowPlayingController.swift
//  boringNotch
//
//  Created by Alexander on 2025-03-29.
//

import AppKit
import Combine
import Foundation

final class NowPlayingController: ObservableObject, MediaControllerProtocol {
    func updatePlaybackInfo() async {
        await fetchFavoriteStateIfSupported()
    }

    // MARK: - Properties
    @Published private(set) var playbackState: PlaybackState = .init(
        bundleIdentifier: "com.apple.Music"
    )

    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    var supportsVolumeControl: Bool {
        let bundleID = playbackState.bundleIdentifier
        return bundleID == "com.apple.Music" || bundleID == "com.spotify.client"
    }

    var supportsFavorite: Bool {
        let bundleID = playbackState.bundleIdentifier
        return bundleID == "com.apple.Music"
    }

    func setFavorite(_ favorite: Bool) async {
        let bundleID = playbackState.bundleIdentifier
        
        if bundleID == "com.apple.Music" {
            let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
            if !runningApps.isEmpty {
                let script = """
                tell application "Music"
                    try
                        set favorited of current track to \(favorite ? "true" : "false")
                    end try
                end tell
                """
                try? await AppleScriptHelper.executeVoid(script)
            }
        }
        
        // Update the favorite state locally and fetch updated info
        try? await Task.sleep(for: .milliseconds(150))
        await updatePlaybackInfo()
    }

    private var lastMusicItem:
        (title: String, artist: String, album: String, duration: TimeInterval, artworkData: Data?)?

    // MARK: - Media Remote Functions
    private let mediaRemoteBundle: CFBundle
    private let MRMediaRemoteSendCommandFunction: @convention(c) (Int, AnyObject?) -> Void
    private let MRMediaRemoteSetElapsedTimeFunction: @convention(c) (Double) -> Void
    private let MRMediaRemoteSetShuffleModeFunction: @convention(c) (Int) -> Void
    private let MRMediaRemoteSetRepeatModeFunction: @convention(c) (Int) -> Void

    private var process: Process?
    private var pipeHandler: JSONLinesPipeHandler?
    private var streamTask: Task<Void, Never>?

    // MARK: - Initialization
    init?() {
        guard
            let bundle = CFBundleCreate(
                kCFAllocatorDefault,
                NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")),
            let MRMediaRemoteSendCommandPointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSendCommand" as CFString),
            let MRMediaRemoteSetElapsedTimePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetElapsedTime" as CFString),
            let MRMediaRemoteSetShuffleModePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetShuffleMode" as CFString),
            let MRMediaRemoteSetRepeatModePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetRepeatMode" as CFString)
            
        else { return nil }

        mediaRemoteBundle = bundle
        MRMediaRemoteSendCommandFunction = unsafeBitCast(
            MRMediaRemoteSendCommandPointer, to: (@convention(c) (Int, AnyObject?) -> Void).self)
        MRMediaRemoteSetElapsedTimeFunction = unsafeBitCast(
            MRMediaRemoteSetElapsedTimePointer, to: (@convention(c) (Double) -> Void).self)
        MRMediaRemoteSetShuffleModeFunction = unsafeBitCast(
            MRMediaRemoteSetShuffleModePointer, to: (@convention(c) (Int) -> Void).self)
        MRMediaRemoteSetRepeatModeFunction = unsafeBitCast(
            MRMediaRemoteSetRepeatModePointer, to: (@convention(c) (Int) -> Void).self)

        Task { await setupNowPlayingObserver() }
    }

    deinit {
        streamTask?.cancel()
        
        if let pipeHandler = self.pipeHandler {
            Task { await pipeHandler.close()
            }
        }
        
        if let process = self.process {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        self.process = nil
        self.pipeHandler = nil
    }

    // MARK: - Protocol Implementation
    // Hoverbird: since macOS 15.4 MediaRemote ignores commands from ordinary apps,
    // so commands go through the bundled adapter (run by Apple's signed /usr/bin/perl),
    // falling back to the in-process call if the adapter is unavailable.
    private func adapter(_ args: [String]) -> Bool {
        guard let scriptURL = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let frameworkPath = Bundle.main.privateFrameworksPath?.appending("/MediaRemoteAdapter.framework") else {
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, frameworkPath] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    private func send(_ command: Int) {
        if !adapter(["send", "\(command)"]) { MRMediaRemoteSendCommandFunction(command, nil) }
    }

    func play() async { send(0) }

    func pause() async { send(1) }

    func togglePlay() async { send(2) }

    /// Apps that ignore system next/previous (remembered), so we act instantly next time.
    private static var appsIgnoringSkip: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "Hoverbird.appsIgnoringSkip") ?? [])
    private var skipInFlightUntil: Date = .distantPast

    private func beginSkip() -> Bool {
        // Ignore repeat presses while a skip is still landing (prevents double skips).
        guard Date() >= skipInFlightUntil else { return false }
        skipInFlightUntil = Date().addingTimeInterval(0.6)
        return true
    }

    /// Apps whose player rejects Now Playing seeks (remembered → go straight to their keys).
    private static var appsRejectingSeek: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "Hoverbird.appsRejectingSeek") ?? [])

    private func isYouTubePlayer() async -> Bool {
        let bundleID = playbackState.bundleIdentifier
        let appName = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? ""
        if appName.localizedCaseInsensitiveContains("youtube") { return true }
        return await isYouTubeSource()
    }

    private func isYouTubeSource() async -> Bool {
        let title = await MainActor.run { LiveVideoManager.shared.sourceWindowTitle } ?? ""
        return title.localizedCaseInsensitiveContains("youtube")
    }

    func nextTrack() async {
        guard beginSkip() else { return }
        let bundleID = playbackState.bundleIdentifier
        if Self.appsIgnoringSkip.contains(bundleID) {
            let youTube = await isYouTubeSource()
            _ = await Task.detached(priority: .userInitiated) { WebMediaFallback.perform(.next, bundleID: bundleID, isYouTube: youTube) }.value
            return
        }
        let before = playbackState.title
        send(4)
        await fallbackIfIgnored(.next, titleBefore: before)
    }

    private func mlog(_ line: String) { IslandDebugLog.write("media-debug.txt", line) }

    func previousTrack() async {
        guard beginSkip() else { mlog("previous ignored (repeat press)"); return }
        let before = playbackState.title
        let bundleID = playbackState.bundleIdentifier

        // YouTube: Previous means the previous video. Press the window's own Back button
        // through Accessibility — reliable in the background and from other desktops.
        if await isYouTubePlayer() {
            let ok = await Task.detached(priority: .userInitiated) {
                WebMediaFallback.perform(.previous, bundleID: bundleID, isYouTube: true)
            }.value
            mlog("previous (YouTube): back button \(ok ? "pressed" : "unavailable")")
            return
        }

        // Music apps: iPhone behaviour — more than 3 s in, Previous restarts the track.
        let elapsed = estimatedElapsed()
        mlog("previous: elapsed≈\(String(format: "%.1f", elapsed)) app=\(bundleID.suffix(14))")
        if elapsed > 3 && playbackState.duration > 0 {
            await seek(to: 0)
            return
        }
        if Self.appsIgnoringSkip.contains(bundleID) {
            _ = await Task.detached(priority: .userInitiated) {
                WebMediaFallback.perform(.previous, bundleID: bundleID, isYouTube: false)
            }.value
        } else {
            send(5)
            await fallbackIfIgnored(.previous, titleBefore: before, elapsedBefore: elapsed)
        }
    }

    private func estimatedElapsed() -> Double {
        let state = playbackState
        guard state.isPlaying else { return state.currentTime }
        return state.currentTime + Date().timeIntervalSince(state.lastUpdated) * state.playbackRate
    }

    /// Web players often ignore system next/previous: if nothing changed, use the page's own controls.
    private func fallbackIfIgnored(_ direction: WebMediaFallback.Direction, titleBefore: String, elapsedBefore: Double = 0) async {
        try? await Task.sleep(for: .milliseconds(900))
        guard playbackState.title == titleBefore else { return }
        if direction == .previous {
            // Restarted already (elapsed jumped back)? Then it worked.
            if estimatedElapsed() < max(1.5, elapsedBefore - 2) { return }
        }
        let bundleID = playbackState.bundleIdentifier
        // Remember: this app ignores system skip commands — act instantly from now on.
        Self.appsIgnoringSkip.insert(bundleID)
        UserDefaults.standard.set(Array(Self.appsIgnoringSkip), forKey: "Hoverbird.appsIgnoringSkip")
        let youTube = await isYouTubeSource()
        skipInFlightUntil = Date().addingTimeInterval(1.0)
        let triggered = await Task.detached(priority: .userInitiated) {
            WebMediaFallback.perform(direction, bundleID: bundleID, isYouTube: youTube)
        }.value
        if direction == .previous {
            return // previousTrack() restarts the video if nothing changed
        } else if !triggered {
            // Last resort for single videos: jump to the end so autoplay moves on.
            if playbackState.duration > 5 { await seek(to: max(0, playbackState.duration - 0.5)) }
        }
    }

    /// Runs the adapter and waits for its exit status (seek reports failure when unsupported).
    private func adapterStatus(_ args: [String]) async -> Int32? {
        guard let scriptURL = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let frameworkPath = Bundle.main.privateFrameworksPath?.appending("/MediaRemoteAdapter.framework") else {
            return nil
        }
        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = [scriptURL.path, frameworkPath] + args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil as Int32? }
            process.waitUntilExit()
            return process.terminationStatus
        }.value
    }

    func seek(to time: Double) async {
        let target = max(0, time)
        let bundleID = playbackState.bundleIdentifier
        var status: Int32? = 1
        if !Self.appsRejectingSeek.contains(bundleID) {
            status = await adapterStatus(["seek", "\(Int64(target * 1_000_000))"])
            if status == 0 { return }
            if status != nil {
                Self.appsRejectingSeek.insert(bundleID)
                UserDefaults.standard.set(Array(Self.appsRejectingSeek), forKey: "Hoverbird.appsRejectingSeek")
            }
        }
        // The player rejects seeking (e.g. YouTube in a Safari web app): use its own keys.
        let youTube = await isYouTubePlayer()
        mlog("  seek \(String(format: "%.1f", target)) via adapter failed (status \(status.map(String.init) ?? "nil")) → YouTube keys: \(youTube)")
        if youTube && target < 1.5 {
            let ok = await WebMediaFallback.restartYouTube(bundleID: bundleID)
            mlog("  restart via YouTube keys: \(ok ? "confirmed" : "not confirmed")")
        } else if youTube {
            let current = estimatedElapsed(), duration = playbackState.duration
            _ = await Task.detached(priority: .userInitiated) {
                WebMediaFallback.seekYouTube(from: current, to: target, duration: duration, bundleID: bundleID)
            }.value
        } else if status == nil {
            MRMediaRemoteSetElapsedTimeFunction(target)
        }
    }

    func isActive() -> Bool {
        return true
    }
    
    func toggleShuffle() async {
        // MRMediaRemoteSendCommandFunction(6, nil)
        let shuffleMode = playbackState.isShuffled ? 1 : 3
        if !adapter(["shuffle", "\(shuffleMode)"]) { MRMediaRemoteSetShuffleModeFunction(shuffleMode) }
        playbackState.isShuffled.toggle()
    }
    
    func toggleRepeat() async {
        // MRMediaRemoteSendCommandFunction(7, nil)
        let newRepeatMode = (playbackState.repeatMode == .off) ? 3 : (playbackState.repeatMode.rawValue - 1)
        playbackState.repeatMode = RepeatMode(rawValue: newRepeatMode) ?? .off
        if !adapter(["repeat", "\(newRepeatMode)"]) { MRMediaRemoteSetRepeatModeFunction(newRepeatMode) }
    }
    
    func setVolume(_ level: Double) async {
        // MediaRemote framework doesn't provide direct volume control for the active audio session
        // As a workaround, try to control the currently active music app directly
        let clampedLevel = max(0.0, min(1.0, level))
        let volumePercentage = Int(clampedLevel * 100)
        
        let bundleID = playbackState.bundleIdentifier
        if !bundleID.isEmpty {
            if bundleID == "com.apple.Music" {
                let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
                if !runningApps.isEmpty {
                    let script = "tell application \"Music\" to set sound volume to \(volumePercentage)"
                    try? await AppleScriptHelper.executeVoid(script)
                }
            } else if bundleID == "com.spotify.client" {
                let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client")
                if !runningApps.isEmpty {
                    let script = "tell application \"Spotify\" to set sound volume to \(volumePercentage)"
                    try? await AppleScriptHelper.executeVoid(script)
                }
            }
        }
        
        playbackState.volume = clampedLevel
    }
    
    // MARK: - Setup Methods
    private func setupNowPlayingObserver() async {
        let process = Process()
        guard
            let scriptURL = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
            let frameworkPath = Bundle.main.privateFrameworksPath?.appending("/MediaRemoteAdapter.framework")
        else {
            assertionFailure("Could not find mediaremote-adapter.pl script or framework path")
            return
        }
        
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, frameworkPath, "stream"]
        // Hoverbird: clean up helpers an earlier run left behind (before starting ours).
        IslandHelperProcesses.reapOrphanedAdapters()

        let pipeHandler = JSONLinesPipeHandler()
        process.standardOutput = await pipeHandler.getPipe()
        
        self.process = process
        self.pipeHandler = pipeHandler

        do {
            try process.run()
            IslandHelperProcesses.terminateOnQuit(process) // deinit never runs at quit
            streamTask = Task { [weak self] in
                await self?.processJSONStream()
            }
        } catch {
            assertionFailure("Failed to launch mediaremote-adapter.pl: \(error)")
        }
    }

    // MARK: - Async Stream Processing
    private func processJSONStream() async {
        guard let pipeHandler = self.pipeHandler else { return }
        
        await pipeHandler.readJSONLines(as: NowPlayingUpdate.self) { [weak self] update in
            await self?.handleAdapterUpdate(update)
        }
    }

    // MARK: - Update Methods
    private func handleAdapterUpdate(_ update: NowPlayingUpdate) async {
        let payload = update.payload
        let diff = update.diff ?? false

        var newPlaybackState = PlaybackState(bundleIdentifier: playbackState.bundleIdentifier)
        
        newPlaybackState.title = payload.title ?? (diff ? self.playbackState.title : "")
        newPlaybackState.artist = payload.artist ?? (diff ? self.playbackState.artist : "")
        newPlaybackState.album = payload.album ?? (diff ? self.playbackState.album : "")
        newPlaybackState.duration = payload.duration ?? (diff ? self.playbackState.duration : 0)
        newPlaybackState.contentID = payload.contentItemIdentifier ?? (diff ? self.playbackState.contentID : nil)
        
        if let elapsedTime = payload.elapsedTime {
            newPlaybackState.currentTime = elapsedTime
        } else if diff {
            if payload.playing == false {
                let timeSinceLastUpdate = Date().timeIntervalSince(self.playbackState.lastUpdated)
                newPlaybackState.currentTime = self.playbackState.currentTime + (self.playbackState.playbackRate * timeSinceLastUpdate)
            } else {
                newPlaybackState.currentTime = self.playbackState.currentTime
            }
        } else {
            newPlaybackState.currentTime = 0
        }

        
        if let shuffleMode = payload.shuffleMode {
            newPlaybackState.isShuffled = shuffleMode != 1
        } else if !diff {
            newPlaybackState.isShuffled = false
        } else {
            newPlaybackState.isShuffled = self.playbackState.isShuffled
        }
        if let repeatModeValue = payload.repeatMode {
            newPlaybackState.repeatMode = RepeatMode(rawValue: repeatModeValue) ?? .off
        } else if !diff {
            newPlaybackState.repeatMode = .off
        } else {
            newPlaybackState.repeatMode = self.playbackState.repeatMode
        }

        if let artworkDataString = payload.artworkData {
            newPlaybackState.artwork = Data(
                base64Encoded: artworkDataString.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } else if !diff {
            newPlaybackState.artwork = nil
        }

        if let dateString = payload.timestamp,
           let date = ISO8601DateFormatter().date(from: dateString) {
            newPlaybackState.lastUpdated = date
        } else if !diff {
            newPlaybackState.lastUpdated = Date()
        } else {
            newPlaybackState.lastUpdated = self.playbackState.lastUpdated
        }

        newPlaybackState.playbackRate = payload.playbackRate ?? (diff ? self.playbackState.playbackRate : 1.0)
        newPlaybackState.isPlaying = payload.playing ?? (diff ? self.playbackState.isPlaying : false)
        newPlaybackState.bundleIdentifier = (
            payload.parentApplicationBundleIdentifier ??
            payload.bundleIdentifier ??
            (diff ? self.playbackState.bundleIdentifier : "")
        )
        
        newPlaybackState.volume = payload.volume ?? (diff ? self.playbackState.volume : 0.5)
        
        self.playbackState = newPlaybackState
        
        // Fetch favorite state for supported apps asynchronously
        // await fetchFavoriteStateIfSupported()
    }
    
     private func fetchFavoriteStateIfSupported() async {
         let bundleID = playbackState.bundleIdentifier
        
         if bundleID == "com.apple.Music" {
             let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
             guard !runningApps.isEmpty else { return }
             
             let script = """
             tell application "Music"
                 try
                     return favorited of current track
                 on error
                     return false
                 end try
             end tell
             """
             if let result = try? await AppleScriptHelper.execute(script) {
                 var updated = self.playbackState
                 updated.isFavorite = result.booleanValue
                 self.playbackState = updated
             }
         }
     }
    
}

struct NowPlayingUpdate: Codable {
    let payload: NowPlayingPayload
    let diff: Bool?
}

struct NowPlayingPayload: Codable {
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let elapsedTime: Double?
    let shuffleMode: Int?
    let repeatMode: Int?
    let artworkData: String?
    let timestamp: String?
    let playbackRate: Double?
    let playing: Bool?
    let parentApplicationBundleIdentifier: String?
    let bundleIdentifier: String?
    let volume: Double?
    /// Hoverbird: the app's id for what's playing (Prime Video: "amzn1.dv.gti.…").
    let contentItemIdentifier: String?
}

actor JSONLinesPipeHandler {
    private let pipe: Pipe
    private let fileHandle: FileHandle
    private var buffer = ""
    
    init() {
        self.pipe = Pipe()
        self.fileHandle = pipe.fileHandleForReading
    }
    
    func getPipe() -> Pipe {
        return pipe
    }
    
    func readJSONLines<T: Decodable>(as type: T.Type, onLine: @escaping (T) async -> Void) async {
        do {
            try await self.processLines(as: type) { decodedObject in
                await onLine(decodedObject)
            }
        } catch {
            print("Error processing JSON stream: \(error)")
        }
    }
    
    private func processLines<T: Decodable>(as type: T.Type, onLine: @escaping (T) async -> Void) async throws {
        while true {
            let data = try await readData()
            guard !data.isEmpty else { break }
            
            if let chunk = String(data: data, encoding: .utf8) {
                buffer.append(chunk)
                
                while let range = buffer.range(of: "\n") {
                    let line = String(buffer[..<range.lowerBound])
                    buffer = String(buffer[range.upperBound...])
                    
                    if !line.isEmpty {
                        await processJSONLine(line, as: type, onLine: onLine)
                    }
                }
            }
        }
    }
    
    private func processJSONLine<T: Decodable>(_ line: String, as type: T.Type, onLine: @escaping (T) async -> Void) async {
        guard let data = line.data(using: .utf8) else {
            return
        }
        do {
            let decodedObject = try JSONDecoder().decode(T.self, from: data)
            await onLine(decodedObject)
        } catch {
            // Ignore lines that can't be decoded
        }
    }
    
    private func readData() async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            
            fileHandle.readabilityHandler = { handle in
                let data = handle.availableData
                handle.readabilityHandler = nil
                continuation.resume(returning: data)
            }
        }
    }
    
    func close() async {
        do {
            fileHandle.readabilityHandler = nil
            try fileHandle.close()
            try pipe.fileHandleForWriting.close()
        } catch {
            print("Error closing pipe handler: \(error)")
        }
    }
}
