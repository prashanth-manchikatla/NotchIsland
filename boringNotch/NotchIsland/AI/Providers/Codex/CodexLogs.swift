//
//  CodexLogs.swift
//  NotchIsland · AI Usage · Codex (OpenAI)
//
//  Reads Codex CLI / IDE rollouts: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
//  (and ~/.codex/archived_sessions). Every line is {"timestamp", "type", "payload"}:
//    session_meta  → session id, cwd, originator (CLI / VS Code)
//    turn_context  → the model in use
//    event_msg user_message → a prompt you typed (a task)
//    event_msg token_count  → cumulative token usage + the ChatGPT plan's rate limits
//                             (primary ≈ 5-hour window, secondary ≈ weekly)
//  Calls are taken as deltas of the cumulative total, so repeated events count once.
//  OpenAI's input_tokens include cached tokens; they're split into input + cache read.
//

import Foundation

final class CodexIngestor: AILogIngestor {
    let provider = AIProvider.codex

    private var cachedRoots: [URL] = []
    private var rootsStamp = Date.distantPast

    var roots: [URL] {
        if Date().timeIntervalSince(rootsStamp) > 60 {
            let codex = AIFiles.home.appendingPathComponent(".codex")
            cachedRoots = AIFiles.existing([codex.appendingPathComponent("sessions"),
                                            codex.appendingPathComponent("archived_sessions")])
            rootsStamp = Date()
        }
        return cachedRoots
    }

    func owns(_ path: String) -> Bool {
        path.hasSuffix(".jsonl") && roots.contains { path.hasPrefix($0.path + "/") }
    }

