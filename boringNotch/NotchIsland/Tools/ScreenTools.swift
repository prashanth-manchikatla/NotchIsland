//
//  ScreenTools.swift
//  NotchIsland · Tools
//
//  The paid "screen grabber" tools, free and on-device:
//   • Copy Text — drag over anything on screen (a video, a PDF image, an error dialog) and its
//     text is copied, via Apple's Vision OCR. QR codes in the selection are read too.
//   • Scan QR — drag over a QR / barcode and its content is copied.
//   • Pick Color — the system loupe; the colour is copied as hex (no screen-recording access needed).
//  Results land on the clipboard (so they're in Clipboard history too) with a pill to confirm.
//

import AppKit
import SwiftUI
import Vision

@MainActor
enum ScreenTools {
    private static var busy = false

    static func copyText() { run(.text) }
    static func scanCode() { run(.code) }

    private enum Goal { case text, code }

    private static func run(_ goal: Goal) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            NotificationCenter.default.post(name: .islandCloseAll, object: nil)
            try? await Task.sleep(for: .milliseconds(320))
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("notchisland-grab-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: file) }
            // -i interactive selection (Space switches to window mode), -x no sound, -r no shadow.
            let status = await CaptureManager.run("/usr/sbin/screencapture", ["-i", "-x", "-r", file.path])
            guard status == 0, let image = NSImage(contentsOf: file)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return // cancelled with Esc, or Screen Recording isn't allowed
            }
            let result = await Task.detached(priority: .userInitiated) { recognize(image, text: goal == .text) }.value
            deliver(result, goal: goal)
        }
    }

    private struct Result: Sendable { var text: String; var codes: [String] }

    nonisolated private static func recognize(_ image: CGImage, text wantText: Bool) -> Result {
        var result = Result(text: "", codes: [])
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let barcodes = VNDetectBarcodesRequest()
        var requests: [VNRequest] = [barcodes]
        let ocr = VNRecognizeTextRequest()
        if wantText {
            ocr.recognitionLevel = .accurate
            ocr.usesLanguageCorrection = true
            ocr.automaticallyDetectsLanguage = true
            requests.append(ocr)
        }
        try? handler.perform(requests)
        result.codes = (barcodes.results ?? []).compactMap(\.payloadStringValue).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        if wantText {
            // Keep the reading order: top-to-bottom lines, left-to-right within a line.
            let lines = (ocr.results ?? []).compactMap { obs -> (CGRect, String)? in
                guard let best = obs.topCandidates(1).first else { return nil }
                return (obs.boundingBox, best.string)
            }
            .sorted { a, b in
                abs(a.0.midY - b.0.midY) > min(a.0.height, b.0.height) * 0.5 ? a.0.midY > b.0.midY : a.0.minX < b.0.minX
            }
            result.text = lines.map(\.1).joined(separator: "\n")
        }
        return result
    }

    private static func deliver(_ result: Result, goal: Goal) {
        let hub = IslandActivityHub.shared
        switch goal {
        case .text:
            if !result.text.isEmpty {
                copy(result.text)
                let words = result.text.split(whereSeparator: \.isWhitespace).count
                hub.showPill(.info(symbol: "text.viewfinder", text: "Copied \(words) word\(words == 1 ? "" : "s") from the screen", tint: .white), duration: 2.4)
            } else if let code = result.codes.first {
                copy(code)
                hub.showPill(.info(symbol: "qrcode", text: "Copied the code: \(AIFormat.oneLine(code, limit: 30))", tint: .white), duration: 2.6)
            } else {
                hub.showPill(.info(symbol: "text.viewfinder", text: "No text found there", tint: .orange), duration: 2.2)
            }
        case .code:
            if let code = result.codes.first {
                copy(result.codes.joined(separator: "\n"))
                let label = URL(string: code).flatMap { $0.scheme?.hasPrefix("http") == true ? $0.host : nil } ?? AIFormat.oneLine(code, limit: 30)
                hub.showPill(.info(symbol: "qrcode", text: "Copied \(URL(string: code)?.host != nil ? "link" : "code"): \(label)", tint: .white), duration: 2.6)
            } else {
                hub.showPill(.info(symbol: "qrcode", text: "No QR or barcode found there", tint: .orange), duration: 2.2)
            }
        }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Colour picker

    private static var sampler: NSColorSampler?

    static func pickColor() {
        NotificationCenter.default.post(name: .islandCloseAll, object: nil)
        let picker = NSColorSampler()
        sampler = picker
        picker.show { color in
            MainActor.assumeIsolated {
                sampler = nil
                guard let rgb = color?.usingColorSpace(.sRGB) else { return }
                let hex = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                                 Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
                copy(hex)
                IslandActivityHub.shared.showPill(.info(symbol: "circle.fill", text: "Copied \(hex)", tint: Color(nsColor: rgb)), duration: 2.4)
            }
        }
    }
}
