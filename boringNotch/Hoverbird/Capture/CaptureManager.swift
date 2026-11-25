//
//  CaptureManager.swift
//  Hoverbird
//
//  Screenshots (area / window / full screen) via the system `screencapture`
//  tool, and screen recordings (area / full screen) via ScreenCaptureKit with
//  a live red "REC" activity in the island — click it to stop.
//

import AppKit
import AVFoundation
import Combine
import Defaults
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class CaptureManager: NSObject, ObservableObject {
    static let shared = CaptureManager()

    enum ScreenshotMode { case area, window, fullScreen }
    enum RecordingMode { case area, fullScreen }

    @Published private(set) var isRecording = false
    @Published private(set) var recordingStart: Date?
    @Published private(set) var countdown: Int?
    @Published private(set) var isBusy = false
    @Published private(set) var lastCapture: URL?
    @Published var lastError: String?

    private var recorder: AnyObject?
    private var countdownTask: Task<Void, Never>?

    // MARK: - Screenshots

    func screenshot(_ mode: ScreenshotMode) {
        guard !isBusy else { return }
        isBusy = true
        Task { @MainActor in
            defer { isBusy = false }
            await closeIslandForCapture()
            let url = Self.newFileURL(prefix: "Screenshot", ext: "png")
            var args: [String] = []
            if !Defaults[.capturePlaySound] { args.append("-x") }
            switch mode {
            case .area: args += ["-i", "-s"]
            case .window: args += ["-i", "-w"]
            case .fullScreen: args += ["-D", "\(Self.displayIndexUnderMouse())"]
            }
            args.append(url.path)
            let status = await Self.run("/usr/sbin/screencapture", args)
            guard status == 0, FileManager.default.fileExists(atPath: url.path) else {
                // Cancelled (Esc) or permission missing.
                if status != 0 && mode == .fullScreen { lastError = "Allow Screen Recording for Hoverbird in System Settings › Privacy & Security." }
                return
            }
            handleNewCapture(url, isVideo: false)
        }
    }

    // MARK: - Recording

    func toggleRecording(_ mode: RecordingMode = .fullScreen) {
        if isRecording || countdown != nil { stopRecording() } else { startRecording(mode) }
    }

    func startRecording(_ mode: RecordingMode) {
        guard !isRecording, countdown == nil, !isBusy else { return }
        guard #available(macOS 15.0, *) else {
            lastError = "Screen recording needs macOS 15 or later."
            return
        }
        isBusy = true
        Task { @MainActor in
            await closeIslandForCapture()
            let screen = Self.screenUnderMouse()
            var rect: CGRect? = nil
            if mode == .area {
                guard let picked = await RegionSelector.select(on: screen) else {
                    isBusy = false
                    return
                }
                rect = picked
            }
            if Defaults[.recordCountdown] {
                for n in stride(from: 3, through: 1, by: -1) {
                    countdown = n
                    try? await Task.sleep(for: .milliseconds(850))
                    if countdown == nil { isBusy = false; return } // cancelled
                }
                countdown = nil
            }
            do {
                let recorder = ScreenRecorder()
                let url = Self.newFileURL(prefix: "Screen Recording", ext: "mov")
                try await recorder.start(screen: screen, rect: rect, url: url)
                self.recorder = recorder
                recordingStart = Date()
                isRecording = true
            } catch {
                lastError = Self.describe(error)
                IslandActivityHub.shared.showPill(.info(symbol: "exclamationmark.triangle.fill", text: "Recording didn't start", tint: .orange), duration: 3)
            }
            isBusy = false
        }
    }

    func stopRecording() {
        if countdown != nil {
            countdown = nil
            return
        }
        guard isRecording, #available(macOS 15.0, *), let recorder = recorder as? ScreenRecorder else { return }
        isRecording = false
        recordingStart = nil
        self.recorder = nil
        Task { @MainActor in
            if let url = await recorder.stop() {
                handleNewCapture(url, isVideo: true)
            } else {
                IslandActivityHub.shared.showPill(.info(symbol: "exclamationmark.triangle.fill", text: "Recording couldn't be saved", tint: .orange), duration: 3)
            }
        }
    }

    /// Used when quitting: stop and wait until the movie file is finalised.
    func stopRecordingAndWait() async {
        guard isRecording, #available(macOS 15.0, *), let recorder = recorder as? ScreenRecorder else { return }
        isRecording = false
        recordingStart = nil
        self.recorder = nil
        if let url = await recorder.stop() { lastCapture = url }
    }

    // MARK: - After capture

    func handleNewCapture(_ url: URL, isVideo: Bool) {
        lastCapture = url
        if Defaults[.captureCopyToClipboard] {
            let pb = NSPasteboard.general
            pb.clearContents()
            let item = NSPasteboardItem()
            if !isVideo, let data = try? Data(contentsOf: url) {
                item.setData(data, forType: url.pathExtension.lowercased() == "jpg" ? NSPasteboard.PasteboardType("public.jpeg") : .png)
            }
            item.setString(url.absoluteString, forType: .fileURL)
            pb.writeObjects([item])
        }
        if Defaults[.captureAddToShelf], let bookmark = try? Bookmark(url: url) {
            ShelfStateViewModel.shared.add([ShelfItem(kind: .file(bookmark: bookmark.data))])
        }
        IslandActivityHub.shared.showPill(.captureSaved(url, isVideo: isVideo), duration: 3.2)
    }

    func revealLastCapture() {
        guard let lastCapture else {
            NSWorkspace.shared.open(IslandPaths.captureFolder)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([lastCapture])
    }

    func openLastCapture() {
        guard let lastCapture else { return }
        NSWorkspace.shared.open(lastCapture)
    }

    // MARK: - Helpers

    private func closeIslandForCapture() async {
        NotificationCenter.default.post(name: .islandCloseAll, object: nil)
        try? await Task.sleep(for: .milliseconds(380))
    }

    static func newFileURL(prefix: String, ext: String) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        let name = "\(prefix) \(f.string(from: Date())).\(ext)"
        return IslandPaths.captureFolder.appendingPathComponent(name)
    }

    static func screenUnderMouse() -> NSScreen {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// `screencapture -D` numbering: 1 = main display, then the others in NSScreen order.
    static func displayIndexUnderMouse() -> Int {
        let target = screenUnderMouse()
        return (NSScreen.screens.firstIndex(of: target) ?? 0) + 1
    }

    static func run(_ path: String, _ args: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(returning: -1) }
        }
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain, ns.code == SCStreamError.userDeclined.rawValue {
            return "Allow Screen Recording for Hoverbird in System Settings › Privacy & Security, then try again."
        }
        return ns.localizedDescription
    }
}

