//
//  AIModels.swift
//  Hoverbird · AI Usage
//
//  The shared vocabulary of the AI Usage feature. Every provider (Claude Code,
//  Codex, Gemini CLI, Grok CLI, API accounts) is turned into these types, so the
//  island, the window and the alerts never care where a number came from.
//

import Foundation
import SwiftUI

// MARK: - Providers

enum AIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude      // Claude Code (terminal, VS Code, desktop) + Claude plan limits
    case codex       // OpenAI Codex CLI + ChatGPT plan limits
    case gemini      // Gemini CLI
    case grok        // Grok CLI + SuperGrok credits
    case openRouter  // API key
    case openAI      // OpenAI API (admin key)
    case deepSeek    // API key

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .grok: return "Grok"
        case .openRouter: return "OpenRouter"
        case .openAI: return "OpenAI API"
        case .deepSeek: return "DeepSeek"
        }
    }

    /// Where the numbers come from, in plain words (settings + empty states).
    var sourceDescription: String {
        switch self {
        case .claude: return "Claude Code logs (terminal, VS Code, desktop)"
        case .codex: return "Codex CLI logs · ChatGPT plan limits"
        case .gemini: return "Gemini CLI logs"
        case .grok: return "Grok CLI logs · SuperGrok credits"
        case .openRouter: return "API key · credits and spend"
        case .openAI: return "Admin API key · spend and tokens"
        case .deepSeek: return "API key · balance"
        }
    }

    var symbol: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .gemini: return "sparkles"
        case .grok: return "bolt.horizontal.fill"
        case .openRouter: return "arrow.triangle.branch"
        case .openAI: return "circle.hexagongrid.fill"
        case .deepSeek: return "fish.fill"
        }
    }

    var tint: Color {
        switch self {
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex, .openAI: return Color(red: 0.25, green: 0.78, blue: 0.62)
        case .gemini: return Color(red: 0.36, green: 0.56, blue: 0.98)
        case .grok: return Color(white: 0.86)
        case .openRouter: return Color(red: 0.49, green: 0.50, blue: 0.98)
        case .deepSeek: return Color(red: 0.33, green: 0.47, blue: 1.0)
        }
    }

    /// Providers whose numbers come from logs on this Mac (vs. an API account).
    var isLocal: Bool { [.claude, .codex, .gemini, .grok].contains(self) }
}

// MARK: - Tokens & totals

/// Token counts in the shape every provider can be mapped to.
/// `input` is *uncached* input; `reasoning` is the thinking part of `output`;
/// `other` holds tokens whose split a provider doesn't report (e.g. Grok session totals).
struct AITokens: Equatable, Sendable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    var reasoning = 0
    var other = 0

    var cacheWrite: Int { cacheWrite5m + cacheWrite1h }
    var total: Int { input + output + cacheRead + cacheWrite + other }
    /// Everything the model read for this request (what long-context pricing keys on).
    var prompt: Int { input + cacheRead + cacheWrite }

    static func + (a: AITokens, b: AITokens) -> AITokens {
        AITokens(input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead,
                 cacheWrite5m: a.cacheWrite5m + b.cacheWrite5m, cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h,
                 reasoning: a.reasoning + b.reasoning, other: a.other + b.other)
    }
    static func += (a: inout AITokens, b: AITokens) { a = a + b }
}

struct AIUsageTotals: Equatable, Sendable {
    var tokens = AITokens()
    var cost: Double = 0
    var requests = 0
    /// Requests whose model has no known price (their cost isn't in `cost`).
    var unpriced = 0

    static let zero = AIUsageTotals()

    mutating func add(_ r: AIRequestRecord) {
        tokens += r.tokens
        requests += 1
        if let c = r.cost { cost += c } else { unpriced += 1 }
    }
    static func += (a: inout AIUsageTotals, b: AIUsageTotals) {
        a.tokens += b.tokens; a.cost += b.cost; a.requests += b.requests; a.unpriced += b.unpriced
    }
}

// MARK: - Records (built by the ingestors)

/// One model call, deduplicated (Claude writes a row per content block).
struct AIRequestRecord: Sendable {
    var provider: AIProvider
    var time: Date
    var model: String
    var tokens: AITokens
    var webSearches = 0
    var sessionID: String
    /// The prompt ("task") this call worked on. Nil for subagent calls until matched by time.
    var taskID: String?
    var isSubagent = false
    var cost: Double?
}

/// One prompt you gave an agent, and everything it caused.
struct AITaskRecord: Identifiable, Sendable {
    let id: String
    var provider: AIProvider
    var sessionID: String
    var prompt: String
    var start: Date
    var project: String
    // Filled in when a snapshot is built:
    var end: Date
    var totals = AIUsageTotals.zero
    var models: [String] = []
    var subagentCalls = 0
    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

struct AISessionRecord: Identifiable, Sendable {
    let id: String
    var provider: AIProvider
    var title: String?
    var project: String
    var cwd: String
    var branch: String?
    var host: String?
    var start: Date
    var end: Date
    /// The provider's own cost figure, when it records one (Claude Code's cost-state).
    var reportedCost: Double?
    // Filled in when a snapshot is built:
    var totals = AIUsageTotals.zero
    var activeSeconds: TimeInterval = 0
    var taskCount = 0
    var models: [String] = []

