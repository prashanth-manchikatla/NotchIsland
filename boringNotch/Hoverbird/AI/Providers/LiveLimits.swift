//
//  LiveLimits.swift
//  Hoverbird · AI Usage
//
//  The real limit numbers, read the same way each CLI reads them. Opt-in per provider
//  (Settings › AI Usage), because it uses that CLI's sign-in:
//   • Claude — Claude Code's sign-in (Keychain "Claude Code-credentials", or
//     ~/.claude/.credentials.json) → GET api.anthropic.com/api/oauth/usage, the numbers
//     `/usage` shows: 5-hour, week, week per model, extra usage.
//   • Codex  — ~/.codex/auth.json → chatgpt.com/backend-api/wham/usage (ChatGPT plan).
//   • Grok   — ~/.grok/auth.json → Grok CLI's billing endpoint (SuperGrok credits).
//  Tokens are only sent to their own provider, are never written anywhere, and are never
//  refreshed here (refreshing would rotate the CLI's token and sign it out). If one has
//  expired, the note says so; the CLI refreshes it the next time you use it.
//

import Foundation

enum AILiveLimits {
    static func fetch(_ provider: AIProvider) async -> AILiveState? {
        switch provider {
        case .claude: return await ClaudeLimits.fetch()
        case .codex: return await CodexLimits.fetch()
        case .grok: return await GrokLimits.fetch()
        default: return nil
        }
    }

    static func get(_ url: URL, headers: [String: String]) async -> (status: Int, json: [String: Any]?, error: String?) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Hoverbird/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (status, AIJSON.object(data), nil)
        } catch {
            return (0, nil, error.localizedDescription)
        }
    }

    /// The shape of a response (keys and numbers only, no strings) → ai-debug.txt, to adapt to API changes.
    static func logShape(_ provider: AIProvider, status: Int, json: [String: Any]?) {
        func shape(_ v: Any, depth: Int) -> Any {
            if depth > 3 { return "…" }
            if let d = v as? [String: Any] { return d.mapValues { shape($0, depth: depth + 1) } }
            if let a = v as? [Any] { return a.prefix(3).map { shape($0, depth: depth + 1) } }
            if v is NSNumber { return v }
            if v is NSNull { return "null" }
            return "string"
        }
        let body = json.map { shape($0, depth: 0) } ?? "no JSON"
        let text = "\(Date()) \(provider.name) HTTP \(status): \(body)\n"
        let url = IslandPaths.appSupport.appendingPathComponent("ai-debug.txt")
        if let h = try? FileHandle(forWritingTo: url) {
            if (try? h.seekToEnd()) ?? 0 > 200_000 { try? h.truncate(atOffset: 0) }
            h.write(Data(text.utf8)); try? h.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }

    static func window(_ provider: AIProvider, kind: AILimitWindow.Kind, label: String, used: Double?,
                       resets: Date?, length: TimeInterval?, detail: String? = nil) -> AILimitWindow {
        AILimitWindow(provider: provider, kind: kind, label: label, usedPercent: used.map { min(100, max(0, $0)) },
                      resetsAt: resets, windowLength: length, detail: detail, isEstimate: false, asOf: Date())
    }
}

// MARK: - Claude

enum ClaudeLimits {
    private struct Credentials { let token: String; let expires: Date?; let plan: String? }
    private static let lock = NSLock()
    private static var cached: Credentials?

