//
//  WebcamView.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 19/08/24.
//

import AVFoundation
import Defaults
import SwiftUI

struct CameraPreviewView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var webcamManager: WebcamManager
    
    // Track if authorization request is in progress to avoid multiple requests
    @State private var isRequestingAuthorization: Bool = false
    // Hoverbird: photo / video / full-screen controls.
    @State private var hovering = false
    @State private var flash = 0.0

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let previewLayer = webcamManager.previewLayer {
                    CameraPreviewLayerView(previewLayer: previewLayer)
                        .scaleEffect(x: -1, y: 1)
                        .clipShape(RoundedRectangle(cornerRadius: Defaults[.mirrorShape] == .rectangle ? !Defaults[.cornerRadiusScaling] ? MusicPlayerImageSizes.cornerRadiusInset.closed : MusicPlayerImageSizes.cornerRadiusInset.opened : 100))
                        .frame(width: geometry.size.width, height: geometry.size.width)
                        .opacity(webcamManager.isSessionRunning ? 1 : 0)
                }

                if !webcamManager.isSessionRunning {
                    ZStack {
                        RoundedRectangle(cornerRadius: Defaults[.mirrorShape] == .rectangle ? !Defaults[.cornerRadiusScaling] ? MusicPlayerImageSizes.cornerRadiusInset.closed : 12 : 100)
                            .fill(Color(red: 20/255, green: 20/255, blue: 20/255))
                            .strokeBorder(.white.opacity(0.04), lineWidth: 1)
                            .frame(width: geometry.size.width, height: geometry.size.width)
                        VStack(spacing: 8) {
                            Image(systemName: webcamManager.authorizationStatus == .denied ? "exclamationmark.triangle" : "web.camera")
                                .foregroundStyle(.gray)
                                .font(.system(size: geometry.size.width/3.5))
                            Text(webcamManager.authorizationStatus == .denied ? "Access Denied" : "Mirror")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                    }
                }
            }
            .overlay { cameraOverlays(size: geometry.size) }
            .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
            .onChange(of: webcamManager.flashCount) {
                flash = 0.85
                withAnimation(.easeOut(duration: 0.45)) { flash = 0 }
            }
            // Hoverbird: the camera button / closing the island control the session.
            // (Stopping on disappear switched the mirror off whenever you changed tabs.)
            .onTapGesture {
                if !webcamManager.isSessionRunning && webcamManager.authorizationStatus == .authorized {
                    webcamManager.startSession()
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
    
    /// Shutter flash, recording ring + timer, and the hover controls.
    @ViewBuilder
    private func cameraOverlays(size: CGSize) -> some View {
        let shape = RoundedRectangle(cornerRadius: Defaults[.mirrorShape] == .rectangle
                                     ? (!Defaults[.cornerRadiusScaling] ? MusicPlayerImageSizes.cornerRadiusInset.closed : MusicPlayerImageSizes.cornerRadiusInset.opened)
                                     : size.width / 2, style: .continuous)
        ZStack {
            shape.fill(Color.white.opacity(flash)).allowsHitTesting(false)
            if webcamManager.isRecording {
                shape.stroke(Color.red, lineWidth: 2.5).allowsHitTesting(false)
                if let start = webcamManager.recordingStart {
                    VStack {
                        HStack(spacing: 4) {
                            Circle().fill(Color.red).frame(width: 6, height: 6)
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(CameraFullScreenView.clock(context.date.timeIntervalSince(start)))
                                    .font(.system(size: 9.5, weight: .bold, design: .rounded).monospacedDigit())
                            }
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .padding(.top, 7)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }
            }
            // Hoverbird: Mac camera ⇄ iPhone camera (the Mac's is always the default).
            if webcamManager.isSessionRunning && !webcamManager.isRecording {
                VStack {
                    HStack(alignment: .top, spacing: 4) {
                        if webcamManager.source == .iPhone {
                            CameraSourceBadge(name: webcamManager.activeCameraName, compact: size.width < 140)
                                .transition(.scale(scale: 0.6, anchor: .topLeading).combined(with: .opacity))
                        }
                        Spacer(minLength: 0)
                        if hovering && (webcamManager.iPhoneCameraName != nil || webcamManager.source == .iPhone) {
                            let onIPhone = webcamManager.source == .iPhone
                            MirrorControl(symbol: onIPhone ? "laptopcomputer" : "iphone.gen3",
                                          help: onIPhone ? "Use this Mac's camera"
                                                         : "Use \(CameraSourceBadge.shortName(webcamManager.iPhoneCameraName) ?? "the iPhone camera")") {
                                webcamManager.toggleCameraSource()
                            }
                            .accessibilityIdentifier("mirror.switchCamera")
                            .transition(.opacity)
                        }
                    }
                    .padding(6)
                    Spacer()
                }
            }
            if webcamManager.isSwitchingCamera {
                shape.fill(Color.black.opacity(0.6)).allowsHitTesting(false)
                VStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text(webcamManager.source == .mac ? "iPhone…" : "Mac camera…")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .allowsHitTesting(false)
            }
            if webcamManager.isSessionRunning && (hovering || webcamManager.isRecording) {
                VStack {
                    Spacer()
                    HStack(spacing: 5) {
                        MirrorControl(symbol: webcamManager.isRecording ? "stop.fill" : "record.circle",
                                      tint: .red, help: webcamManager.isRecording ? "Stop recording" : "Record a video") {
                            webcamManager.toggleRecording()
                        }
                        MirrorControl(symbol: "camera.fill", help: "Take a photo") { webcamManager.capturePhoto() }
                        MirrorControl(symbol: "arrow.up.left.and.arrow.down.right", help: "Full screen") { CameraFullScreen.shared.show() }
                    }
                    .padding(4)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
                    .padding(.bottom, 7)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(width: size.width, height: size.width)
    }

    private func handleCameraTap() {
        if isRequestingAuthorization {
            return // Prevent multiple authorization requests
        }
        
        switch webcamManager.authorizationStatus {
        case .authorized:
            if webcamManager.isSessionRunning {
                webcamManager.stopSession()
            } else if webcamManager.cameraAvailable {
                webcamManager.startSession()
            }
        case .denied, .restricted:
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Camera Access Required"
                alert.informativeText = "Please allow camera access in System Settings to use the mirror feature."
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Cancel")

                if alert.runModal() == .alertFirstButtonReturn {
                    if let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                        NSWorkspace.shared.open(settingsURL)
                    }
                }
            }
        case .notDetermined:
            isRequestingAuthorization = true
            webcamManager.checkAndRequestVideoAuthorization()
            // Reset the request flag after a reasonable delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                isRequestingAuthorization = false
            }
        @unknown default:
            break
        }
    }
}

struct CameraPreviewLayerView: NSViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        previewLayer.frame = view.bounds
        previewLayer.videoGravity = .resizeAspectFill
        view.layer = previewLayer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = nsView.bounds
        CATransaction.commit()
    }
}


