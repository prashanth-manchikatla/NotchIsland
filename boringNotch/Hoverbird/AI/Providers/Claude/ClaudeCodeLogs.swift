//
//  ClaudeCodeLogs.swift
//  Hoverbird · AI Usage · Claude
//
//  Reads Claude Code transcripts. The terminal CLI, the VS Code / JetBrains extensions
//  and Claude Desktop all write the same JSONL:
//    ~/.claude/projects/<project>/<session>.jsonl
//    ~/.claude/projects/<project>/<session>/subagents/agent-<id>.jsonl
//  An assistant row carries message.usage. A reply is written as one row per content
//  block (same usage each time), so calls are deduplicated by message.id + requestId —
//  counting rows would inflate usage ~2.4× on real-world logs.
//  A "task" starts at each prompt you typed (origin.kind / turnOrigin == "human");
//  subagent calls are credited to the task that was running when they happened.
//

import Foundation

final class ClaudeCodeIngestor: AILogIngestor {
    let provider = AIProvider.claude

    private var cachedRoots: [URL] = []
    private var rootsStamp = Date.distantPast

    var roots: [URL] {
        if Date().timeIntervalSince(rootsStamp) > 60 {
            let home = AIFiles.home
            let desktop = home.appendingPathComponent("Library/Application Support/Claude")
            cachedRoots = AIFiles.existing([
                home.appendingPathComponent(".claude/projects"),
                home.appendingPathComponent(".config/claude/projects"),
                desktop.appendingPathComponent("claude-code-sessions"),
                desktop.appendingPathComponent("local-agent-mode-sessions"),
            ])
            rootsStamp = Date()
        }
        return cachedRoots
    }

    func owns(_ path: String) -> Bool {
        path.hasSuffix(".jsonl") && roots.contains { path.hasPrefix($0.path + "/") }
    }

    func files(modifiedSince since: Date) -> [String] {
        AIFiles.enumerate(roots, since: since) { $0.hasSuffix(".jsonl") }
    }

