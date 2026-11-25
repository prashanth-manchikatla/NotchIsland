//
//  AIFormat.swift
//  NotchIsland · AI Usage
//
//  Small helpers shared by the ingestors and the views: number / time formatting,
//  a fast ISO-8601 parser (logs have hundreds of thousands of timestamps) and an
//  incremental line reader that only reads bytes appended since last time.
//

import Darwin
import Foundation

enum AIFormat {
    /// 0, 999, 1.2K, 12K, 1.2M, 12M, 1.2B
    static func tokens(_ n: Int) -> String {
        let v = Double(n)
        switch abs(v) {
        case ..<1_000: return "\(n)"
        case ..<10_000: return String(format: "%.1fK", v / 1_000)
        case ..<1_000_000: return String(format: "%.0fK", v / 1_000)
        case ..<10_000_000: return String(format: "%.1fM", v / 1_000_000)
        case ..<1_000_000_000: return String(format: "%.0fM", v / 1_000_000)
        default: return String(format: "%.1fB", v / 1_000_000_000)
        }
    }

    static func cost(_ dollars: Double) -> String {
        switch dollars {
        case 0: return "$0"
        case ..<0.01: return "<$0.01"
        case ..<10: return String(format: "$%.2f", dollars)
        case ..<1_000: return String(format: "$%.0f", dollars)
        default: return String(format: "$%.1fK", dollars / 1_000)
        }
    }

    static func percent(_ p: Double) -> String { "\(Int(p.rounded()))%" }

    /// 45s · 12m · 1h 12m · 2d 3h
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "\(s)s" }
        if s < 3_600 { return "\(s / 60)m" }
        if s < 86_400 { let m = (s % 3_600) / 60; return m == 0 ? "\(s / 3_600)h" : "\(s / 3_600)h \(m)m" }
        let h = (s % 86_400) / 3_600
        return h == 0 ? "\(s / 86_400)d" : "\(s / 86_400)d \(h)h"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f
    }()
    private static let dayTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEE j:mm"); return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEE d MMM"); return f
    }()

    /// "3:10 PM" today, otherwise "Thu 9:00 AM".
    static func clock(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? timeFormatter.string(from: date) : dayTimeFormatter.string(from: date)
    }

    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }

    /// "now", "4m ago", "3h ago", "yesterday", "Mon 24 Nov".
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(date)
        if s < 45 { return "now" }
        if s < 3_600 { return "\(Int(s / 60))m ago" }
        if s < 86_400 && Calendar.current.isDateInToday(date) { return "\(Int(s / 3_600))h ago" }
        if Calendar.current.isDateInYesterday(date) { return "yesterday" }
        return day(date)
    }

    /// "in 1h 12m"
    static func until(_ date: Date, now: Date = Date()) -> String {
        let s = date.timeIntervalSince(now)
        return s <= 0 ? "now" : "in \(duration(s))"
    }

    /// "claude-opus-5-5" → "Opus 5.5", "gpt-5-codex" → "GPT-5 Codex", "gemini-2.5-pro" → "Gemini 2.5 Pro".
    static func model(_ id: String) -> String {
        let m = AIPricing.normalize(id)
        if m.hasPrefix("claude-") {
            var parts = m.dropFirst("claude-".count).split(separator: "-").map(String.init)
            parts = parts.filter { !($0.count >= 8 && $0.allSatisfy(\.isNumber)) } // drop date stamps
            guard let family = parts.first(where: { $0.first?.isLetter == true }) else { return id }
            let version = parts.filter { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
            return family.capitalized + (version.isEmpty ? "" : " " + version)
        }
        if m.hasPrefix("gpt-") {
            return "GPT-" + m.dropFirst(4).split(separator: "-").enumerated()
                .map { $0.offset == 0 ? String($0.element) : $0.element.capitalized }.joined(separator: " ")
        }
        if m.hasPrefix("gemini-") || m.hasPrefix("grok-") {
            return id.replacingOccurrences(of: "models/", with: "").split(separator: "-")
                .map { $0.first?.isNumber == true ? String($0) : $0.capitalized }.joined(separator: " ")
        }
        return id
    }

    /// "/Users/me/Downloads/NotchIsland" → "NotchIsland"; the home folder → "~".
    static func project(fromPath path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.isEmpty { return "—" }
        if path == home || path == home + "/" { return "~" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// One line, no runs of whitespace, at most `limit` characters.
    static func oneLine(_ text: String, limit: Int = 200) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > limit ? String(collapsed.prefix(limit - 1)) + "…" : collapsed
    }
}

// MARK: - Dates

enum AIDate {
    private static let fallback: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let fallbackNoFraction = ISO8601DateFormatter()

    /// "2026-11-13T12:05:01.986Z" / "…+05:30" / "…Z" without fraction. Fast path for UTC "Z".
    static func parse(_ string: String?) -> Date? {
        guard let s = string, s.count >= 20 else { return nil }
        let u = Array(s.utf8)
        func num(_ from: Int, _ len: Int) -> Int? {
            var v = 0
            for i in from..<(from + len) {
                guard i < u.count, u[i] >= 48, u[i] <= 57 else { return nil }
                v = v * 10 + Int(u[i] - 48)
            }
            return v
        }
        if u.last == UInt8(ascii: "Z"), u.count >= 20, u[4] == 45, u[10] == 84,
           let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2),
           let h = num(11, 2), let mi = num(14, 2), let se = num(17, 2) {
            var t = tm(tm_sec: Int32(se), tm_min: Int32(mi), tm_hour: Int32(h), tm_mday: Int32(d),
                       tm_mon: Int32(mo - 1), tm_year: Int32(y - 1900), tm_wday: 0, tm_yday: 0,
                       tm_isdst: 0, tm_gmtoff: 0, tm_zone: nil)
            let seconds = timegm(&t)
            var fraction = 0.0
            if u.count > 21, u[19] == 46 { // ".986Z"
                var scale = 0.1
                for i in 20..<(u.count - 1) where u[i] >= 48 && u[i] <= 57 {
                    fraction += Double(u[i] - 48) * scale
                    scale /= 10
                }
            }
            return Date(timeIntervalSince1970: TimeInterval(seconds) + fraction)
        }
        return fallback.date(from: s) ?? fallbackNoFraction.date(from: s)
    }

    /// Unix seconds or milliseconds → Date.
    static func fromEpoch(_ value: Any?) -> Date? {
        guard let n = AIJSON.double(value), n > 0 else {
            if let s = value as? String { return parse(s) }
            return nil
        }
        return Date(timeIntervalSince1970: n > 10_000_000_000 ? n / 1000 : n)
    }
}

