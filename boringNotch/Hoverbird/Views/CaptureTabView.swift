//
//  CaptureTabView.swift
//  Hoverbird
//

import Defaults
import SwiftUI

struct CaptureTabView: View {
    @ObservedObject private var capture = CaptureManager.shared
    @Default(.captureCopyToClipboard) private var copyToClipboard
    @Default(.recordSystemAudio) private var systemAudio
    @Default(.recordMicrophone) private var microphone
    @Default(.recordShowClicks) private var showClicks

    var body: some View {
        VStack(spacing: 10) {
            if capture.isRecording || capture.countdown != nil {
                recordingControls
            } else {
                HStack(spacing: 8) {
                    CaptureButton(title: "Selection", subtitle: "Screenshot", symbol: "rectangle.dashed", tint: .white) {
                        capture.screenshot(.area)
                    }
                    CaptureButton(title: "Window", subtitle: "Screenshot", symbol: "macwindow", tint: .white) {
                        capture.screenshot(.window)
                    }
                    CaptureButton(title: "Full Screen", subtitle: "Screenshot", symbol: "macbook", tint: .white) {
                        capture.screenshot(.fullScreen)
                    }
                    CaptureButton(title: "Selection", subtitle: "Record", symbol: "rectangle.dashed.badge.record", tint: .red) {
                        capture.startRecording(.area)
                    }
                    CaptureButton(title: "Full Screen", subtitle: "Record", symbol: "record.circle", tint: .red) {
                        capture.startRecording(.fullScreen)
                    }
                }
                // Hoverbird: screen tools (on-device OCR / codes / colour).
                HStack(spacing: 6) {
                    ToolButton(title: "Copy Text", symbol: "text.viewfinder", help: "Drag over anything on screen to copy its text (⇧⌘2)") {
                        ScreenTools.copyText()
                    }
                    ToolButton(title: "Scan QR", symbol: "qrcode.viewfinder", help: "Drag over a QR code or barcode to copy what it says") {
                        ScreenTools.scanCode()
                    }
                    ToolButton(title: "Pick Color", symbol: "eyedropper.halffull", help: "Pick any colour on screen — copied as hex") {
                        ScreenTools.pickColor()
                    }
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 6) {
                OptionChip(title: "Copy", symbol: "doc.on.doc", isOn: $copyToClipboard)
                OptionChip(title: "System audio", symbol: "speaker.wave.2", isOn: $systemAudio)
                OptionChip(title: "Mic", symbol: "mic", isOn: $microphone)
                OptionChip(title: "Clicks", symbol: "cursorarrow.click", isOn: $showClicks)
                Spacer(minLength: 4)
                if let last = capture.lastCapture {
                    Button { capture.openLastCapture() } label: {
                        CaptureThumbnail(url: last, isVideo: last.pathExtension.lowercased() == "mov")
                            .frame(width: 30, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help("Open \(last.lastPathComponent)")
                }
                Button { capture.revealLastCapture() } label: {
                    Image(systemName: "folder").font(.system(size: 11, weight: .semibold)).foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
                .help("Show captures in Finder")
            }
            if let error = capture.lastError {
                Text(error)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .onTapGesture { capture.lastError = nil }
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    private var recordingControls: some View {
        Button {
            capture.stopRecording()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "stop.circle.fill").font(.system(size: 30, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(capture.countdown != nil ? "Starting in \(capture.countdown ?? 0)…" : "Stop Recording")
                        .font(.system(size: 15, weight: .semibold))
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(capture.recordingStart.map { IslandTimerManager.clock(context.date.timeIntervalSince($0)) } ?? "Click to cancel")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .opacity(0.8)
                    }
                }
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 74)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.red.opacity(0.75)))
        }
        .buttonStyle(.plain)
    }
}

private struct CaptureButton: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(height: 26)
                VStack(spacing: 0) {
                    Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    Text(subtitle).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.gray)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 60)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.14 : 0.07)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.06)))
            .scaleEffect(hovering ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { hovering = h } }
    }
}

/// A one-line tool button (Copy Text / Scan QR / Pick Color).
private struct ToolButton: View {
    let title: String
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(Capsule().fill(Color.white.opacity(hovering ? 0.16 : 0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .help(help)
    }
}

private struct OptionChip: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(isOn ? Color.white.opacity(0.2) : Color.white.opacity(0.06)))
                .foregroundStyle(isOn ? .white : .gray)
        }
        .buttonStyle(.plain)
    }
}