    // Byte patterns checked before any JSON parsing (most rows are tool results and file snapshots).
    private static let assistantTag = Array(#""type":"assistant""#.utf8)
    private static let userTag = Array(#""type":"user""#.utf8)
    private static let toolResultTag = Array(#""tool_use_id""#.utf8)
    private static let titleTag = Array(#""type":"ai-title""#.utf8)
    private static let costTag = Array(#""type":"cost-state""#.utf8)

    func ingest(path: String, cursor: inout AIFileCursor, into db: AIUsageDB) {
        let url = URL(fileURLWithPath: path)
        let isSubagentFile = path.contains("/subagents/")
        let fallbackSession = isSubagentFile
            ? url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            : url.deletingPathExtension().lastPathComponent
        var taskID = cursor.currentTaskID
        var sessionID = cursor.sessionID
        AIFileReader.readNewLines(path, cursor: &cursor, restarted: { taskID = nil; sessionID = nil }) { line in
            if AIFileReader.contains(line, Self.assistantTag) {
                assistant(line, isSubagentFile: isSubagentFile, taskID: taskID, fallbackSession: fallbackSession,
                          sessionID: &sessionID, db: db)
            } else if AIFileReader.contains(line, Self.userTag) {
                if !isSubagentFile, !AIFileReader.contains(line, Self.toolResultTag),
                   let task = prompt(line, fallbackSession: fallbackSession, db: db) {
                    taskID = task
                }
            } else if AIFileReader.contains(line, Self.titleTag) || AIFileReader.contains(line, Self.costTag) {
                meta(line, db: db)
            }
        }
        cursor.currentTaskID = taskID
        cursor.sessionID = sessionID
    }

    // MARK: Rows

    private func assistant(_ line: Data, isSubagentFile: Bool, taskID: String?, fallbackSession: String,
                           sessionID: inout String?, db: AIUsageDB) {
        guard let row = AIJSON.object(line), row["type"] as? String == "assistant",
              let message = row["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return }
        let model = message["model"] as? String ?? "unknown"
        guard model != "<synthetic>" else { return }
        let messageID = message["id"] as? String
        let requestID = row["requestId"] as? String
        guard messageID != nil || requestID != nil else { return }
        let session = row["sessionId"] as? String ?? sessionID ?? fallbackSession
        sessionID = session
        let time = AIDate.parse(row["timestamp"] as? String) ?? Date()

        var t = AITokens()
        t.input = AIJSON.int(usage["input_tokens"])
        t.output = AIJSON.int(usage["output_tokens"])
        t.cacheRead = AIJSON.int(usage["cache_read_input_tokens"])
        if let split = usage["cache_creation"] as? [String: Any] {
            t.cacheWrite5m = AIJSON.int(split["ephemeral_5m_input_tokens"])
            t.cacheWrite1h = AIJSON.int(split["ephemeral_1h_input_tokens"])
        }
        if t.cacheWrite == 0 { t.cacheWrite5m = AIJSON.int(usage["cache_creation_input_tokens"]) }
        t.reasoning = AIJSON.int((usage["output_tokens_details"] as? [String: Any])?["thinking_tokens"])
        let searches = AIJSON.int((usage["server_tool_use"] as? [String: Any])?["web_search_requests"])
        let isSubagent = isSubagentFile || (row["isSidechain"] as? Bool) == true

        let key = "claude|\(messageID ?? "")|\(requestID ?? "")"
        var record = AIRequestRecord(provider: .claude, time: time, model: model, tokens: t, webSearches: searches,
                                     sessionID: session, taskID: isSubagent ? nil : taskID, isSubagent: isSubagent)
        record.cost = AIPricing.cost(model: model, tokens: t, webSearches: searches)
        if let old = db.requests[key] { // a later row of the same reply: keep the first time and its task
            record.time = min(old.time, time)
            if record.taskID == nil { record.taskID = old.taskID }
        }
        db.requests[key] = record
        db.touchSession(.claude, id: session, time: time, cwd: row["cwd"] as? String,
                        branch: row["gitBranch"] as? String, host: Self.host(row["entrypoint"] as? String))

        if let quota = row["quotaLimits"] as? [String: Any], let event = Self.limitEvent(quota, time: time) {
            db.recordLimit(event)
        }
        if !isSubagent, let activity = Self.lastToolUse(message["content"]) {
            db.activity[session] = AIActivity(text: activity, time: time)
        }
    }

    /// A prompt you typed starts a new task. Returns its id.
    private func prompt(_ line: Data, fallbackSession: String, db: AIUsageDB) -> String? {
        guard let row = AIJSON.object(line), row["type"] as? String == "user",
              let message = row["message"] as? [String: Any] else { return nil }
        if (row["isMeta"] as? Bool) == true || (row["isCompactSummary"] as? Bool) == true
            || (row["isVisibleInTranscriptOnly"] as? Bool) == true { return nil }
        let originKind = (row["origin"] as? [String: Any])?["kind"] as? String
        let turnOrigin = row["turnOrigin"] as? String
        if let originKind, originKind != "human" { return nil }        // task notifications, hooks…
        if let turnOrigin, turnOrigin != "human" { return nil }
        let explicitlyHuman = originKind == "human" || turnOrigin == "human"
        guard let text = Self.promptText(message["content"], explicitlyHuman: explicitlyHuman) else { return nil }

        let session = row["sessionId"] as? String ?? fallbackSession
        let time = AIDate.parse(row["timestamp"] as? String) ?? Date()
        let cwd = row["cwd"] as? String ?? ""
        let id = (row["promptId"] as? String) ?? (row["uuid"] as? String) ?? "\(session)|\(time.timeIntervalSince1970)"
        if db.tasks[id] == nil {
            db.tasks[id] = AITaskRecord(id: id, provider: .claude, sessionID: session, prompt: text, start: time,
                                        project: AIFormat.project(fromPath: cwd), end: time)
        }
        db.touchSession(.claude, id: session, time: time, cwd: cwd, branch: row["gitBranch"] as? String,
                        host: Self.host(row["entrypoint"] as? String))
        return id
    }

    private func meta(_ line: Data, db: AIUsageDB) {
        guard let row = AIJSON.object(line), let session = row["sessionId"] as? String else { return }
        switch row["type"] as? String {
        case "ai-title":
            if let title = row["aiTitle"] as? String, !title.isEmpty { db.titles[session] = title }
        case "cost-state":
            if let cost = AIJSON.double(row["totalCostUSD"]) { db.reportedCosts[session] = cost }
        default:
            break
        }
    }

    // MARK: Helpers

    /// The text you typed: skips IDE context blocks / reminders, turns `<command-name>` into "/command".
    static func promptText(_ content: Any?, explicitlyHuman: Bool) -> String? {
        var texts: [String] = []
        if let s = content as? String {
            texts = [s]
        } else if let blocks = content as? [[String: Any]] {
            texts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        }
        for raw in texts {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if let open = t.range(of: "<command-name>"),
               let close = t.range(of: "</command-name>", range: open.upperBound..<t.endIndex) {
                var name = String(t[open.upperBound..<close.lowerBound])
                if !name.hasPrefix("/") { name = "/" + name }
                if let a = t.range(of: "<command-args>"),
                   let ae = t.range(of: "</command-args>", range: a.upperBound..<t.endIndex) {
                    let args = String(t[a.upperBound..<ae.lowerBound])
                    if !args.isEmpty { name += " " + args }
                }
                return AIFormat.oneLine(name)
            }
            if t.hasPrefix("<") || t.hasPrefix("Caveat:") { continue } // IDE context, reminders, local command output
            return AIFormat.oneLine(t)
        }
        // Only context blocks: a real prompt (e.g. an image with IDE context) still counts.
        return explicitlyHuman && !texts.isEmpty ? "Prompt" : nil
    }

    static func host(_ entrypoint: String?) -> String? {
        guard let raw = entrypoint, !raw.isEmpty else { return nil }
        let e = raw.lowercased()
        if e.contains("vscode") { return "VS Code" }
        if e.contains("cursor") { return "Cursor" }
        if e.contains("windsurf") { return "Windsurf" }
        if e.contains("jetbrains") || e.contains("intellij") { return "JetBrains" }
        if e.contains("desktop") { return "Claude Desktop" }
        if e == "cli" { return "Terminal" }
        if e.contains("sdk") { return "Agent SDK" }
        return raw
    }

    /// "Edit · ContentView.swift", "Bash · npm test", "WebFetch · github.com".
    static func lastToolUse(_ content: Any?) -> String? {
        guard let blocks = content as? [[String: Any]],
              let use = blocks.last(where: { $0["type"] as? String == "tool_use" }),
              let name = use["name"] as? String else { return nil }
        let input = use["input"] as? [String: Any] ?? [:]
        var detail: String?
        if let p = (input["file_path"] ?? input["path"] ?? input["notebook_path"]) as? String {
            detail = URL(fileURLWithPath: p).lastPathComponent
        } else if let c = input["command"] as? String {
            detail = AIFormat.oneLine(c, limit: 48)
        } else if let u = input["url"] as? String {
            detail = URL(string: u)?.host ?? AIFormat.oneLine(u, limit: 40)
        } else if let q = (input["pattern"] ?? input["query"] ?? input["description"]) as? String {
            detail = AIFormat.oneLine(q, limit: 44)
        }
        let tool = name.hasPrefix("mcp__") ? (name.components(separatedBy: "__").last ?? name) : name
        return detail.map { "\(tool) · \($0)" } ?? tool
    }

    /// Claude writes `quotaLimits` on a reply when the limit state changes (e.g. "rejected" = limit hit).
    static func limitEvent(_ q: [String: Any], time: Date) -> AILogLimitEvent? {
        guard let status = q["status"] as? String else { return nil }
        let type = (q["rateLimitType"] as? String) ?? "five_hour"
        let kind: AILimitWindow.Kind = type.hasPrefix("five") ? .session : (type == "seven_day" ? .weekly : .weeklyModel)
        let used = AIJSON.double(q["utilization"]).map { $0 <= 1 ? $0 * 100 : $0 }
        return AILogLimitEvent(provider: .claude, time: time, kind: kind, status: status, usedPercent: used,
                               resetsAt: AIDate.fromEpoch(q["resetsAt"]), windowMinutes: kind == .session ? 300 : 10_080)
    }
}
