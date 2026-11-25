//
//  AIUsageDB.swift
//  NotchIsland · AI Usage
//
//  What the ingestors have read so far (kept in memory; nothing is written to disk).
//  Owned by AIUsageEngine's serial queue. Records older than `retention` are dropped.
//

import Foundation

final class AIUsageDB {
    static let retention: TimeInterval = 35 * 86_400

    /// Deduplicated model calls, by provider-specific key (Claude: message.id|requestId).
    var requests: [String: AIRequestRecord] = [:]
    var tasks: [String: AITaskRecord] = [:]
    var sessions: [String: AISessionRecord] = [:]
    /// Latest limit state each provider wrote into its logs, by "provider.kind".
    var limitEvents: [String: AILogLimitEvent] = [:]
    /// What each session did last ("Edit · ContentView.swift").
    var activity: [String: AIActivity] = [:]
    /// Session titles the agent wrote (Claude's ai-title rows), by session id.
    var titles: [String: String] = [:]
    /// The agent's own cost figure for a session (Claude Code's cost-state), by session id.
    var reportedCosts: [String: Double] = [:]

    func touchSession(_ provider: AIProvider, id: String, time: Date, cwd: String? = nil,
                      branch: String? = nil, host: String? = nil, title: String? = nil) {
        if var s = sessions[id] {
            if time < s.start { s.start = time }
            if time > s.end { s.end = time }
            if let cwd, !cwd.isEmpty, s.cwd.isEmpty || s.cwd != cwd && time >= s.end {
                s.cwd = cwd; s.project = AIFormat.project(fromPath: cwd)
            }
            if let branch, !branch.isEmpty { s.branch = branch }
            if let host { s.host = host }
            if let title, !title.isEmpty { s.title = title }
            sessions[id] = s
        } else {
            let path = cwd ?? ""
            sessions[id] = AISessionRecord(id: id, provider: provider, title: title, project: AIFormat.project(fromPath: path),
                                           cwd: path, branch: branch, host: host, start: time, end: time)
        }
    }

    func recordLimit(_ event: AILogLimitEvent) {
        let key = "\(event.provider.rawValue).\(event.kind.rawValue)"
        if let old = limitEvents[key], old.time > event.time { return }
        limitEvents[key] = event
    }

    func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        requests = requests.filter { $0.value.time >= cutoff }
        tasks = tasks.filter { $0.value.start >= cutoff }
        sessions = sessions.filter { $0.value.end >= cutoff }
        activity = activity.filter { $0.value.time >= cutoff }
    }
}

/// One provider's log reader. Each call happens on the engine's queue.
protocol AILogIngestor: AnyObject {
    var provider: AIProvider { get }
    /// Folders the provider writes logs to (only existing ones are watched).
    var roots: [URL] { get }
    /// Does a changed path belong to this reader?
    func owns(_ path: String) -> Bool
    /// Log files modified after `since` (first scan and the periodic safety sweep).
    func files(modifiedSince since: Date) -> [String]
    /// Reads what changed in one file.
    func ingest(path: String, cursor: inout AIFileCursor, into db: AIUsageDB)
}

enum AIFiles {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static func existing(_ urls: [URL]) -> [URL] {
        urls.filter { var dir: ObjCBool = false; return FileManager.default.fileExists(atPath: $0.path, isDirectory: &dir) && dir.boolValue }
    }

    /// Recursively lists files under `roots` whose name passes `match`, modified after `since`.
    static func enumerate(_ roots: [URL], since: Date, match: (String) -> Bool) -> [String] {
        var out: [String] = []
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        for root in roots {
            // Hidden folders are walked on purpose: Claude Desktop keeps sessions in …/<id>/.claude/projects.
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                         options: [.skipsPackageDescendants]) else { continue }
            for case let url as URL in e {
                guard match(url.lastPathComponent),
                      let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                      (v.contentModificationDate ?? .distantPast) >= since else { continue }
                out.append(url.path)
            }
        }
        return out
    }
}
