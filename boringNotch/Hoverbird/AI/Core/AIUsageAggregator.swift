//
//  AIUsageAggregator.swift
//  Hoverbird · AI Usage
//
//  Turns the raw records into what the island shows: today / current window / week /
//  month totals, per model and per project, 30 days of history, tasks (with the
//  subagent calls they caused), sessions (with active time) and the request log.
//

import Foundation

/// Limits read live from a provider (set by AIUsageStore).
struct AILiveState: Sendable {
    var limits: [AILimitWindow] = []
    var plan: String?
    var note: String?
    var fetchedAt: Date?
}

enum AIUsageAggregator {
    static let sessionWindow: TimeInterval = 5 * 3_600
    static let week: TimeInterval = 7 * 86_400
    /// Gaps longer than this between calls don't count as active time.
    static let idleGap: TimeInterval = 5 * 60

    static func build(db: AIUsageDB, detected: Set<AIProvider>, live: [AIProvider: AILiveState],
                      agents rawAgents: [AIAgent], extra: [AIProviderUsage], now: Date = Date()) -> AIUsageSnapshot {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let firstDay = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        let dayStarts: [Date] = (0..<30).compactMap { calendar.date(byAdding: .day, value: $0, to: firstDay) }

        // Index the requests once.
        var byProvider: [AIProvider: [AIRequestRecord]] = [:]
        var bySession: [String: [AIRequestRecord]] = [:]
        for r in db.requests.values {
            byProvider[r.provider, default: []].append(r)
            bySession[r.sessionID, default: []].append(r)
        }

        // Tasks: direct calls + subagent calls matched to the task running at that moment.
        var tasksBySession: [String: [AITaskRecord]] = [:]
        for t in db.tasks.values { tasksBySession[t.sessionID, default: []].append(t) }
        var builtTasks: [AITaskRecord] = []
        var builtSessions: [AISessionRecord] = []
        for (sessionID, var session) in db.sessions {
            let calls = (bySession[sessionID] ?? []).sorted { $0.time < $1.time }
            var tasks = (tasksBySession[sessionID] ?? []).sorted { $0.start < $1.start }
            var index: [String: Int] = [:]
            for (i, t) in tasks.enumerated() { index[t.id] = i }
            var models: [String: Int] = [:]
            for call in calls {
                session.totals.add(call)
                models[call.model, default: 0] += 1
                var slot = call.taskID.flatMap { index[$0] }
                if slot == nil, !tasks.isEmpty, let last = tasks.lastIndex(where: { $0.start <= call.time }) { slot = last }
                guard let i = slot else { continue }
                tasks[i].totals.add(call)
                if call.time > tasks[i].end { tasks[i].end = call.time }
                if !tasks[i].models.contains(call.model) { tasks[i].models.append(call.model) }
                if call.isSubagent { tasks[i].subagentCalls += 1 }
            }
            session.activeSeconds = activeTime(calls.map(\.time) + tasks.map(\.start))
            session.taskCount = tasks.count
            session.models = models.sorted { $0.value > $1.value }.map(\.key)
            if let title = db.titles[sessionID] { session.title = title }
            if session.title == nil { session.title = tasks.first?.prompt }
            session.reportedCost = db.reportedCosts[sessionID] ?? session.reportedCost
            builtTasks += tasks
            builtSessions.append(session)
        }
        let sessionsByID = Dictionary(uniqueKeysWithValues: builtSessions.map { ($0.id, $0) })
        let latestTaskBySession = Dictionary(grouping: builtTasks, by: \.sessionID).compactMapValues { $0.max { $0.start < $1.start } }

        // Providers.
        var providers: [AIProviderUsage] = []
        for provider in AIProvider.allCases where provider.isLocal {
            let calls = (byProvider[provider] ?? []).sorted { $0.time < $1.time }
            var usage = AIProviderUsage(provider: provider)
            usage.detected = detected.contains(provider) || !calls.isEmpty
            guard usage.detected else { providers.append(usage); continue }
            let state = live[provider]
            usage.plan = state?.plan
            usage.limits = limits(for: provider, live: state, db: db, calls: calls, now: now)
            usage.limitsNote = state?.note

            let session = usage.limits.first { $0.kind == .session }
            usage.windowStart = session?.windowStart
            usage.windowIsEstimate = session?.isEstimate ?? true
            let weekly = usage.limits.first { $0.kind == .weekly }
            usage.weekStart = weekly.flatMap { $0.isEstimate ? nil : $0.windowStart } ?? now.addingTimeInterval(-week)
            let monthStart = now.addingTimeInterval(-30 * 86_400)

            var daily = Array(repeating: AIUsageTotals.zero, count: dayStarts.count)
            var models: [String: AIUsageTotals] = [:]
            var projects: [String: (AIUsageTotals, Set<String>)] = [:]
            for call in calls {
                if call.time >= today {
                    usage.today.add(call)
                    let hour = min(23, max(0, Int(call.time.timeIntervalSince(today) / 3_600)))
                    usage.hourlyToday[hour] += call.tokens.total
                }
                if let start = usage.windowStart, call.time >= start { usage.window.add(call) }
                if let start = usage.weekStart, call.time >= start {
                    usage.week.add(call)
                    models[call.model, default: .zero].add(call)
                    let project = sessionsByID[call.sessionID]?.project ?? "—"
                    var entry = projects[project] ?? (.zero, [])
                    entry.0.add(call); entry.1.insert(call.sessionID)
                    projects[project] = entry
                }
                if call.time >= monthStart { usage.month.add(call) }
                if call.time >= firstDay, let slot = dayIndex(call.time, dayStarts) { daily[slot].add(call) }
            }
            usage.daily = zip(dayStarts, daily).map { AIDayUsage(day: $0, totals: $1) }
            usage.byModel = models.map { AIModelUsage(model: $0.key, totals: $0.value) }.sorted { $0.totals.tokens.total > $1.totals.tokens.total }
            usage.byProject = projects.map { AIProjectUsage(project: $0.key, totals: $0.value.0, sessions: $0.value.1.count) }
                .sorted { $0.totals.tokens.total > $1.totals.tokens.total }
            usage.lastActivity = calls.last?.time
            providers.append(usage)
        }
        providers += extra

        // Agents: add this session's totals and current prompt; plus other CLIs that wrote logs just now.
        var agents = rawAgents.map { agent -> AIAgent in
            var a = agent
            if let id = a.sessionID {
                if let s = sessionsByID[id] { a.sessionTokens = s.totals.tokens.total; a.sessionCost = s.totals.cost }
                a.currentPrompt = latestTaskBySession[id]?.prompt
            }
            return a
        }
        let claudeSessions = Set(agents.compactMap(\.sessionID))
        for s in builtSessions where s.provider != .claude && !claudeSessions.contains(s.id) && now.timeIntervalSince(s.end) < 120 {
            var a = AIAgent(id: "\(s.provider.rawValue).\(s.id)", provider: s.provider, pid: nil, sessionID: s.id,
                            title: s.displayTitle, project: s.project, cwd: s.cwd, host: s.host, status: .working,
                            waitingFor: nil, startedAt: s.start, statusSince: s.start)
            a.sessionTokens = s.totals.tokens.total
            a.sessionCost = s.totals.cost
            a.currentPrompt = latestTaskBySession[s.id]?.prompt
            a.lastActivity = db.activity[s.id]
            agents.append(a)
        }

        var snapshot = AIUsageSnapshot()
        snapshot.providers = providers
        snapshot.agents = agents
        snapshot.tasks = Array(builtTasks.sorted { $0.start > $1.start }.prefix(300))
        snapshot.sessions = Array(builtSessions.sorted { $0.end > $1.end }.prefix(150))
        snapshot.log = Array(db.requests.values.sorted { $0.time > $1.time }.prefix(500))
        snapshot.generated = now
        return snapshot
    }

