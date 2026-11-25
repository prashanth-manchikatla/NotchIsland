//
//  AITabView.swift
//  NotchIsland · AI Usage
//
//  ✦ AI tab in the island. Overview: the focused provider's limits (with a pace marker),
//  the agents that are running, and today / this week. Tasks: what each prompt cost.
//  Log: every model call. ⤢ opens the full AI Usage window; 📌 keeps the tightest
//  limit in the closed island.
//

import Defaults
import SwiftUI

struct AITabView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var store = AIUsageStore.shared
    @Default(.aiTabMode) private var mode
    @Default(.aiUsageInIsland) private var pinned
    @Default(.aiUsageEnabled) private var enabled
    @Default(.aiFocusedProvider) private var focusedRaw

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 5) {
                if !enabled {
                    AIEmptyState(symbol: "sparkle", title: "AI Usage is off", detail: "Turn it on in Settings › AI Usage.")
                } else if store.snapshot.generated == .distantPast {
                    AIEmptyState(symbol: "hourglass", title: "Reading your AI logs…", detail: nil)
                } else if store.snapshot.detectedProviders.isEmpty {
                    AIEmptyState(symbol: "sparkle", title: "No AI tools found yet",
                                 detail: "Claude Code, Codex, Gemini CLI and Grok CLI show up here by themselves. API accounts: Settings › AI Usage.")
                } else {
                    header
                    switch mode {
                    case .overview: AIOverview(usage: focused, agents: store.snapshot.agents, compact: vm.isCameraExpanded)
                    case .tasks: AITaskList(tasks: store.snapshot.tasks.filter { $0.provider == focused.provider }, rows: 4)
                    case .log: AIRequestLogList(log: store.snapshot.log.filter { $0.provider == focused.provider },
                                                sessions: store.snapshot.sessions, rows: 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            VStack(spacing: 6) {
                AISideButton(symbol: "arrow.up.left.and.arrow.down.right", active: false, help: "Open AI Usage (tasks, sessions, charts, logs)") {
                    AIUsageWindowController.shared.show()
                }
                AISideButton(symbol: pinned ? "pin.fill" : "pin", active: pinned,
                             help: pinned ? "Stop showing usage in the closed island" : "Keep the tightest limit in the closed island") {
                    pinned.toggle()
                }
                AISideButton(symbol: "arrow.clockwise", active: !store.fetchingLive.isEmpty, help: "Refresh now") {
                    store.refresh()
                }
                Spacer(minLength: 0)
            }
            .frame(width: 24)
        }
        .frame(height: 128)
        .padding(.top, 2)
        .onAppear { store.attach(.tab) }
        .onDisappear { store.detach(.tab) }
    }

    /// The provider the tab focuses on: your pick, else the one used most recently.
    private var focused: AIProviderUsage {
        let detected = store.snapshot.detectedProviders
        if let raw = focusedRaw, let pick = detected.first(where: { $0.provider.rawValue == raw }) { return pick }
        return detected.max { ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast) } ?? AIProviderUsage(provider: .claude)
    }

    private var header: some View {
        HStack(spacing: 4) {
            let detected = store.snapshot.detectedProviders
            if detected.count > 1 {
                ForEach(detected) { usage in
                    AIProviderChip(usage: usage, selected: usage.provider == focused.provider) {
                        focusedRaw = usage.provider.rawValue
                    }
                }
            } else {
                AIProviderChip(usage: focused, selected: true) {}
            }
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                ForEach(AITabMode.allCases) { m in
                    Button { withAnimation(.smooth(duration: 0.25)) { mode = m } } label: {
                        Text(m.rawValue)
                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(mode == m ? .white : .white.opacity(0.5))
                            .padding(.horizontal, 7).padding(.vertical, 2.5)
                            .background(Capsule().fill(Color.white.opacity(mode == m ? 0.16 : 0)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Capsule().fill(Color.white.opacity(0.06)))
        }
        .frame(height: 18)
    }
}

// MARK: - Overview

private struct AIOverview: View {
    let usage: AIProviderUsage
    let agents: [AIAgent]
    let compact: Bool
    @Default(.aiShowCosts) private var showCosts

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            AILimitsCard(usage: usage)
                .frame(width: compact ? 190 : 206)
            AIAgentsCard(agents: agents)
                .frame(maxWidth: .infinity)
            if !compact {
                AITotalsCard(usage: usage, showCosts: showCosts)
                    .frame(width: 112)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// The provider's limits: real ones (live / from its logs) or the estimated 5-hour window.
struct AILimitsCard: View {
    let usage: AIProviderUsage
    @ObservedObject private var store = AIUsageStore.shared
    @Default(.aiShowCosts) private var showCosts

    var body: some View {
        AICard {
            let real = usage.limits.filter { !$0.isEstimate && $0.usedPercent != nil }
            if !real.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(real.prefix(2))) { w in AILimitMeter(window: w) }
                }
                if let note = usage.limitsNote { AINote(note) }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(usage.provider.isLocal ? "5-hour window" : "Account").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                        Spacer(minLength: 0)
                        if let start = usage.windowStart, usage.provider.isLocal {
                            Text("~\(AIFormat.clock(start))–\(AIFormat.clock(start.addingTimeInterval(AIUsageAggregator.sessionWindow)))")
                                .font(.system(size: 9, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    if usage.provider.isLocal {
                        Text(usage.windowStart == nil ? "No window open" : "\(AIFormat.tokens(usage.window.tokens.total)) tokens")
                            .font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                        Text(showCosts && usage.window.cost > 0 ? "≈ \(AIFormat.cost(usage.window.cost)) at API prices · \(usage.window.requests) calls"
                                                                 : "\(usage.window.requests) calls")
                            .font(.system(size: 9)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                        if let start = usage.windowStart {
                            // How much of the (estimated) window has gone by.
                            let end = start.addingTimeInterval(AIUsageAggregator.sessionWindow)
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                VStack(alignment: .leading, spacing: 2) {
                                    AIMeterBar(fraction: context.date.timeIntervalSince(start) / AIUsageAggregator.sessionWindow,
                                               tint: usage.provider.tint.opacity(0.7))
                                        .frame(height: 4)
                                    Text("window ends ~\(AIFormat.clock(end)) · \(AIFormat.until(end, now: context.date))")
                                        .font(.system(size: 9).monospacedDigit()).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                                }
                            }
                            .padding(.top, 2)
                        }
                    } else {
                        ForEach(usage.limits) { w in
                            Text("\(w.label): \(w.detail ?? "—")").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if let note = usage.limitsNote {
                        AINote(note)
                    } else if usage.provider == .claude || usage.provider == .codex || usage.provider == .grok {
                        AIConnectButton(provider: usage.provider)
                    }
                }
            }
        }
    }
}

struct AILimitMeter: View {
    let window: AILimitWindow
    var large = false

    var body: some View {
        let used = window.usedPercent ?? 0
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(window.label).font(.system(size: large ? 12 : 10, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                Spacer(minLength: 0)
                Text(AIFormat.percent(used))
                    .font(.system(size: large ? 15 : 12, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(AILimitMeter.color(used))
            }
            AIMeterBar(fraction: used / 100, pace: window.elapsedFraction(), tint: AILimitMeter.color(used))
                .frame(height: large ? 7 : 5)
            Text(caption).font(.system(size: large ? 10.5 : 9).monospacedDigit()).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
        }
    }

    private var caption: String {
        if let detail = window.detail, window.resetsAt == nil { return detail }
        guard let resets = window.resetsAt else { return window.detail ?? "" }
        var text = "resets \(AIFormat.clock(resets)) · \(AIFormat.until(resets))"
        if let out = window.projectedRunOut() { text = "runs out ~\(AIFormat.clock(out)) · resets \(AIFormat.clock(resets))" }
        return text
    }

    static func color(_ used: Double) -> Color {
        used >= 90 ? .red : (used >= 75 ? .orange : (used >= 50 ? .yellow : .green))
    }
}

/// A rounded meter with a thin mark where an even pace would be.
struct AIMeterBar: View {
    let fraction: Double
    var pace: Double?
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule().fill(tint.gradient).frame(width: max(geo.size.height, geo.size.width * min(1, max(0, fraction))))
                if let pace, pace > 0.02, pace < 0.98 {
                    Rectangle().fill(Color.white.opacity(0.75)).frame(width: 1.5, height: geo.size.height + 4)
                        .offset(x: geo.size.width * pace - 0.75)
                }
            }
        }
        .help(pace.map { "The mark shows where you'd be at an even pace (\(Int($0 * 100))% of the window has passed)." } ?? "")
    }
}

/// Opt-in for live limits (it reads that CLI's sign-in, so it asks first).
struct AIConnectButton: View {
    let provider: AIProvider

    var body: some View {
        Button { AIConnect.ask(provider) } label: {
            HStack(spacing: 3) {
                Image(systemName: "bolt.fill").font(.system(size: 8, weight: .bold))
                Text("Show live limits").font(.system(size: 9.5, weight: .semibold))
            }
            .foregroundStyle(provider.tint)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(provider.tint.opacity(0.16)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Read the real \(provider.name) limits with the sign-in that's already on this Mac")
    }
}

enum AIConnect {
    /// Explains what happens, then turns the provider's live limits on.
    @MainActor
    static func ask(_ provider: AIProvider) {
        let alert = NSAlert()
        alert.messageText = "Show live \(provider.name) limits?"
        switch provider {
        case .claude:
            alert.informativeText = "NotchIsland reads the numbers Claude Code shows in /usage (5-hour and weekly limits, with reset times). It uses Claude Code's sign-in, so macOS will ask to let NotchIsland use “Claude Code-credentials” from your Keychain — choose Always Allow.\n\nThe sign-in is only sent to api.anthropic.com, never saved or changed."
        case .codex:
            alert.informativeText = "NotchIsland reads your ChatGPT plan's Codex limits using the sign-in in ~/.codex/auth.json. It's only sent to chatgpt.com, never saved or changed."
        default:
            alert.informativeText = "NotchIsland reads your SuperGrok credits using Grok CLI's sign-in (~/.grok/auth.json). It's only sent to xAI, never saved or changed."
        }
        alert.addButton(withTitle: "Show Live Limits")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        switch provider {
        case .claude: Defaults[.aiClaudeLiveLimits] = true
        case .codex: Defaults[.aiCodexLiveLimits] = true
        case .grok: Defaults[.aiGrokLiveLimits] = true
        default: break
        }
    }
}

// MARK: - Agents

struct AIAgentsCard: View {
    let agents: [AIAgent]

    var body: some View {
        AICard(padding: 6) {
            if agents.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("No agents running").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                    Text("Claude Code, Codex, Gemini and Grok sessions appear here while they run — with what they're doing.")
                        .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.45)).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(agents) { agent in AIAgentRow(agent: agent) }
                    }
                }
            }
        }
    }
}

struct AIAgentRow: View {
    let agent: AIAgent
    var large = false
    @Default(.aiHideDetails) private var hide

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            AIStatusDot(status: agent.status).padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(hide ? agent.provider.name : agent.title)
                        .font(.system(size: large ? 12.5 : 10.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Spacer(minLength: 2)
                    TimelineView(.periodic(from: .now, by: agent.status == .working ? 1 : 30)) { context in
                        Text("\(agent.status.label) \(AIFormat.duration(context.date.timeIntervalSince(agent.statusSince)))")
                            .font(.system(size: large ? 10.5 : 9, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(agent.status.color)
                    }
                    if let host = agent.host, let app = AIAgentRow.appURL(host) {
                        Button { NSWorkspace.shared.open(app) } label: {
                            Image(systemName: "arrow.up.forward.app").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .help("Show \(host)")
                    }
                }
                Text(detail)
                    .font(.system(size: large ? 10.5 : 9)).foregroundStyle(agent.status == .needsYou ? .orange : .white.opacity(0.5)).lineLimit(1)
            }
        }
    }

    private var detail: String {
        if agent.status == .needsYou { return "Waiting for \(agent.waitingFor ?? "you")" + (agent.host.map { " in \($0)" } ?? "") }
        var parts: [String] = [hide ? "" : agent.project, agent.host ?? ""].filter { !$0.isEmpty }
        if agent.sessionTokens > 0 { parts.append("\(AIFormat.tokens(agent.sessionTokens)) tok") }
        if !agent.subagents.isEmpty { parts.append("+\(agent.subagents.count) subagent\(agent.subagents.count == 1 ? "" : "s")") }
        if agent.status == .working, !hide, let a = agent.lastActivity, Date().timeIntervalSince(a.time) < 600 { parts.append(a.text) }
        return parts.joined(separator: " · ")
    }

    /// The app an agent runs in, to bring it forward.
    static func appURL(_ host: String) -> URL? {
        let ids: [String: String] = ["VS Code": "com.microsoft.VSCode", "Cursor": "com.todesktop.230313mzl4w4u92",
                                     "Windsurf": "com.exafunction.windsurf", "Terminal": "com.apple.Terminal",
                                     "Claude Desktop": "com.anthropic.claudefordesktop"]
        guard let id = ids[host] else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }
}

struct AIStatusDot: View {
    let status: AIAgentStatus

    var body: some View {
        Circle().fill(status.color).frame(width: 6, height: 6)
            .phaseAnimator(status == .working || status == .needsYou ? [1.0, 0.35] : [1.0]) { view, phase in view.opacity(phase) }
                animation: { _ in .easeInOut(duration: 0.9) }
    }
}

// MARK: - Totals

private struct AITotalsCard: View {
    let usage: AIProviderUsage
    let showCosts: Bool

    var body: some View {
        AICard(padding: 6) {
            VStack(alignment: .leading, spacing: 4) {
                total("Today", usage.today)
                total("This week", usage.week)
                AISparkline(values: usage.daily.suffix(7).map { Double($0.totals.tokens.total) }, tint: usage.provider.tint)
                    .frame(height: 16)
                    .help("Tokens per day, last 7 days")
            }
        }
    }

    private func total(_ title: String, _ t: AIUsageTotals) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased()).font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.4))
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(t.tokens.total > 0 || t.cost == 0 ? AIFormat.tokens(t.tokens.total) : AIFormat.cost(t.cost))
                    .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(.white)
                if showCosts && t.cost > 0 && t.tokens.total > 0 {
                    Text("≈\(AIFormat.cost(t.cost))").font(.system(size: 9, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .help("\(t.requests) calls · in \(AIFormat.tokens(t.tokens.input)) · out \(AIFormat.tokens(t.tokens.output)) · cache read \(AIFormat.tokens(t.tokens.cacheRead)) · cache write \(AIFormat.tokens(t.tokens.cacheWrite))")
    }
}

struct AISparkline: View {
    let values: [Double]
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            let top = max(values.max() ?? 1, 1)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(v > 0 ? tint.opacity(0.85) : Color.white.opacity(0.12))
                        .frame(height: max(2, geo.size.height * v / top))
                }
            }
        }
    }
}

