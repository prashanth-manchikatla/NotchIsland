//
//  AICompactViews.swift
//  NotchIsland · AI Usage
//
//  The closed island's AI live activities:
//   • needs you — an agent is waiting for a permission / your answer (pulsing, with caption);
//   • working   — an agent is busy: its icon + how long it has been working ("+1" for more);
//   • usage     — 📌 from the AI tab: the tightest limit's %, or tokens in the 5-hour window.
//

import Defaults
import SwiftUI

struct AICompactView: View {
    enum Kind { case attention, working, usage }
    let kind: Kind
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var store = AIUsageStore.shared
    @Default(.aiHideDetails) private var hide

    private var iconSize: CGFloat { max(12, vm.effectiveClosedNotchHeight - 16) }

    var body: some View {
        switch kind {
        case .attention:
            if let agent = store.attention {
                IslandCompactWithDetail(detail: caption(agent), tint: .orange) {
                    IslandCompactRow(sideWidth: 64) {
                        pulsing(Image(systemName: agent.provider.symbol)
                            .font(.system(size: iconSize, weight: .bold)).foregroundStyle(.orange))
                    } trailing: {
                        Text("Needs you").font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundStyle(.orange)
                    }
                }
            }
        case .working:
            if let agent = store.workingAgents.first {
                let extra = store.workingAgents.count - 1
                IslandCompactRow(sideWidth: extra > 0 ? 62 : 50) {
                    pulsing(Image(systemName: agent.provider.symbol)
                        .font(.system(size: iconSize, weight: .bold)).foregroundStyle(agent.provider.tint))
                } trailing: {
                    HStack(spacing: 3) {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(IslandTimerManager.clock(context.date.timeIntervalSince(agent.statusSince)))
                                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                                .foregroundStyle(agent.provider.tint)
                        }
                        if extra > 0 {
                            Text("+\(extra)").font(.system(size: 9.5, weight: .bold, design: .rounded))
                                .foregroundStyle(agent.provider.tint.opacity(0.75))
                        }
                    }
                }
            }
        case .usage:
            let (provider, text, color) = usageReadout
            IslandCompactRow(sideWidth: 46) {
                Image(systemName: provider.symbol).font(.system(size: iconSize, weight: .bold)).foregroundStyle(provider.tint)
            } trailing: {
                Text(text).font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(color)
            }
        }
    }

    private func caption(_ agent: AIAgent) -> String {
        let what = agent.waitingFor ?? "you"
        let title = hide ? "" : " · " + String(agent.title.prefix(22))
        return "\(agent.provider.name)\(title) · waiting for \(what)"
    }

    /// The tightest real limit; else tokens in the current window.
    private var usageReadout: (AIProvider, String, Color) {
        let providers = store.snapshot.detectedProviders
        if let w = providers.compactMap(\.tightestLimit).filter({ !$0.isEstimate }).max(by: { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) }),
           let used = w.usedPercent {
            return (w.provider, AIFormat.percent(used), AILimitMeter.color(used))
        }
        let active = providers.max { ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast) }
        return (active?.provider ?? .claude, AIFormat.tokens(active?.window.tokens.total ?? 0), .white)
    }

    private func pulsing<V: View>(_ view: V) -> some View {
        view.phaseAnimator([1.0, 0.45]) { v, phase in v.opacity(phase) } animation: { _ in .easeInOut(duration: 1.0) }
    }
}

/// The small detached bubble (secondary activity).
struct AIBubbleView: View {
    let kind: AICompactView.Kind
    let diameter: CGFloat
    @ObservedObject private var store = AIUsageStore.shared

    var body: some View {
        let icon = diameter * 0.46
        switch kind {
        case .attention:
            Image(systemName: "exclamationmark").font(.system(size: icon, weight: .heavy)).foregroundStyle(.orange)
        case .working:
            let provider = store.workingAgents.first?.provider ?? .claude
            Image(systemName: provider.symbol).font(.system(size: icon, weight: .bold)).foregroundStyle(provider.tint)
                .phaseAnimator([1.0, 0.45]) { v, phase in v.opacity(phase) } animation: { _ in .easeInOut(duration: 1.0) }
        case .usage:
            let w = store.snapshot.detectedProviders.compactMap(\.tightestLimit).filter { !$0.isEstimate }
                .max { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) }
            if let w, let used = w.usedPercent {
                ProgressRing(progress: used / 100, tint: AILimitMeter.color(used))
                    .frame(width: diameter - 10, height: diameter - 10)
            } else {
                Image(systemName: AIProvider.claude.symbol).font(.system(size: icon, weight: .bold)).foregroundStyle(AIProvider.claude.tint)
            }
        }
    }
}
