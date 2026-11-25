//
//  AIPricing.swift
//  NotchIsland · AI Usage
//
//  "≈ $" figures: what the tokens would cost at the provider's public API prices.
//  (On a flat plan like Claude Max you don't pay this — it shows how much work was done.)
//  Claude prices are Anthropic's list prices; checked against Claude Code's own cost
//  records (an Opus 5.5 session priced at $17.119 by both).
//  Unknown models get no price instead of a guess.
//
//  Override or add models without rebuilding:
//  ~/Library/Application Support/NotchIsland/ai-pricing.json
//    { "my-model": { "input": 1.0, "output": 4.0, "cacheRead": 0.1 } }   ($ per 1M tokens)
//

import Foundation

struct AIModelPrice: Codable, Sendable {
    var input: Double
    var output: Double
    var cacheRead: Double?
    var cacheWrite5m: Double?
    var cacheWrite1h: Double?
    /// Prompt size above which the long-context rates apply.
    var longContextAbove: Int?
    var longInput: Double?
    var longOutput: Double?
}

enum AIPricing {
    /// Matched by prefix after normalising the model id; the longest matching prefix wins.
    private static let builtIn: [String: AIModelPrice] = [
        // Anthropic
        "claude-fable-5-2": .init(input: 8, output: 40, cacheRead: 0.20),
        "claude-mythos-5-2": .init(input: 8, output: 40, cacheRead: 0.20),
        "claude-fable-5": .init(input: 10, output: 50),
        "claude-mythos-5": .init(input: 10, output: 50),
        "claude-opus-5-5": .init(input: 4, output: 20, cacheRead: 0.20),
        "claude-opus-5": .init(input: 5, output: 25),
        "claude-opus-4-8": .init(input: 5, output: 25),
        "claude-opus-4-7": .init(input: 5, output: 25),
        "claude-opus-4-6": .init(input: 5, output: 25),
        "claude-opus-4-5": .init(input: 5, output: 25),
        "claude-opus-4": .init(input: 15, output: 75),        // Opus 4 / 4.1
        "claude-sonnet-5-5": .init(input: 2, output: 10, cacheRead: 0.10),
        "claude-sonnet-5": .init(input: 2, output: 10),
        "claude-sonnet-4": .init(input: 3, output: 15),       // 4 / 4.5 / 4.6
        "claude-3-7-sonnet": .init(input: 3, output: 15),
        "claude-3-5-sonnet": .init(input: 3, output: 15),
        "claude-haiku-5-5": .init(input: 0.10, output: 0.50, longContextAbove: 100_000, longInput: 0.50, longOutput: 2.50),
        "claude-haiku-4-5": .init(input: 1, output: 5),
        "claude-3-5-haiku": .init(input: 0.80, output: 4),
        // OpenAI (input includes cached tokens upstream; the Codex reader splits them out)
        "gpt-5-codex": .init(input: 1.25, output: 10, cacheRead: 0.125),
        "gpt-5-mini": .init(input: 0.25, output: 2, cacheRead: 0.025),
        "gpt-5-nano": .init(input: 0.05, output: 0.40, cacheRead: 0.005),
        "gpt-5": .init(input: 1.25, output: 10, cacheRead: 0.125),
        "gpt-4.1": .init(input: 2, output: 8, cacheRead: 0.50),
        "o3": .init(input: 2, output: 8, cacheRead: 0.50),
        "o4-mini": .init(input: 1.10, output: 4.40, cacheRead: 0.275),
        // Google
        "gemini-2.5-pro": .init(input: 1.25, output: 10, cacheRead: 0.31, longContextAbove: 200_000, longInput: 2.50, longOutput: 15),
        "gemini-2.5-flash-lite": .init(input: 0.10, output: 0.40, cacheRead: 0.025),
        "gemini-2.5-flash": .init(input: 0.30, output: 2.50, cacheRead: 0.075),
        // xAI
        "grok-code-fast": .init(input: 0.20, output: 1.50, cacheRead: 0.02),
        "grok-4-fast": .init(input: 0.20, output: 0.50, cacheRead: 0.05),
        "grok-4": .init(input: 3, output: 15, cacheRead: 0.75),
        "grok-3-mini": .init(input: 0.30, output: 0.50, cacheRead: 0.075),
        "grok-3": .init(input: 3, output: 15, cacheRead: 0.75),
    ]