    func files(modifiedSince since: Date) -> [String] {
        AIFiles.enumerate(roots, since: since) { $0.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") }
    }

    private static let tags = [#""session_meta""#, #""turn_context""#, #""token_count""#, #""user_message""#, #""function_call""#]
        .map { Array($0.utf8) }

    func ingest(path: String, cursor: inout AIFileCursor, into db: AIUsageDB) {
        var session = cursor.sessionID ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        var model = cursor.model ?? "codex"
        var taskID = cursor.currentTaskID
        var totals = cursor.cumulative
        AIFileReader.readNewLines(path, cursor: &cursor, restarted: { taskID = nil; totals = nil }) { line in
            guard Self.tags.contains(where: { AIFileReader.contains(line, $0) }),
                  let row = AIJSON.object(line), let payload = row["payload"] as? [String: Any] else { return }
            let time = AIDate.parse(row["timestamp"] as? String) ?? Date()
            switch row["type"] as? String {
            case "session_meta":
                if let id = payload["id"] as? String { session = id }
                db.touchSession(.codex, id: session, time: AIDate.parse(payload["timestamp"] as? String) ?? time,
                                cwd: payload["cwd"] as? String,
                                branch: (payload["git"] as? [String: Any])?["branch"] as? String,
                                host: Self.host(payload["originator"] as? String))
            case "turn_context":
                if let m = payload["model"] as? String { model = m }
                db.touchSession(.codex, id: session, time: time, cwd: payload["cwd"] as? String)
            case "event_msg":
                switch payload["type"] as? String {
                case "user_message":
                    let text = AIFormat.oneLine(payload["message"] as? String ?? "")
                    guard !text.isEmpty, !text.hasPrefix("<") else { break }
                    let id = "codex|\(session)|\(time.timeIntervalSince1970)"
                    if db.tasks[id] == nil {
                        db.tasks[id] = AITaskRecord(id: id, provider: .codex, sessionID: session, prompt: text, start: time,
                                                    project: db.sessions[session]?.project ?? "—", end: time)
                    }
                    taskID = id
                    db.touchSession(.codex, id: session, time: time)
                case "token_count":
                    if let info = payload["info"] as? [String: Any],
                       let total = info["total_token_usage"] as? [String: Any] {
                        let now = Self.tokens(total)
                        let previous = totals ?? AITokens()
                        totals = now
                        // A smaller total means a new thread in the same file: start over from it.
                        let delta = now.total >= previous.total ? Self.minus(now, previous) : now
                        if delta.total > 0 {
                            let key = "codex|\(session)|\(now.total)"
                            var r = AIRequestRecord(provider: .codex, time: time, model: model, tokens: delta,
                                                    sessionID: session, taskID: taskID)
                            r.cost = AIPricing.cost(model: model, tokens: delta)
                            db.requests[key] = r
                            db.touchSession(.codex, id: session, time: time)
                        }
                    }
                    if let limits = payload["rate_limits"] as? [String: Any] {
                        for event in Self.limitEvents(limits, time: time) { db.recordLimit(event) }
                    }
                default:
                    break
                }
            case "response_item":
                if payload["type"] as? String == "function_call", let name = payload["name"] as? String {
                    db.activity[session] = AIActivity(text: Self.describeCall(name, payload["arguments"] as? String), time: time)
                }
            default:
                break
            }
        }
        cursor.sessionID = session
        cursor.model = model
        cursor.currentTaskID = taskID
        cursor.cumulative = totals
    }

    // MARK: Helpers

    /// OpenAI counts cached tokens inside input_tokens: split them out so pricing is right.
    static func tokens(_ u: [String: Any]) -> AITokens {
        let input = AIJSON.int(u["input_tokens"])
        let cached = min(input, AIJSON.int(u["cached_input_tokens"]))
        var t = AITokens()
        t.input = input - cached
        t.cacheRead = cached
        t.output = AIJSON.int(u["output_tokens"])
        t.reasoning = AIJSON.int(u["reasoning_output_tokens"])
        return t
    }

    static func minus(_ a: AITokens, _ b: AITokens) -> AITokens {
        AITokens(input: max(0, a.input - b.input), output: max(0, a.output - b.output),
                 cacheRead: max(0, a.cacheRead - b.cacheRead), reasoning: max(0, a.reasoning - b.reasoning))
    }

    /// rate_limits.primary / .secondary: used_percent, window_minutes, resets_at | resets_in_seconds.
    static func limitEvents(_ limits: [String: Any], time: Date) -> [AILogLimitEvent] {
        var out: [AILogLimitEvent] = []
        for key in ["primary", "secondary"] {
            guard let w = limits[key] as? [String: Any], let used = AIJSON.double(w["used_percent"]) else { continue }
            let minutes = AIJSON.double(w["window_minutes"]) ?? (key == "primary" ? 300 : 10_080)
            let resets = AIDate.fromEpoch(w["resets_at"])
                ?? AIJSON.double(w["resets_in_seconds"]).map { time.addingTimeInterval($0) }
            let kind: AILimitWindow.Kind = minutes <= 600 ? .session : (minutes <= 20_160 ? .weekly : .monthly)
            out.append(AILogLimitEvent(provider: .codex, time: time, kind: kind, status: used >= 100 ? "rejected" : "allowed",
                                       usedPercent: used, resetsAt: resets, windowMinutes: minutes))
        }
        return out
    }

    static func host(_ originator: String?) -> String? {
        guard let o = originator?.lowercased() else { return nil }
        if o.contains("vscode") { return "VS Code" }
        if o.contains("exec") { return "codex exec" }
        if o.contains("cli") || o.contains("tui") { return "Terminal" }
        return originator
    }

    static func describeCall(_ name: String, _ arguments: String?) -> String {
        guard let arguments, let data = arguments.data(using: .utf8), let args = AIJSON.object(data) else { return name }
        if let command = args["command"] as? [String] {
            return "\(name) · " + AIFormat.oneLine(command.last ?? command.joined(separator: " "), limit: 44)
        }
        if let command = args["command"] as? String { return "\(name) · " + AIFormat.oneLine(command, limit: 44) }
        return name
    }
}