    var displayTitle: String { (title?.isEmpty == false ? title : nil) ?? project }
}

/// A limit state that a provider wrote into its own logs (Claude's quotaLimits, Codex rate_limits).
struct AILogLimitEvent: Sendable {
    var provider: AIProvider
    var time: Date
    var kind: AILimitWindow.Kind
    var status: String          // "allowed", "allowed_warning", "rejected", …
    var usedPercent: Double?
    var resetsAt: Date?
    var windowMinutes: Double?
}

/// What an agent was last doing ("Edit · ContentView.swift").
struct AIActivity: Sendable, Equatable {
    var text: String
    var time: Date
}

// MARK: - Limits

struct AILimitWindow: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case session, weekly, weeklyModel, monthly, credits, spend, balance }

    var provider: AIProvider
    var kind: Kind
    var label: String              // "5-hour", "Week", "Week · Opus", "Credits"
    var usedPercent: Double?       // 0…100
    var resetsAt: Date?
    var windowLength: TimeInterval?
    var detail: String?            // "$12.40 of $50", "$3.20 left"
    /// True when this was estimated from logs rather than read from the provider.
    var isEstimate = false
    /// When the provider reported it (live fetch or log line).
    var asOf: Date?

    var id: String { "\(provider.rawValue).\(kind.rawValue).\(label)" }
    var windowStart: Date? {
        guard let resetsAt, let windowLength else { return nil }
        return resetsAt.addingTimeInterval(-windowLength)
    }
    /// How far through the window we are (0…1), for the pace marker.
    func elapsedFraction(now: Date = Date()) -> Double? {
        guard let start = windowStart, let windowLength, windowLength > 0 else { return nil }
        return min(1, max(0, now.timeIntervalSince(start) / windowLength))
    }
    /// At the current pace, when the window would run out (nil = it won't before it resets).
    func projectedRunOut(now: Date = Date()) -> Date? {
        guard let used = usedPercent, used > 0, used < 100, let start = windowStart, let resetsAt,
              now > start else { return nil }
        let rate = used / now.timeIntervalSince(start) // % per second
        let out = now.addingTimeInterval((100 - used) / rate)
        return out < resetsAt ? out : nil
    }
}

// MARK: - Agents

enum AIAgentStatus: String, Sendable {
    case working, idle, needsYou, finished
    var label: String {
        switch self {
        case .working: return "Working"
        case .idle: return "Idle"
        case .needsYou: return "Needs you"
        case .finished: return "Finished"
        }
    }
    var color: Color {
        switch self {
        case .working: return .green
        case .idle: return .gray
        case .needsYou: return .orange
        case .finished: return .blue
        }
    }
}

/// A running agent session (or a subagent it spawned).
struct AIAgent: Identifiable, Equatable, Sendable {
    var id: String
    var provider: AIProvider
    var pid: Int32?
    var sessionID: String?
    var title: String
    var project: String
    var cwd: String
    var host: String?              // "VS Code", "Terminal", "Desktop"
    var status: AIAgentStatus
    /// Why it needs you ("permission", "input needed").
    var waitingFor: String?
    var startedAt: Date
    var statusSince: Date
    var currentPrompt: String?
    var lastActivity: AIActivity?
    var sessionTokens = 0
    var sessionCost: Double = 0
    var subagents: [AISubagent] = []
}

struct AISubagent: Identifiable, Equatable, Sendable {
    var id: String
    var type: String               // "Explore", "web-fetch"
    var detail: String             // its description
    var model: String?
    var running: Bool
}

// MARK: - Per-provider rollups (what the views show)

struct AIModelUsage: Identifiable, Sendable {
    var id: String { model }
    var model: String
    var totals: AIUsageTotals
}

struct AIProjectUsage: Identifiable, Sendable {
    var id: String { project }
    var project: String
    var totals: AIUsageTotals
    var sessions: Int
}

struct AIDayUsage: Identifiable, Sendable {
    var id: Date { day }
    var day: Date
    var totals: AIUsageTotals
}

struct AIProviderUsage: Identifiable, Sendable {
    var id: AIProvider { provider }
    var provider: AIProvider
    var detected = false
    var plan: String?
    var limits: [AILimitWindow] = []
    /// Shown under the limits ("Connect to see live limits", an error, "as of 2:10 PM").
    var limitsNote: String?
    var today = AIUsageTotals.zero
    /// The current limit window (live start when known, else estimated from activity).
    var window = AIUsageTotals.zero
    var windowStart: Date?
    var windowIsEstimate = true
    var week = AIUsageTotals.zero
    var weekStart: Date?
    var month = AIUsageTotals.zero
    var byModel: [AIModelUsage] = []      // this week
    var byProject: [AIProjectUsage] = []  // this week
    var daily: [AIDayUsage] = []          // last 30 days, oldest first
    var hourlyToday: [Int] = Array(repeating: 0, count: 24)
    var lastActivity: Date?

    /// The limit that's closest to running out (for the closed island and alerts).
    var tightestLimit: AILimitWindow? {
        limits.filter { $0.usedPercent != nil }.max { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) }
    }
}

struct AIUsageSnapshot: Sendable {
    var providers: [AIProviderUsage] = []
    var agents: [AIAgent] = []
    var tasks: [AITaskRecord] = []         // newest first
    var sessions: [AISessionRecord] = []   // newest first
    var log: [AIRequestRecord] = []        // newest first
    var generated = Date.distantPast

    static let empty = AIUsageSnapshot()

    func usage(for provider: AIProvider) -> AIProviderUsage? { providers.first { $0.provider == provider } }
    var detectedProviders: [AIProviderUsage] { providers.filter(\.detected) }
}