    /// Web search is billed per search ($10 per 1,000) on top of tokens.
    static let webSearchPrice = 0.01

    private static var overrides: [String: AIModelPrice] = [:]
    private static var overridesStamp: Date?
    private static let lock = NSLock()

    private static var overridesURL: URL { IslandPaths.appSupport.appendingPathComponent("ai-pricing.json") }

    /// Re-reads ai-pricing.json when it changed (cheap stat; called before each rebuild).
    static func reloadOverridesIfNeeded() {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: overridesURL.path))?[.modificationDate] as? Date
        lock.lock(); defer { lock.unlock() }
        guard stamp != overridesStamp else { return }
        overridesStamp = stamp
        guard stamp != nil, let data = try? Data(contentsOf: overridesURL), let obj = AIJSON.object(data) else {
            overrides = [:]
            return
        }
        // Entry by entry, so a comment or one bad entry doesn't drop the rest.
        var parsed: [String: AIModelPrice] = [:]
        for (model, value) in obj {
            guard let dict = value as? [String: Any], let entry = try? JSONSerialization.data(withJSONObject: dict),
                  let price = try? JSONDecoder().decode(AIModelPrice.self, from: entry) else { continue }
            parsed[normalize(model)] = price
        }
        overrides = parsed
    }

    /// "us.anthropic.claude-opus-4-5-20251101-v1:0" → "claude-opus-4-5-20251101-v1:0" (prefix matching handles the rest).
    static func normalize(_ model: String) -> String {
        var m = model.lowercased()
        for prefix in ["us.", "eu.", "apac.", "global."] where m.hasPrefix(prefix) { m.removeFirst(prefix.count) }
        for vendor in ["anthropic.", "anthropic/", "openai/", "google/", "x-ai/", "xai/", "models/"] where m.hasPrefix(vendor) {
            m.removeFirst(vendor.count)
        }
        return m.replacingOccurrences(of: ".", with: "-", options: [], range: nil)
            .replacingOccurrences(of: "gpt-4-1", with: "gpt-4.1")
    }

    static func price(for model: String) -> AIModelPrice? {
        let m = normalize(model)
        lock.lock(); let custom = overrides; lock.unlock()
        if let exact = custom[m] { return exact }
        let pick: ([String: AIModelPrice]) -> AIModelPrice? = { table in
            table.filter { m.hasPrefix(normalize($0.key)) }.max { $0.key.count < $1.key.count }?.value
        }
        return pick(custom) ?? pick(builtIn)
    }

    /// API-price estimate for one request; nil when the model's price is unknown.
    static func cost(model: String, tokens t: AITokens, webSearches: Int = 0) -> Double? {
        guard let p = price(for: model) else { return nil }
        var input = p.input, output = p.output
        if let above = p.longContextAbove, t.prompt > above {
            input = p.longInput ?? input
            output = p.longOutput ?? output
        }
        let scale = input / p.input // long-context rates scale the cache rates too
        let cacheRead = (p.cacheRead ?? p.input * 0.1) * scale
        let write5m = (p.cacheWrite5m ?? p.input * 1.25) * scale
        let write1h = (p.cacheWrite1h ?? p.input * 2) * scale
        let dollars = Double(t.input) * input + Double(t.output) * output + Double(t.cacheRead) * cacheRead
            + Double(t.cacheWrite5m) * write5m + Double(t.cacheWrite1h) * write1h
        return dollars / 1_000_000 + Double(webSearches) * webSearchPrice
    }
}
