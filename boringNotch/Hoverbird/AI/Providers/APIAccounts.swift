//
//  APIAccounts.swift
//  Hoverbird · AI Usage
//
//  Providers you use through an API key (Settings › AI Usage › API accounts). The key is
//  kept in Hoverbird's Keychain item and only ever sent to that provider:
//   • OpenRouter — /api/v1/credits (balance) and /api/v1/key (spend today / week / month, key limit)
//   • OpenAI API — an Admin key (sk-admin-…): /v1/organization/costs and /usage/completions
//   • DeepSeek   — /user/balance
//

import Foundation

enum AIAPIAccounts {
    static let providers: [AIProvider] = [.openRouter, .openAI, .deepSeek]

    static func keyHint(_ provider: AIProvider) -> String {
        switch provider {
        case .openRouter: return "sk-or-…"
        case .openAI: return "Admin key (sk-admin-…)"
        case .deepSeek: return "sk-…"
        default: return ""
        }
    }

    /// One card per API account that has a key.
    static func fetchAll() async -> [AIProviderUsage] {
        var out: [AIProviderUsage] = []
        for provider in providers {
            let key = await Task.detached(priority: .utility) { AIKeychain.apiKey(for: provider) }.value
            guard let key else { continue }
            switch provider {
            case .openRouter: out.append(await openRouter(key))
            case .openAI: out.append(await openAI(key))
            case .deepSeek: out.append(await deepSeek(key))
            default: break
            }
        }
        return out
    }

    private static func note(_ provider: AIProvider, _ status: Int, _ error: String?) -> String {
        switch status {
        case 401, 403: return "The API key was rejected."
        case 0: return error ?? "Offline"
        default: return "\(provider.name) answered \(status)."
        }
    }

    // MARK: OpenRouter

    static func openRouter(_ key: String) async -> AIProviderUsage {
        var u = AIProviderUsage(provider: .openRouter)
        u.detected = true
        let headers = ["Authorization": "Bearer \(key)"]
        let credits = await AILiveLimits.get(URL(string: "https://openrouter.ai/api/v1/credits")!, headers: headers)
        let info = await AILiveLimits.get(URL(string: "https://openrouter.ai/api/v1/key")!, headers: headers)
        if let d = credits.json?["data"] as? [String: Any],
           let total = AIJSON.double(d["total_credits"]), let used = AIJSON.double(d["total_usage"]) {
            u.limits.append(AILiveLimits.window(.openRouter, kind: .balance, label: "Credits",
                                                used: total > 0 ? used / total * 100 : nil, resets: nil, length: nil,
                                                detail: "\(AIFormat.cost(max(0, total - used))) left of \(AIFormat.cost(total))"))
        }
        if let d = info.json?["data"] as? [String: Any] {
            if let limit = AIJSON.double(d["limit"]), limit > 0 {
                let used = AIJSON.double(d["usage"]) ?? 0
                u.limits.append(AILiveLimits.window(.openRouter, kind: .spend, label: "Key limit", used: used / limit * 100,
                                                    resets: nil, length: nil,
                                                    detail: "\(AIFormat.cost(used)) of \(AIFormat.cost(limit))"))
            }
            u.today.cost = AIJSON.double(d["usage_daily"]) ?? 0
            u.week.cost = AIJSON.double(d["usage_weekly"]) ?? 0
            u.month.cost = AIJSON.double(d["usage_monthly"]) ?? 0
        }
        if credits.status != 200 && info.status != 200 { u.limitsNote = note(.openRouter, info.status, info.error) }
        u.lastActivity = Date()
        return u
    }

    // MARK: OpenAI API (organization admin key)

    static func openAI(_ key: String) async -> AIProviderUsage {
        var u = AIProviderUsage(provider: .openAI)
        u.detected = true
        let headers = ["Authorization": "Bearer \(key)"]
        let now = Date(), calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        let query = "start_time=\(Int(start.timeIntervalSince1970))&bucket_width=1d&limit=31"
        let costs = await AILiveLimits.get(URL(string: "https://api.openai.com/v1/organization/costs?\(query)")!, headers: headers)
        let usage = await AILiveLimits.get(URL(string: "https://api.openai.com/v1/organization/usage/completions?\(query)")!, headers: headers)
        guard costs.status == 200 || usage.status == 200 else {
            u.limitsNote = note(.openAI, costs.status, costs.error)
            return u
        }
        var days: [Date: AIUsageTotals] = [:]
        for case let bucket as [String: Any] in costs.json?["data"] as? [Any] ?? [] {
            guard let day = AIDate.fromEpoch(bucket["start_time"]) else { continue }
            for case let r as [String: Any] in bucket["results"] as? [Any] ?? [] {
                days[calendar.startOfDay(for: day), default: .zero].cost += AIJSON.double((r["amount"] as? [String: Any])?["value"]) ?? 0
            }
        }
        for case let bucket as [String: Any] in usage.json?["data"] as? [Any] ?? [] {
            guard let day = AIDate.fromEpoch(bucket["start_time"]) else { continue }
            for case let r as [String: Any] in bucket["results"] as? [Any] ?? [] {
                let input = AIJSON.int(r["input_tokens"]), cached = min(input, AIJSON.int(r["input_cached_tokens"]))
                var t = AITokens()
                t.input = input - cached; t.cacheRead = cached; t.output = AIJSON.int(r["output_tokens"])
                var totals = days[calendar.startOfDay(for: day)] ?? .zero
                totals.tokens += t
                totals.requests += AIJSON.int(r["num_model_requests"])
                days[calendar.startOfDay(for: day)] = totals
            }
        }
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        for (day, totals) in days {
            if day >= today { u.today += totals }
            if day >= weekStart { u.week += totals }
            u.month += totals
        }
        u.weekStart = weekStart
        u.daily = (0..<30).compactMap { i in
            calendar.date(byAdding: .day, value: i, to: start).map { AIDayUsage(day: $0, totals: days[$0] ?? .zero) }
        }
        u.lastActivity = Date()
        return u
    }

    // MARK: DeepSeek

    static func deepSeek(_ key: String) async -> AIProviderUsage {
        var u = AIProviderUsage(provider: .deepSeek)
        u.detected = true
        let r = await AILiveLimits.get(URL(string: "https://api.deepseek.com/user/balance")!, headers: ["Authorization": "Bearer \(key)"])
        guard r.status == 200, let infos = r.json?["balance_infos"] as? [[String: Any]] else {
            u.limitsNote = note(.deepSeek, r.status, r.error)
            return u
        }
        for info in infos {
            let currency = info["currency"] as? String ?? "USD"
            let total = AIJSON.double(info["total_balance"]) ?? 0
            let text = currency == "USD" ? AIFormat.cost(total) : String(format: "%.2f %@", total, currency)
            u.limits.append(AILiveLimits.window(.deepSeek, kind: .balance, label: "Balance", used: nil, resets: nil,
                                                length: nil, detail: "\(text) left"))
        }
        u.lastActivity = Date()
        return u
    }
}