// MARK: - Tasks & log (island lists)

struct AITaskList: View {
    let tasks: [AITaskRecord]
    let rows: Int
    @Default(.aiShowCosts) private var showCosts
    @Default(.aiHideDetails) private var hide

    var body: some View {
        AICard(padding: 6) {
            if tasks.isEmpty {
                Text("No tasks yet — every prompt you give an agent shows up here with what it cost.")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 3) {
                        ForEach(tasks.prefix(60)) { task in
                            HStack(spacing: 6) {
                                Text(hide ? "Prompt hidden" : task.prompt)
                                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(stats(task)).font(.system(size: 9, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.55))
                                    .lineLimit(1).fixedSize()
                            }
                            .frame(height: 16)
                            .help(hide ? "" : "\(task.prompt)\n\(task.project) · \(AIFormat.clock(task.start)) · \(task.totals.requests) calls\(task.subagentCalls > 0 ? " (\(task.subagentCalls) by subagents)" : "") · \(task.models.map(AIFormat.model).joined(separator: ", "))")
                        }
                    }
                }
            }
        }
    }

    private func stats(_ t: AITaskRecord) -> String {
        var parts = [AIFormat.duration(t.duration), "\(AIFormat.tokens(t.totals.tokens.total)) tok"]
        if showCosts && t.totals.cost > 0 { parts.append("≈\(AIFormat.cost(t.totals.cost))") }
        parts.append(AIFormat.ago(t.start))
        return parts.joined(separator: " · ")
    }
}

