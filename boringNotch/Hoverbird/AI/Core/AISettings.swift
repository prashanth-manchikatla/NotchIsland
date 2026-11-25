//
//  AISettings.swift
//  Hoverbird · AI Usage
//
//  Preference keys for AI Usage (Settings › AI Usage).
//

import Defaults
import Foundation

enum AITabMode: String, CaseIterable, Identifiable, Defaults.Serializable {
    case overview = "Overview"
    case tasks = "Tasks"
    case log = "Log"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .tasks: return "checklist"
        case .log: return "list.bullet.rectangle"
        }
    }
}

extension Defaults.Keys {
    static let aiUsageEnabled = Key<Bool>("aiUsageEnabled", default: true)
    /// "≈ $" figures at API prices.
    static let aiShowCosts = Key<Bool>("aiShowCosts", default: true)
    /// Privacy: hide prompt text, commands and project names (screen sharing, screenshots).
    static let aiHideDetails = Key<Bool>("aiHideDetails", default: false)
    static let aiTabMode = Key<AITabMode>("aiTabMode", default: .overview)
    /// The provider the tab and window focus on (nil = the most active one).
    static let aiFocusedProvider = Key<String?>("aiFocusedProvider", default: nil)

    // Closed island
    /// A working agent shows in the closed island.
    static let aiWorkingInIsland = Key<Bool>("aiWorkingInIsland", default: true)
    /// An agent waiting for you (permission, a question) takes over the closed island.
    static let aiAttentionInIsland = Key<Bool>("aiAttentionInIsland", default: true)
    /// The tightest limit's % stays in the closed island (📌 in the AI tab).
    static let aiUsageInIsland = Key<Bool>("aiUsageInIsland", default: false)
    /// "Claude finished · 4m" pill when a turn ends after at least 30 s of work.
    static let aiFinishedPill = Key<Bool>("aiFinishedPill", default: true)

    // Alerts
    /// 50 / 80 / 95 % of a limit, "at this pace…", limit reached, limit reset.
    static let aiLimitAlerts = Key<Bool>("aiLimitAlerts", default: true)
    /// Alerts already shown (so they don't repeat after a relaunch).
    static let aiShownAlerts = Key<[String]>("aiShownAlerts", default: [])

    // Live limits (opt-in: they read a CLI's sign-in)
    static let aiClaudeLiveLimits = Key<Bool>("aiClaudeLiveLimits", default: false)
    static let aiCodexLiveLimits = Key<Bool>("aiCodexLiveLimits", default: false)
    static let aiGrokLiveLimits = Key<Bool>("aiGrokLiveLimits", default: false)
}