extension Notification.Name {
    /// Ask every island to close (e.g. before taking a screenshot).
    static let islandCloseAll = Notification.Name("Hoverbird.closeAll")
}

// MARK: - ScreenCaptureKit recorder

@available(macOS 15.0, *)
final class ScreenRecorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var outputURL: URL?
    private var finishContinuation: CheckedContinuation<Bool, Never>?
    private var didFinish = false
    private var didFail = false

    @MainActor
    func start(screen: NSScreen, rect: CGRect?, url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw NSError(domain: "Hoverbird", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display to record"])
        }
        // Keep Hoverbird itself (the island, the REC pill) out of the video.
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        if let rect {
            config.sourceRect = rect
            config.width = Int((rect.width * scale).rounded()) & ~1
            config.height = Int((rect.height * scale).rounded()) & ~1
        } else {
            config.width = Int((CGFloat(display.width) * scale).rounded()) & ~1
            config.height = Int((CGFloat(display.height) * scale).rounded()) & ~1
        }
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Defaults[.recordQuality].fps))
        config.showsCursor = true
        config.showMouseClicks = Defaults[.recordShowClicks]
        config.capturesAudio = Defaults[.recordSystemAudio]
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = Defaults[.recordMicrophone]
        config.queueDepth = 6

        let recConfig = SCRecordingOutputConfiguration()
        recConfig.outputURL = url
        recConfig.outputFileType = .mov
        recConfig.videoCodecType = .hevc

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        let output = SCRecordingOutput(configuration: recConfig, delegate: self)
        try stream.addRecordingOutput(output)
        try await stream.startCapture()
        self.stream = stream
        self.recordingOutput = output
        self.outputURL = url
    }

    /// Stops and waits for the movie file to be finalised.
    func stop() async -> URL? {
        guard let stream else { return nil }
        try? await stream.stopCapture()
        let ok: Bool = await withCheckedContinuation { continuation in
            if didFinish || didFail {
                continuation.resume(returning: didFinish)
            } else {
                finishContinuation = continuation
                // Safety timeout in case the delegate never reports back.
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, let pending = self.finishContinuation else { return }
                    self.finishContinuation = nil
                    pending.resume(returning: self.outputURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
                }
            }
        }
        self.stream = nil
        return ok ? outputURL : nil
    }

    // SCRecordingOutputDelegate
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        DispatchQueue.main.async {
            self.didFinish = true
            self.finishContinuation?.resume(returning: true)
            self.finishContinuation = nil
        }
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.didFail = true
            self.finishContinuation?.resume(returning: false)
            self.finishContinuation = nil
        }
    }

    // SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            Task { @MainActor in
                // The system stopped us (e.g. the user clicked the menu-bar stop button).
                if CaptureManager.shared.isRecording { CaptureManager.shared.stopRecording() }
            }
        }
    }
}
