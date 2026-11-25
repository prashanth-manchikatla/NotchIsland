//
//  AIAlerts.swift
//  Hoverbird · AI Usage
//
//  Island pills for AI Usage:
//   • "Claude 5-hour limit · 80% used · resets 3:10 PM" — once per window at 50 / 80 / 95 %
//     (only the highest one when several are crossed at once), and when it's reached;
//   • "At this pace the 5-hour limit runs out at 2:40 PM" — once per window;
//   • "Claude's 5-hour limit has reset" — at the reset time, if you'd used ≥ 80 % of it;
//   • "Claude finished · Hoverbird · 4m" — when an agent stops after ≥ 30 s of work.
//  Shown alerts are remembered (Defaults) so a relaunch doesn't repeat them.
//

import Defaults
import SwiftUI

@MainActor
final class AIAlerts {
    private var shown: [String] = Defaults[.aiShownAlerts]
    private var resetTimers: [String: Task<Void, Never>] = [:]

    func evaluate(old: AIUsageSnapshot, new: AIUsageSnapshot) {
        finishedTurns(old: old, new: new)
        guard Defaults[.aiLimitAlerts] else { return }
        let now = Date()
        for usage in new.providers {
            for w in usage.limits where !w.isEstimate {
                guard let used = w.usedPercent, let resets = w.resetsAt, resets > now else { continue }
                let instance = "\(w.id)@\(Int(resets.timeIntervalSince1970 / 600))"
                // Kept under ~45 characters: the caption under the closed island is 300 pt wide.
                let name = "\(w.provider.name) \(w.label.lowercased())"
                let back = AIFormat.clock(resets)

                if let crossed = [100.0, 95, 80, 50].first(where: { used >= $0 }), !shown.contains("\(instance)#\(Int(crossed))") {
                    for t in [50.0, 80, 95, 100] where t <= crossed { remember("\(instance)#\(Int(t))") }
                    let text = crossed >= 100 ? "\(name) limit reached · back \(back)"
                                              : "\(name) · \(AIFormat.percent(used)) used · resets \(back)"
                    pill(w.provider, crossed >= 95 ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.67percent",
                         text, tint: crossed >= 95 ? .red : (crossed >= 80 ? .orange : w.provider.tint), seconds: 4.5)
                } else if used >= 25, used < 95, let out = w.projectedRunOut(now: now), !shown.contains("\(instance)#pace") {
                    remember("\(instance)#pace")
                    pill(w.provider, "speedometer", "\(name) runs out ~\(AIFormat.clock(out)) at this pace",
                         tint: .orange, seconds: 5)
                }
                if used >= 80 { scheduleResetPill(for: w, instance: instance) }
            }
        }
    }

    private func finishedTurns(old: AIUsageSnapshot, new: AIUsageSnapshot) {
        guard Defaults[.aiFinishedPill] else { return }
        for before in old.agents where before.status == .working {
            guard let after = new.agents.first(where: { $0.id == before.id }), after.status == .idle else { continue }
            let worked = after.statusSince.timeIntervalSince(before.statusSince)
            guard worked >= 30 else { continue }
            let title = Defaults[.aiHideDetails] ? "" : " · " + String(before.title.prefix(18))
            pill(before.provider, "checkmark.circle.fill", "\(before.provider.name) finished\(title) · \(AIFormat.duration(worked))",
                 tint: .green, seconds: 3.5)
        }
    }

    private func scheduleResetPill(for w: AILimitWindow, instance: String) {
        let key = "\(instance)#reset"
        guard let resets = w.resetsAt, !shown.contains(key), resetTimers[key] == nil else { return }
        resetTimers[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(1, resets.timeIntervalSinceNow + 5)))
            guard let self, !Task.isCancelled, !self.shown.contains(key) else { return }
            self.remember(key)
            self.resetTimers[key] = nil
            self.pill(w.provider, "arrow.counterclockwise.circle.fill", "\(w.provider.name) \(w.label.lowercased()) limit reset · fresh window",
                      tint: .green, seconds: 4)
        }
    }

    private func remember(_ key: String) {
        shown.append(key)
        if shown.count > 80 { shown.removeFirst(shown.count - 80) }
        Defaults[.aiShownAlerts] = shown
    }

    private func pill(_ provider: AIProvider, _ symbol: String, _ text: String, tint: Color, seconds: TimeInterval) {
        IslandActivityHub.shared.showPill(.info(symbol: symbol, text: text, tint: tint), duration: seconds)
    }
}