    /// Blocking: call off the main thread. Read once per launch (and again when it expires).
    private static func readCredentials() -> (Credentials?, String?) {
        var data: Data?
        var problem: String?
        switch AIKeychain.readWithSecurityTool(service: "Claude Code-credentials") {
        case .found(let d): data = d
        case .notFound: break
        case .denied, .failed: problem = "Couldn't read Claude Code's sign-in from the Keychain."
        }
        if data == nil {
            for name in [".claude/.credentials.json", ".claude/credentials.json"] {
                if let d = FileManager.default.contents(atPath: AIFiles.home.appendingPathComponent(name).path) { data = d; break }
            }
        }
        guard let data, let obj = AIJSON.object(data),
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            return (nil, problem ?? "Claude Code isn't signed in on this Mac.")
        }
        // The sign-in keeps the plan from login time (Pro after an upgrade to Max): prefer the
        // account profile Claude Code keeps current.
        let profile = FileManager.default.contents(atPath: AIFiles.home.appendingPathComponent(".claude.json").path)
        let plan = ClaudePlan.fromProfile(profile)
            ?? ClaudePlan.name(type: oauth["subscriptionType"] as? String, tier: oauth["rateLimitTier"] as? String)
        return (Credentials(token: token, expires: AIDate.fromEpoch(oauth["expiresAt"]), plan: plan), nil)
    }

    private static func credentials(reload: Bool) async -> (Credentials?, String?) {
        let current = lock.withLock { cached }
        if !reload, let current, (current.expires ?? .distantFuture) > Date().addingTimeInterval(60) { return (current, nil) }
        let result = await Task.detached(priority: .utility) { readCredentials() }.value
        lock.withLock { cached = result.0 }
        return result
    }

    static func fetch() async -> AILiveState {
        var (creds, problem) = await credentials(reload: false)
        if let c = creds, let exp = c.expires, exp <= Date() { (creds, problem) = await credentials(reload: true) }
        guard let c = creds else { return AILiveState(note: problem, fetchedAt: Date()) }
        if let exp = c.expires, exp <= Date() {
            return AILiveState(plan: c.plan, note: "Claude Code's sign-in has expired — it renews the next time you use Claude Code.", fetchedAt: Date())
        }
        let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        var r = await AILiveLimits.get(url, headers: ["Authorization": "Bearer \(c.token)", "anthropic-beta": "oauth-2025-04-20"])
        if r.status == 401 { // Claude Code may have renewed it since we read it
            let (fresh, _) = await credentials(reload: true)
            if let fresh, fresh.token != c.token {
                r = await AILiveLimits.get(url, headers: ["Authorization": "Bearer \(fresh.token)", "anthropic-beta": "oauth-2025-04-20"])
            }
        }
        AILiveLimits.logShape(.claude, status: r.status, json: r.json)
        guard r.status == 200, let json = r.json else {
            let note: String
            switch r.status {
            case 401: note = "Claude Code's sign-in has expired — it renews the next time you use Claude Code."
            case 403: note = "This sign-in can't read usage. Sign in again in Claude Code (/login)."
            case 429: note = "Anthropic asked to slow down — trying again in a few minutes."
            case 0: note = r.error ?? "Offline"
            default: note = "Anthropic answered \(r.status)."
            }
            return AILiveState(plan: c.plan, note: note, fetchedAt: Date())
        }
        return AILiveState(limits: parse(json), plan: c.plan, note: nil, fetchedAt: Date())
    }

    /// {five_hour: {utilization, resets_at}, seven_day: {…}, seven_day_opus: {…}, extra_usage: {…}}
    static func parse(_ json: [String: Any]) -> [AILimitWindow] {
        var out: [AILimitWindow] = []
        let named: [(String, AILimitWindow.Kind, String, TimeInterval)] = [
            ("five_hour", .session, "5-hour", 5 * 3_600),
            ("seven_day", .weekly, "Week", 7 * 86_400),
            ("seven_day_opus", .weeklyModel, "Week · Opus", 7 * 86_400),
            ("seven_day_sonnet", .weeklyModel, "Week · Sonnet", 7 * 86_400),
        ]
        for (key, kind, label, length) in named {
            guard let w = json[key] as? [String: Any], let used = AIJSON.double(w["utilization"]) else { continue }
            out.append(AILiveLimits.window(.claude, kind: kind, label: label, used: used,
                                           resets: AIDate.parse(w["resets_at"] as? String), length: length))
        }
        // Other weekly windows Anthropic adds (seven_day_<name>), shown by name.
        for (key, value) in json where key.hasPrefix("seven_day_") && !named.contains(where: { $0.0 == key }) && key != "seven_day_oauth_apps" {
            guard let w = value as? [String: Any], let used = AIJSON.double(w["utilization"]), used > 0 else { continue }
            let name = key.dropFirst("seven_day_".count).replacingOccurrences(of: "_", with: " ").capitalized
            out.append(AILiveLimits.window(.claude, kind: .weeklyModel, label: "Week · \(name)", used: used,
                                           resets: AIDate.parse(w["resets_at"] as? String), length: 7 * 86_400))
        }
        if let extra = json["extra_usage"] as? [String: Any], (extra["is_enabled"] as? Bool) == true {
            let used = AIJSON.double(extra["used_credits"]), limit = AIJSON.double(extra["monthly_limit"])
            let detail = used.map { u in limit.map { "\(AIFormat.cost(u / 100)) of \(AIFormat.cost($0 / 100))" } ?? AIFormat.cost(u / 100) }
            out.append(AILiveLimits.window(.claude, kind: .spend, label: "Extra usage", used: AIJSON.double(extra["utilization"]),
                                           resets: nil, length: nil, detail: detail))
        }
        return out
    }
}