struct AIRequestLogList: View {
    let log: [AIRequestRecord]
    let sessions: [AISessionRecord]
    let rows: Int
    @Default(.aiShowCosts) private var showCosts

    private static let time: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("j:mm:ss"); return f }()

    var body: some View {
        AICard(padding: 6) {
            if log.isEmpty {
                Text("No calls yet.").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 3) {
                        ForEach(Array(log.prefix(100).enumerated()), id: \.offset) { _, r in
                            HStack(spacing: 6) {
                                Text(Self.time.string(from: r.time)).frame(width: 58, alignment: .leading).foregroundStyle(.white.opacity(0.5))
                                Text(AIFormat.model(r.model) + (r.isSubagent ? " ·sub" : "")).frame(width: 78, alignment: .leading).foregroundStyle(.white.opacity(0.85))
                                Text("in \(AIFormat.tokens(r.tokens.input)) · out \(AIFormat.tokens(r.tokens.output)) · cache \(AIFormat.tokens(r.tokens.cacheRead + r.tokens.cacheWrite))")
                                    .foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                                Spacer(minLength: 4)
                                if showCosts, let c = r.cost { Text("≈\(AIFormat.cost(c))").foregroundStyle(.white.opacity(0.55)) }
                            }
                            .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                            .frame(height: 15)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Building blocks

struct AICard<Content: View>: View {
    var padding: CGFloat = 7
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}

struct AIProviderChip: View {
    let usage: AIProviderUsage
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: usage.provider.symbol).font(.system(size: 8.5, weight: .bold)).foregroundStyle(usage.provider.tint)
                Text(usage.provider.name).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(selected ? 1 : 0.6))
                if let plan = usage.plan, selected {
                    Text(plan).font(.system(size: 8.5, weight: .bold)).foregroundStyle(usage.provider.tint)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(usage.provider.tint.opacity(0.18)))
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(selected ? 0.12 : 0.04)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct AIEmptyState: View {
    let symbol: String
    let title: String
    let detail: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(AIProvider.claude.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                if let detail { Text(detail).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AINote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 8.5)).foregroundStyle(.orange.opacity(0.85)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
    }
}

struct AISideButton: View {
    let symbol: String
    let active: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(active ? Color.orange : Color.white.opacity(0.85))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.18 : 0.09)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