// MARK: - JSON helpers

enum AIJSON {
    static func int(_ value: Any?) -> Int {
        switch value {
        case let n as Int: return n
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s) ?? 0
        default: return 0
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
    }
}

// MARK: - Incremental file reading

/// Where we got to in one log file.
struct AIFileCursor {
    var offset: UInt64 = 0
    var inode: UInt64 = 0
    var size: UInt64 = 0
    var modified: Date = .distantPast
    // Provider state carried between reads:
    var currentTaskID: String?
    var sessionID: String?
    var model: String?
    var cumulative: AITokens?
}

enum AIFileReader {
    struct Stat { let inode: UInt64; let size: UInt64; let modified: Date }

    static func stat(_ path: String) -> Stat? {
        var st = Darwin.stat()
        guard fstatat(AT_FDCWD, path, &st, 0) == 0 else { return nil }
        let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
        return Stat(inode: UInt64(st.st_ino), size: UInt64(st.st_size), modified: mtime)
    }

    /// True when the file changed since the cursor saw it.
    static func hasChanges(_ path: String, cursor: AIFileCursor) -> Bool {
        guard let s = stat(path) else { return false }
        return s.inode != cursor.inode || s.size != cursor.offset
    }

    /// Calls `handle` for each complete line appended since `cursor.offset` and advances the cursor.
    /// A file that was replaced or truncated is read again from the start (`restarted` = true).
    @discardableResult
    static func readNewLines(_ path: String, cursor: inout AIFileCursor,
                             restarted: (() -> Void)? = nil, handle: (Data) -> Void) -> Bool {
        guard let s = stat(path) else { return false }
        if s.inode != cursor.inode || s.size < cursor.offset {
            cursor = AIFileCursor(inode: s.inode)
            restarted?()
        }
        cursor.size = s.size
        cursor.modified = s.modified
        guard s.size > cursor.offset, let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        do { try fh.seek(toOffset: cursor.offset) } catch { return false }

        var carry = Data()
        var consumed: UInt64 = 0
        let chunkSize = 1 << 20
        while true {
            let chunk: Data
            do { chunk = try fh.read(upToCount: chunkSize) ?? Data() } catch { break }
            if chunk.isEmpty { break }
            carry.append(chunk)
            var lineStart = carry.startIndex
            // JSONSerialization's objects are autoreleased: drain them per chunk, or a first scan of
            // hundreds of MB of logs piles them all up until the scan ends.
            autoreleasepool {
            carry.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                var position = 0
                while position < raw.count,
                      let hit = memchr(base + position, 0x0A, raw.count - position) {
                    let end = base.distance(to: hit)
                    if end > position {
                        handle(carry.subdata(in: (carry.startIndex + position)..<(carry.startIndex + end)))
                    }
                    position = end + 1
                }
                lineStart = carry.startIndex + position
            }
            }
            consumed += UInt64(lineStart - carry.startIndex)
            carry = carry.subdata(in: lineStart..<carry.endIndex)
            if chunk.count < chunkSize { break }
        }
        cursor.offset += consumed // a trailing partial line is read again next time
        return consumed > 0
    }

    /// Fast "does this line contain these bytes" (memmem), so most lines skip JSON parsing.
    static func contains(_ line: Data, _ needle: [UInt8]) -> Bool {
        line.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            return needle.withUnsafeBufferPointer { n in memmem(base, raw.count, n.baseAddress, n.count) != nil }
        }
    }
}
