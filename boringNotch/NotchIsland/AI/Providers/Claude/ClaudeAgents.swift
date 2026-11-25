//
//  ClaudeAgents.swift
//  NotchIsland · AI Usage · Claude
//
//  Running Claude Code sessions. Every Claude Code (terminal or IDE) keeps
//  ~/.claude/sessions/<pid>.json up to date: status "busy" (working), "idle", or
//  "waiting" with `waitingFor` ("input needed", a permission dialog, …).
//  Subagents it spawned have <session>/subagents/agent-<id>.meta.json ("finished").
//

import Foundation

enum ClaudeAgents {
    static var sessionsDirectory: URL { AIFiles.home.appendingPathComponent(".claude/sessions") }

    /// Live sessions (dead pids are skipped — Claude removes the file on a clean exit).
    static func read(db: AIUsageDB, projectRoots: [URL], now: Date = Date()) -> [AIAgent] {
        let dir = sessionsDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var agents: [AIAgent] = []
        for name in names where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let obj = AIJSON.object(data),
                  let pid = (obj["pid"] as? NSNumber)?.int32Value, isAlive(pid) else { continue }
            let session = obj["sessionId"] as? String
            let cwd = obj["cwd"] as? String ?? ""
            let raw = obj["status"] as? String ?? "idle"
            let status: AIAgentStatus = raw == "busy" ? .working : (raw == "waiting" ? .needsYou : .idle)
            let started = AIDate.fromEpoch(obj["startedAt"]) ?? now
            let since = AIDate.fromEpoch(obj["statusUpdatedAt"]) ?? AIDate.fromEpoch(obj["updatedAt"]) ?? started
            let project = AIFormat.project(fromPath: cwd)
            let title = session.flatMap { db.titles[$0] }
                ?? session.flatMap { db.sessions[$0]?.title }
                ?? project
            var agent = AIAgent(id: "claude.\(pid)", provider: .claude, pid: pid, sessionID: session, title: title,
                                project: project, cwd: cwd, host: ClaudeCodeIngestor.host(obj["entrypoint"] as? String),
                                status: status, waitingFor: (obj["waitingFor"] as? String).map(prettyWaitingFor),
                                startedAt: started, statusSince: since)
            if let session {
                agent.lastActivity = db.activity[session]
                agent.subagents = subagents(session: session, roots: projectRoots, now: now)
            }
            agents.append(agent)
        }
        return agents.sorted { lhs, rhs in
            if lhs.status != rhs.status { return rank(lhs.status) < rank(rhs.status) }
            return lhs.statusSince > rhs.statusSince
        }
    }

    static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private static func rank(_ s: AIAgentStatus) -> Int {
        switch s { case .needsYou: return 0; case .working: return 1; case .finished: return 2; case .idle: return 3 }
    }

    private static func prettyWaitingFor(_ raw: String) -> String {
        let r = raw.lowercased()
        if r.contains("permission") || r.contains("approv") { return "permission" }
        if r.contains("input") { return "your answer" }
        if r.contains("dialog") { return "a dialog" }
        return raw
    }

    /// Subagents still running for a session (meta.json "finished" == false, written in the last 15 min).
    private static func subagents(session: String, roots: [URL], now: Date) -> [AISubagent] {
        let fm = FileManager.default
        for root in roots {
            guard let projects = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            for project in projects {
                let dir = root.appendingPathComponent(project).appendingPathComponent(session).appendingPathComponent("subagents")
                guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
                var out: [AISubagent] = []
                for file in files where file.hasSuffix(".meta.json") {
                    let url = dir.appendingPathComponent(file)
                    guard let data = try? Data(contentsOf: url), let meta = AIJSON.object(data),
                          (meta["finished"] as? Bool) != true else { continue }
                    let log = url.deletingPathExtension().deletingPathExtension().appendingPathExtension("jsonl")
                    let touched = AIFileReader.stat(log.path)?.modified ?? AIFileReader.stat(url.path)?.modified ?? .distantPast
                    guard now.timeIntervalSince(touched) < 900 else { continue }
                    out.append(AISubagent(id: file, type: meta["agentType"] as? String ?? "agent",
                                          detail: AIFormat.oneLine(meta["description"] as? String ?? "", limit: 60),
                                          model: meta["model"] as? String, running: true))
                }
                return out
            }
        }
        return []
    }
}
