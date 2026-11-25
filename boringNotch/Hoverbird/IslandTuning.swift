//
//  IslandTuning.swift
//  Hoverbird
//
//  Optional runtime knobs in ~/Library/Application Support/Hoverbird/tuning.json
//  (lets behaviour be adjusted without rebuilding — rebuilding an ad-hoc signed
//  app makes macOS forget its privacy permissions).
//

import Foundation

struct IslandTuning: Codable {
    /// Flip the live-video crop vertically (if ScreenCaptureKit's origin differs).
    var liveVideoFlipY: Bool? = nil
    /// Luma difference (0-255) that counts as "moving" for video detection.
    var liveVideoMotionThreshold: Int? = nil
    /// Heat (0-255) a cell needs to be part of the moving region.
    var liveVideoHeatThreshold: Int? = nil
    /// Write live-video debug info to livevideo-debug.txt.
    var liveVideoDebug: Bool? = nil

    private static var cached = IslandTuning()
    private static var cachedDate: Date?
    private static let lock = NSLock()

    static var current: IslandTuning {
        lock.withLock {
            let url = IslandPaths.appSupportPath.appendingPathComponent("tuning.json")
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            if modified != cachedDate {
                cachedDate = modified
                if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(IslandTuning.self, from: data) {
                    cached = decoded
                } else {
                    cached = IslandTuning()
                }
            }
            return cached
        }
    }
}

/// Tiny append-only debug log (only written when a feature asks for it).
enum IslandDebugLog {
    private static let lock = NSLock()

    static func write(_ name: String, _ line: String, reset: Bool = false) {
        lock.withLock {
            let url = IslandPaths.appSupportPath.appendingPathComponent(name)
            let stamp = ISO8601DateFormatter().string(from: Date())
            let text = "[\(stamp)] \(line)\n"
            if reset || !FileManager.default.fileExists(atPath: url.path) {
                try? text.write(to: url, atomically: true, encoding: .utf8)
                return
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                if (try? handle.offset()) ?? 0 > 200_000 { return }
                handle.write(Data(text.utf8))
            }
        }
    }
}

/// Returns memory that was freed (startup scans, closed island views) to the system.
/// macOS otherwise keeps those emptied malloc pages counted against the app until
/// memory gets tight; handing them back keeps Hoverbird's footprint small.
enum IslandMemory {
    private static var pending: DispatchWorkItem?

    static func trimSoon(after seconds: Double = 6) {
        pending?.cancel()
        let work = DispatchWorkItem { _ = malloc_zone_pressure_relief(nil, 0) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