// MARK: - Codex (ChatGPT plan)

enum CodexLimits {
    static func fetch() async -> AILiveState {
        let path = AIFiles.home.appendingPathComponent(".codex/auth.json").path
        guard let data = FileManager.default.contents(atPath: path), let obj = AIJSON.object(data),
              let tokens = obj["tokens"] as? [String: Any], let token = tokens["access_token"] as? String else {
            return AILiveState(note: "Codex isn't signed in with ChatGPT on this Mac.", fetchedAt: Date())
        }
        var headers = ["Authorization": "Bearer \(token)"]
        if let account = tokens["account_id"] as? String { headers["ChatGPT-Account-Id"] = account }
        let r = await AILiveLimits.get(URL(string: "https://chatgpt.com/backend-api/wham/usage")!, headers: headers)
        AILiveLimits.logShape(.codex, status: r.status, json: r.json)
        guard r.status == 200, let json = r.json else {
            let note = r.status == 401 ? "Codex's sign-in has expired — it renews the next time you use Codex." : (r.error ?? "OpenAI answered \(r.status).")
            return AILiveState(note: note, fetchedAt: Date())
        }
        var out: [AILimitWindow] = []
        let limits = json["rate_limit"] as? [String: Any] ?? [:]
        for key in ["primary_window", "secondary_window"] {
            guard let w = limits[key] as? [String: Any], let used = AIJSON.double(w["used_percent"]) else { continue }
            let length = AIJSON.double(w["limit_window_seconds"]) ?? (key == "primary_window" ? 18_000 : 604_800)
            let resets = AIDate.fromEpoch(w["reset_at"]) ?? AIJSON.double(w["reset_after_seconds"]).map { Date().addingTimeInterval($0) }
            let kind: AILimitWindow.Kind = length <= 36_000 ? .session : (length <= 1_209_600 ? .weekly : .monthly)
            out.append(AILiveLimits.window(.codex, kind: kind, label: kind == .session ? "5-hour" : (kind == .weekly ? "Week" : "Month"),
                                           used: used, resets: resets, length: length))
        }
        return AILiveState(limits: out, plan: (json["plan_type"] as? String)?.capitalized, note: nil, fetchedAt: Date())
    }
}

// MARK: - Grok (SuperGrok via Grok CLI)

enum GrokLimits {
    static func fetch() async -> AILiveState {
        let path = AIFiles.home.appendingPathComponent(".grok/auth.json").path
        guard let data = FileManager.default.contents(atPath: path), let obj = AIJSON.object(data) else {
            return AILiveState(note: "Grok CLI isn't signed in on this Mac.", fetchedAt: Date())
        }
        let entries = obj.values.compactMap { $0 as? [String: Any] }
        guard let entry = obj.first(where: { $0.key.hasPrefix("https://auth.x.ai") })?.value as? [String: Any] ?? entries.first,
              let token = entry["key"] as? String else {
            return AILiveState(note: "Grok CLI isn't signed in on this Mac.", fetchedAt: Date())
        }
        let r = await AILiveLimits.get(URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!,
                                       headers: ["Authorization": "Bearer \(token)", "x-xai-token-auth": "xai-grok-cli"])
        AILiveLimits.logShape(.grok, status: r.status, json: r.json)
        guard r.status == 200, let json = r.json else {
            let note = r.status == 401 ? "Grok CLI's sign-in has expired — run grok once to renew it." : (r.error ?? "xAI answered \(r.status).")
            return AILiveState(note: note, fetchedAt: Date())
        }
        let config = json["config"] as? [String: Any] ?? json
        var used = AIJSON.double(config["creditUsagePercent"])
        if used == nil, let u = AIJSON.double((config["onDemandUsed"] as? [String: Any])?["val"]),
           let cap = AIJSON.double((config["onDemandCap"] as? [String: Any])?["val"]), cap > 0 {
            used = u / cap * 100
        }
        let resets = AIDate.fromEpoch((config["currentPeriod"] as? [String: Any])?["end"]) ?? AIDate.fromEpoch(config["billingPeriodEnd"])
        guard let used else { return AILiveState(note: "Grok didn't report credits.", fetchedAt: Date()) }
        return AILiveState(limits: [AILiveLimits.window(.grok, kind: .credits, label: "Credits", used: used, resets: resets, length: nil)],
                           plan: nil, note: nil, fetchedAt: Date())
    }
}
