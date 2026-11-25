//
//  GrokLogs.swift
//  NotchIsland · AI Usage · Grok CLI
//
//  Reads Grok CLI session summaries: ~/.grok/sessions/<encoded-cwd>/<session-id>/usage.json
//  ({totalTokens, models, endedAt}). Grok only records a session total — no per-call split —
//  so a session shows as one entry with its total tokens (no API-price estimate).
//

import Foundation

final class GrokIngestor: AILogIngestor {
    let provider = AIProvider.grok

    private var cachedRoots: [URL] = []
    private var rootsStamp = Date.distantPast

    var roots: [URL] {
        if Date().timeIntervalSince(rootsStamp) > 60 {
            cachedRoots = AIFiles.existing([AIFiles.home.appendingPathComponent(".grok/sessions")])
            rootsStamp = Date()
        }
        return cachedRoots
    }

    func owns(_ path: String) -> Bool {
        path.hasSuffix("/usage.json") && roots.contains { path.hasPrefix($0.path + "/") }
    }

    func files(modifiedSince since: Date) -> [String] {
        AIFiles.enumerate(roots, since: since) { $0 == "usage.json" }
    }

    func ingest(path: String, cursor: inout AIFileCursor, into db: AIUsageDB) {
        guard let stat = AIFileReader.stat(path), stat.size != cursor.size || stat.modified != cursor.modified,
              let data = FileManager.default.contents(atPath: path), let obj = AIJSON.object(data) else { return }
        cursor.size = stat.size
        cursor.modified = stat.modified
        let sessionDir = URL(fileURLWithPath: path).deletingLastPathComponent()
        let session = sessionDir.lastPathComponent
        let encodedCwd = sessionDir.deletingLastPathComponent().lastPathComponent
        let cwd = encodedCwd.removingPercentEncoding.flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? "/" + encodedCwd.split(separator: "-").joined(separator: "/")
        let total = AIJSON.int(obj["totalTokens"])
        guard total > 0 else { return }
        let time = AIDate.fromEpoch(obj["endedAt"]) ?? stat.modified
        let model: String
        if let models = obj["models"] as? [String: Any] { model = models.keys.sorted().first ?? "grok" }
        else if let models = obj["models"] as? [String] { model = models.first ?? "grok" }
        else { model = "grok" }
        var t = AITokens()
        t.other = total
        db.requests["grok|\(session)"] = AIRequestRecord(provider: .grok, time: time, model: model, tokens: t, sessionID: session)
        db.touchSession(.grok, id: session, time: time, cwd: cwd, host: "Grok CLI")
    }
}
