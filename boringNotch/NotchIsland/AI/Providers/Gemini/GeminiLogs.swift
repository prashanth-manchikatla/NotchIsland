//
//  GeminiLogs.swift
//  NotchIsland · AI Usage · Gemini CLI
//
//  Reads Gemini CLI chat recordings: ~/.gemini/tmp/<project-hash>/chats/session-*.json.
//  Each file is one session, rewritten as it grows: {sessionId, messages: [{id, timestamp,
//  type "user" | "gemini", content, model, tokens {input, output, cached, thoughts, tool}}]}.
//  Gemini's input count includes cached tokens; thoughts are billed as output.
//  Records are keyed by message id, so reading a rewritten file again never double-counts.
//

import Foundation

final class GeminiIngestor: AILogIngestor {
    let provider = AIProvider.gemini

    private var cachedRoots: [URL] = []
    private var rootsStamp = Date.distantPast

    var roots: [URL] {
        if Date().timeIntervalSince(rootsStamp) > 60 {
            cachedRoots = AIFiles.existing([AIFiles.home.appendingPathComponent(".gemini/tmp")])
            rootsStamp = Date()
        }
        return cachedRoots
    }

    func owns(_ path: String) -> Bool {
        path.hasSuffix(".json") && path.contains("/chats/") && roots.contains { path.hasPrefix($0.path + "/") }
    }

    func files(modifiedSince since: Date) -> [String] {
        AIFiles.enumerate(roots, since: since) { $0.hasPrefix("session-") && $0.hasSuffix(".json") }
            .filter { $0.contains("/chats/") }
    }

    func ingest(path: String, cursor: inout AIFileCursor, into db: AIUsageDB) {
        guard let stat = AIFileReader.stat(path), stat.size != cursor.size || stat.modified != cursor.modified,
              stat.size < 64 << 20, let data = FileManager.default.contents(atPath: path),
              let obj = AIJSON.object(data) else { return }
        cursor.size = stat.size
        cursor.modified = stat.modified
        let session = obj["sessionId"] as? String ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let projectHash = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        let project = (obj["projectRoot"] as? String).map { AIFormat.project(fromPath: $0) } ?? "Gemini · \(projectHash.prefix(6))"
        var taskID: String?
        for case let m as [String: Any] in obj["messages"] as? [Any] ?? [] {
            let time = AIDate.parse(m["timestamp"] as? String) ?? stat.modified
            let id = m["id"] as? String ?? "\(time.timeIntervalSince1970)"
            switch m["type"] as? String {
            case "user":
                let text = AIFormat.oneLine(Self.text(m["content"]))
                guard !text.isEmpty else { continue }
                let key = "gemini|\(session)|\(id)"
                if db.tasks[key] == nil {
                    db.tasks[key] = AITaskRecord(id: key, provider: .gemini, sessionID: session, prompt: text,
                                                 start: time, project: project, end: time)
                }
                taskID = key
                db.touchSession(.gemini, id: session, time: time)
                db.sessions[session]?.project = project
            case "gemini":
                guard let tokens = m["tokens"] as? [String: Any] else { continue }
                let model = m["model"] as? String ?? "gemini"
                let input = AIJSON.int(tokens["input"]), cached = min(input, AIJSON.int(tokens["cached"]))
                let thoughts = AIJSON.int(tokens["thoughts"])
                var t = AITokens()
                t.input = input - cached + AIJSON.int(tokens["tool"])
                t.cacheRead = cached
                t.output = AIJSON.int(tokens["output"]) + thoughts
                t.reasoning = thoughts
                var r = AIRequestRecord(provider: .gemini, time: time, model: model, tokens: t, sessionID: session, taskID: taskID)
                r.cost = AIPricing.cost(model: model, tokens: t)
                db.requests["gemini|\(session)|\(id)"] = r
                db.touchSession(.gemini, id: session, time: time)
                db.sessions[session]?.project = project
                if let calls = m["toolCalls"] as? [[String: Any]], let name = calls.last?["name"] as? String {
                    db.activity[session] = AIActivity(text: name, time: time)
                }
            default:
                continue
            }
        }
    }

    private static func text(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let parts = content as? [[String: Any]] { return parts.compactMap { $0["text"] as? String }.joined(separator: " ") }
        return ""
    }
}
