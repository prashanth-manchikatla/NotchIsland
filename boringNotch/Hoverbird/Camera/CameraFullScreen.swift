//
//  CameraFullScreen.swift
//  Hoverbird
//
//  The camera, full screen on the MacBook display — like Photo Booth / FaceTime, in
//  real macOS full screen (its own Space): glass controls float at the bottom (timer, mirror,
//  shutter, record, fit / fill, close), the screen flashes white for a photo, and
//  controls fade away while you don't move the mouse.
//  Keys: Space = photo · R = record · Esc = close.
//

import AVFoundation
import Combine
import SwiftUI

/// Borderless windows can't become key unless they say so (needed for Space / Esc).
private final class CameraFullScreenWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class CameraFullScreen: NSObject, NSWindowDelegate {
    static let shared = CameraFullScreen()

    final class Model: ObservableObject {
        @Published var appear = false
        @Published var previewLayer: AVCaptureVideoPreviewLayer?
        @Published var countdown: Int?
        @Published var timerSeconds = 0
        @Published var mirrored = true
        @Published var fill = true
        @Published var controlsVisible = true
    }

    let model = Model()
    private var window: CameraFullScreenWindow?
    private var keyMonitor: Any?
    private var layerWatch: AnyCancellable?
    private var countdownTask: Task<Void, Never>?

    var isShown: Bool { window != nil }

    func toggle() { if isShown { close() } else { show() } }

    /// Real macOS full screen: the camera gets its own Space, so swiping between full-screen
    /// apps (or ⌘-Tab) works exactly as it does for any app.
    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let webcam = WebcamManager.shared
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            IslandActivityHub.shared.showPill(.info(symbol: "web.camera", text: "Allow the camera for Hoverbird first", tint: .orange), duration: 3)
            return
        }
        NotificationCenter.default.post(name: .islandCloseAll, object: nil)
        let wasRunning = webcam.isSessionRunning
        webcam.isFullScreen = true
        if !wasRunning {
            webcam.startSession()
            webcam.stopSession() // nobody else needs it: stop again when full screen closes
        }

        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        let window = CameraFullScreenWindow(contentRect: screen.frame,
                                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                            backing: .buffered, defer: false)
        window.title = "Camera"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.setFrame(screen.frame, display: false)
        window.contentView = NSHostingView(rootView: CameraFullScreenView(model: model))
        window.delegate = self
        self.window = window

        model.controlsVisible = true
        model.appear = true
        attachPreview()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { window.toggleFullScreen(nil) } // macOS's own full-screen animation
        installKeys()
    }

    /// Leaves full screen (the camera's Space closes with macOS's animation).
    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        countdownTask?.cancel()
        model.countdown = nil
        removeKeys()
        layerWatch = nil
        window = nil
        model.previewLayer?.session = nil
        model.previewLayer = nil
        model.appear = false
        WebcamManager.shared.isFullScreen = false // stops the camera if nothing else uses it
    }

    /// Swiped to another Space / app: pause the picture (and the camera light) until you're back.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else { return }
        WebcamManager.shared.setFullScreenHidden(!window.occlusionState.contains(.visible))
    }

    /// A second live preview of the camera; waits for the session if it is still starting.
    private func attachPreview() {
        let webcam = WebcamManager.shared
        if let layer = webcam.makePreviewLayer() {
            model.previewLayer = layer
            return
        }
        layerWatch = webcam.$previewLayer
            .compactMap { $0 }
            .first()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isShown else { return }
                    self.model.previewLayer = WebcamManager.shared.makePreviewLayer()
                }
            }
    }

    /// Photo, with the self-timer if one is set.
    func shutter() {
        guard model.countdown == nil else { return }
        let seconds = model.timerSeconds
        guard seconds > 0 else {
            WebcamManager.shared.capturePhoto()
            return
        }
        countdownTask = Task { @MainActor in
            for value in stride(from: seconds, to: 0, by: -1) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { model.countdown = value }
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            withAnimation(.easeOut(duration: 0.15)) { model.countdown = nil }
            WebcamManager.shared.capturePhoto()
        }
    }

    func cycleTimer() {
        withAnimation(.smooth) { model.timerSeconds = model.timerSeconds == 0 ? 3 : (model.timerSeconds == 3 ? 10 : 0) }
    }

    private func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let windowID = event.window.map { ObjectIdentifier($0) }
            let handled: Bool = MainActor.assumeIsolated {
                guard let self, let window = self.window, windowID == ObjectIdentifier(window) else { return false }
                switch keyCode {
                case 53: self.close()                              // Esc
                case 49: self.shutter()                            // Space
                case 15: WebcamManager.shared.toggleRecording()    // R
                default: return false
                }
                return true
            }
            return handled ? nil : event
        }
    }

    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

// MARK: - View

private struct LivePreviewLayer: NSViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer
    let fill: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        layer.frame = view.bounds
        CATransaction.commit()
    }
}