/// Hoverbird: shows that the picture comes from the iPhone. Opens with the camera's name
/// ("Alex's iPhone"), then settles into a small "iPhone" tag.
struct CameraSourceBadge: View {
    let name: String?
    var compact = true
    @State private var showName = true

    static func shortName(_ name: String?) -> String? {
        guard var name, !name.isEmpty else { return nil }
        for suffix in [" Camera", " camera"] where name.hasSuffix(suffix) { name.removeLast(suffix.count) }
        return name
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "iphone.gen3").font(.system(size: compact ? 8.5 : 12, weight: .bold))
            Text(showName ? (Self.shortName(name) ?? "iPhone") : "iPhone")
                .font(.system(size: compact ? 9 : 13, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, compact ? 6 : 12)
        .padding(.vertical, compact ? 2.5 : 6)
        .background(Capsule().fill(Color.black.opacity(0.5)))
        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
        .help(name ?? "iPhone camera")
        .allowsHitTesting(false)
        .task(id: name) {
            showName = true
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(.smooth(duration: 0.35)) { showName = false }
        }
    }
}

/// Small round control on the mirror.
private struct MirrorControl: View {
    let symbol: String
    var tint: Color = .white
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.25 : 0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { inside in hovering = inside }
        .help(help)
    }
}
