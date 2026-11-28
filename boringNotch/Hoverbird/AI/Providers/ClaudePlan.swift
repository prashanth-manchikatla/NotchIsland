//
//  ClaudePlan.swift
//  Hoverbird
//
//  The Claude plan's name ("Pro", "Max 5×", "Max 20×", "Team"…). Claude Code writes the plan
//  into its Keychain sign-in when you log in and keeps it there after an upgrade, so a Pro → Max
//  upgrade still reads "pro". The account profile Claude Code keeps refreshing from Anthropic
//  (~/.claude.json → oauthAccount) is current, so it wins; the sign-in is only the fallback.
//

import Foundation

enum ClaudePlan {
    /// The plan in Claude Code's account profile (the contents of ~/.claude.json), or nil.
    /// Only the plan fields are read.
    static func fromProfile(_ data: Data?) -> String? {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = object["oauthAccount"] as? [String: Any] else { return nil }
        let tier = (account["userRateLimitTier"] as? String) ?? (account["organizationRateLimitTier"] as? String)
        return name(type: account["organizationType"] as? String, tier: tier)
    }

    /// "claude_max" or "max", with a rate-limit tier like "default_claude_max_5x" → "Max 5×".
    /// The tier is what Anthropic applies, so it decides between Max 5× and 20×.
    static func name(type: String?, tier: String?) -> String? {
        let tier = (tier ?? "").lowercased()
        if tier.contains("max_20x") { return "Max 20×" }
        if tier.contains("max_5x") { return "Max 5×" }
        var kind = (type ?? "").lowercased()
        if kind.hasPrefix("claude_") { kind.removeFirst("claude_".count) }
        switch kind {
        case "": return nil
        case "max": return "Max"
        case "pro": return "Pro"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        default: return kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