struct CameraFullScreenView: View {
    @ObservedObject var model: CameraFullScreen.Model
    @ObservedObject private var webcam = WebcamManager.shared
    @State private var flash = 0.0
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black
            if let layer = model.previewLayer {
                LivePreviewLayer(layer: layer, fill: model.fill)
                    .scaleEffect(x: model.mirrored ? -1 : 1, y: 1)
                    .opacity(webcam.isSessionRunning ? 1 : 0)
                    .animation(.easeInOut(duration: 0.35), value: webcam.isSessionRunning)
            }
            if !webcam.isSessionRunning {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large)
                    Text("Starting the camera…").font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                }
            }
            // Photo Booth-style flash (it lights your face, too).
            Color.white.opacity(flash).allowsHitTesting(false)
            if let value = model.countdown {
                Text("\(value)")
                    .font(.system(size: 200, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 30)
                    .id(value)
                    .transition(.scale(scale: 1.6).combined(with: .opacity))
            }
            overlay
                .opacity(model.controlsVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.3), value: model.controlsVisible)
        }
        .ignoresSafeArea()
        .onChange(of: webcam.flashCount) {
            flash = 0.9
            withAnimation(.easeOut(duration: 0.55)) { flash = 0 }
        }
        .onContinuousHover { _ in revealControls() }
        .onAppear { revealControls() }
    }

    private var overlay: some View {
        VStack {
            HStack(alignment: .top) {
                if webcam.isRecording, let start = webcam.recordingStart {
                    HStack(spacing: 8) {
                        Circle().fill(Color.red).frame(width: 10, height: 10)
                            .phaseAnimator([1.0, 0.3]) { view, phase in view.opacity(phase) } animation: { _ in .easeInOut(duration: 0.7) }
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(Self.clock(context.date.timeIntervalSince(start)))
                                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 0.5))
                    .transition(.scale.combined(with: .opacity))
                }
                if webcam.source == .iPhone {
                    CameraSourceBadge(name: webcam.activeCameraName, compact: false)
                        .transition(.scale(scale: 0.6, anchor: .topLeading).combined(with: .opacity))
                }
                Spacer()
                if let url = webcam.lastCameraCapture {
                    Button { NSWorkspace.shared.open(url) } label: {
                        CaptureThumbnail(url: url, isVideo: url.pathExtension.lowercased() == "mov")
                            .frame(width: 96, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.5), lineWidth: 1))
                            .shadow(color: .black.opacity(0.4), radius: 10)
                    }
                    .buttonStyle(.plain)
                    .help("Open the last photo or video")
                    .id(url)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .padding(.top, 16)
            Spacer()
            controls
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 40)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: webcam.lastCameraCapture)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: webcam.isRecording)
    }

    private var controls: some View {
        HStack(spacing: 22) {
            GlassCircleButton(symbol: "timer", badge: model.timerSeconds > 0 ? "\(model.timerSeconds)s" : nil,
                              active: model.timerSeconds > 0, help: "Self-timer (off · 3 s · 10 s)") {
                CameraFullScreen.shared.cycleTimer()
            }
            GlassCircleButton(symbol: "flip.horizontal", active: model.mirrored, help: "Mirror") {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { model.mirrored.toggle() }
            }
            // Hoverbird: Mac camera ⇄ iPhone camera (only when an iPhone is nearby).
            if webcam.iPhoneCameraName != nil || webcam.source == .iPhone {
                let onIPhone = webcam.source == .iPhone
                GlassCircleButton(symbol: onIPhone ? "laptopcomputer" : "iphone.gen3", active: onIPhone,
                                  help: onIPhone ? "Use this Mac's camera" : "Use \(CameraSourceBadge.shortName(webcam.iPhoneCameraName) ?? "the iPhone camera")") {
                    webcam.toggleCameraSource()
                }
                .disabled(webcam.isRecording || webcam.isSwitchingCamera)
                .opacity(webcam.isRecording ? 0.4 : 1)
            }
            Button { CameraFullScreen.shared.shutter() } label: {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.9), lineWidth: 4).frame(width: 78, height: 78)
                    Circle().fill(Color.white).frame(width: 64, height: 64)
                }
                .contentShape(Circle())
            }
            .buttonStyle(PressScaleStyle())
            .help("Take a photo (Space)")
            Button { webcam.toggleRecording() } label: {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.9), lineWidth: 4).frame(width: 62, height: 62)
                    RoundedRectangle(cornerRadius: webcam.isRecording ? 6 : 24, style: .continuous)
                        .fill(Color.red)
                        .frame(width: webcam.isRecording ? 24 : 48, height: webcam.isRecording ? 24 : 48)
                }
                .contentShape(Circle())
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: webcam.isRecording)
            }
            .buttonStyle(PressScaleStyle())
            .help(webcam.isRecording ? "Stop recording (R)" : "Record a video (R)")
            GlassCircleButton(symbol: model.fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                              help: model.fill ? "Show the whole picture" : "Fill the screen") {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { model.fill.toggle() }
            }
            GlassCircleButton(symbol: "xmark", help: "Close (Esc)") { CameraFullScreen.shared.close() }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
    }

    private func revealControls() {
        if !model.controlsVisible { model.controlsVisible = true }
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { model.controlsVisible = false }
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
                             : String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct GlassCircleButton: View {
    let symbol: String
    var badge: String?
    var active = false
    var help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(active ? Color.yellow : Color.white)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Color.white.opacity(hovering ? 0.22 : 0.12)))
                if let badge {
                    Text(badge).font(.system(size: 9, weight: .bold, design: .rounded))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(Color.yellow)).foregroundStyle(.black)
                        .offset(x: 4, y: 2)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .help(help)
    }
}

/// Buttons squish a little when pressed, like iOS.
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