    // MARK: Limits

    /// Live limits when we have them; otherwise what the provider wrote in its logs; otherwise an
    /// estimated 5-hour window from your activity (like ccusage's blocks).
    static func limits(for provider: AIProvider, live: AILiveState?, db: AIUsageDB,
                       calls: [AIRequestRecord], now: Date) -> [AILimitWindow] {
        if let live, !live.limits.isEmpty {
            // Live windows stay valid until they reset, then we wait for the next fetch.
            let fresh = live.limits.filter { ($0.resetsAt ?? .distantFuture) > now }
            if !fresh.isEmpty { return fresh }
        }
        var out: [AILimitWindow] = []
        for kind in [AILimitWindow.Kind.session, .weekly, .weeklyModel] {
            guard let e = db.limitEvents["\(provider.rawValue).\(kind.rawValue)"],
                  let resets = e.resetsAt, resets > now else { continue }
            let length = (e.windowMinutes ?? (kind == .session ? 300 : 10_080)) * 60
            let used = e.usedPercent ?? (e.status == "rejected" ? 100 : nil)
            out.append(AILimitWindow(provider: provider, kind: kind,
                                     label: kind == .session ? "5-hour" : (kind == .weekly ? "Week" : "Week · model"),
                                     usedPercent: used, resetsAt: resets, windowLength: length,
                                     detail: e.status == "rejected" ? "Limit reached" : nil, isEstimate: false, asOf: e.time))
        }
        if !out.contains(where: { $0.kind == .session }), provider == .claude || provider == .codex,
           let start = estimatedWindowStart(calls.map(\.time), now: now) {
            out.insert(AILimitWindow(provider: provider, kind: .session, label: "5-hour", usedPercent: nil,
                                     resetsAt: start.addingTimeInterval(sessionWindow), windowLength: sessionWindow,
                                     detail: nil, isEstimate: true, asOf: nil), at: 0)
        }
        return out
    }

    /// The 5-hour window you're in, estimated: it opens at the first call after the previous window
    /// ended (Claude's real resets land on 10-minute marks, e.g. 15:20 UTC). Nil when no window is open.
    static func estimatedWindowStart(_ times: [Date], now: Date) -> Date? {
        var start: Date?
        for t in times {
            if let s = start, t < s.addingTimeInterval(sessionWindow) { continue }
            start = Date(timeIntervalSince1970: (t.timeIntervalSince1970 / 600).rounded(.down) * 600)
        }
        guard let s = start, now < s.addingTimeInterval(sessionWindow) else { return nil }
        return s
    }

    // MARK: Helpers

    static func activeTime(_ times: [Date]) -> TimeInterval {
        let sorted = times.sorted()
        guard sorted.count > 1 else { return sorted.isEmpty ? 0 : 30 }
        var total: TimeInterval = 30 // the first call took some time too
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            let gap = b.timeIntervalSince(a)
            total += gap <= idleGap ? gap : 30
        }
        return total
    }

    private static func dayIndex(_ time: Date, _ starts: [Date]) -> Int? {
        var lo = 0, hi = starts.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= time { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }
}
