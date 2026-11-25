//
//  AIUsageWindow.swift
//  Hoverbird · AI Usage
//
//  The full AI Usage window (⤢ in the AI tab): limits with pace, totals (today, the
//  current 5-hour window, week, 30 days), 30 days of tokens and today by hour, and
//  tables — Agents, Tasks (per prompt), Sessions (time log), Models, Projects and the
//  Log (every call) — each exportable as CSV.
//

import Charts
import Defaults
import SwiftUI

final class AIUsageWindowController: NSObject, NSWindowDelegate {
    static let shared = AIUsageWindowController()
    private var window: NSWindow?

    @MainActor
    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "AI Usage"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 860, height: 600)
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView = NSHostingView(rootView: AIUsageDetailView())
            w.setFrameAutosaveName("HoverbirdAIUsage")
            if w.frame.origin == .zero { w.center() }
            w.delegate = self
            window = w
        }
        AIUsageStore.shared.attach(.window)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { AIUsageStore.shared.detach(.window) }
    }
}

struct AIUsageDetailView: View {
    enum Section: String, CaseIterable, Identifiable {
        case agents = "Agents", tasks = "Tasks", sessions = "Sessions", models = "Models", projects = "Projects", log = "Log"
        var id: String { rawValue }
    }

    @ObservedObject private var store = AIUsageStore.shared
    @Default(.aiFocusedProvider) private var focusedRaw
    @Default(.aiShowCosts) private var showCosts
    @Default(.aiHideDetails) private var hide
    @State private var section: Section = .tasks
    @State private var selectedDay: Date?

    private var detected: [AIProviderUsage] { store.snapshot.detectedProviders }
    private var usage: AIProviderUsage {
        if let raw = focusedRaw, let u = detected.first(where: { $0.provider.rawValue == raw }) { return u }
        return detected.max { ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast) } ?? AIProviderUsage(provider: .claude)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            topBar
            if detected.isEmpty {
                AIEmptyState(symbol: "sparkle", title: "No AI tools found yet",
                             detail: "Hoverbird reads Claude Code, Codex, Gemini CLI and Grok CLI logs on this Mac, and API accounts you add in Settings › AI Usage.")
            } else {
                limitsAndTotals
                charts.frame(height: 170)
                HStack {
                    Picker("", selection: $section) { ForEach(Section.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 460)
                    Spacer()
                    Button { export() } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }
                        .disabled(section == .agents)
                }
                table.frame(maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)
        .padding(.bottom, 18)
        .frame(minWidth: 860, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            ForEach(detected) { u in
                AIProviderChip(usage: u, selected: u.provider == usage.provider) { focusedRaw = u.provider.rawValue }
                    .scaleEffect(1.15)
            }
            Spacer()
            if let note = usage.limitsNote { Text(note).font(.caption).foregroundStyle(.orange).lineLimit(1) }
            if store.fetchingLive.contains(usage.provider) { ProgressView().controlSize(.small) }
            Text("Updated \(AIFormat.ago(store.snapshot.generated))").font(.caption).foregroundStyle(.secondary)
            Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh now")
            Button { SettingsWindowController.shared.showWindow() } label: { Image(systemName: "gearshape") }.help("AI Usage settings")
        }
    }

    // MARK: Limits & totals

    private var limitsAndTotals: some View {
        HStack(alignment: .top, spacing: 10) {
            let real = usage.limits.filter { !$0.isEstimate && $0.usedPercent != nil }
            if real.isEmpty {
                card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Limits").font(.headline)
                        if usage.provider.isLocal, let start = usage.windowStart {
                            Text("5-hour window ~\(AIFormat.clock(start)) – \(AIFormat.clock(start.addingTimeInterval(AIUsageAggregator.sessionWindow))) (estimated from your activity)")
                                .font(.callout).foregroundStyle(.secondary)
                        } else if !usage.limits.isEmpty {
                            ForEach(usage.limits) { w in Text("\(w.label): \(w.detail ?? "—")").font(.callout) }
                        } else {
                            Text("No limit window open right now.").font(.callout).foregroundStyle(.secondary)
                        }
                        if [.claude, .codex, .grok].contains(usage.provider), usage.limitsNote == nil {
                            AIConnectButton(provider: usage.provider).scaleEffect(1.2, anchor: .leading)
                        }
                    }
                }
                .frame(width: 300)
            } else {
                ForEach(real.prefix(4)) { w in card { AILimitMeter(window: w, large: true) }.frame(width: 210) }
            }
            totalCard("Today", usage.today)
            if usage.provider.isLocal { totalCard(usage.windowIsEstimate ? "5-hour window (est.)" : "5-hour window", usage.window) }
            totalCard("This week", usage.week)
            totalCard("30 days", usage.month)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func totalCard(_ title: String, _ t: AIUsageTotals) -> some View {
        card {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(t.tokens.total > 0 || t.cost == 0 ? AIFormat.tokens(t.tokens.total) : AIFormat.cost(t.cost))
                    .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                if showCosts && t.cost > 0 && t.tokens.total > 0 {
                    Text("≈ \(AIFormat.cost(t.cost)) at API prices").font(.caption).foregroundStyle(.secondary)
                }
                if t.tokens.total > 0 {
                    Text("in \(AIFormat.tokens(t.tokens.input)) · out \(AIFormat.tokens(t.tokens.output)) · cache \(AIFormat.tokens(t.tokens.cacheRead + t.tokens.cacheWrite))")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
                Text("\(t.requests) calls").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(minWidth: 120, maxWidth: .infinity)
    }

    // MARK: Charts

    private var charts: some View {
        HStack(spacing: 10) {
            card {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Tokens per day · last 30 days").font(.headline)
                        Spacer()
                        if let day = selectedDay, let d = usage.daily.first(where: { Calendar.current.isDate($0.day, inSameDayAs: day) }) {
                            Text("\(AIFormat.day(d.day)): \(AIFormat.tokens(d.totals.tokens.total))\(showCosts && d.totals.cost > 0 ? " · ≈\(AIFormat.cost(d.totals.cost))" : "") · \(d.totals.requests) calls")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    Chart(usage.daily) { d in
                        BarMark(x: .value("Day", d.day, unit: .day), y: .value("Tokens", d.totals.tokens.total))
                            .foregroundStyle(usage.provider.tint.gradient)
                            .opacity(selectedDay == nil || Calendar.current.isDate(d.day, inSameDayAs: selectedDay!) ? 1 : 0.45)
                    }
                    .chartXSelection(value: $selectedDay)
                    .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let n = v.as(Int.self) { Text(AIFormat.tokens(n)) } } } }
                }
            }
            card {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Today by hour").font(.headline)
                    Chart(Array(usage.hourlyToday.enumerated()), id: \.offset) { hour, tokens in
                        BarMark(x: .value("Hour", hour), y: .value("Tokens", tokens)).foregroundStyle(usage.provider.tint.opacity(0.85))
                    }
                    .chartXScale(domain: 0...23)
                    .chartXAxis { AxisMarks(values: [0, 6, 12, 18]) { v in AxisValueLabel { if let h = v.as(Int.self) { Text("\(h):00") } } } }
                    .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let n = v.as(Int.self) { Text(AIFormat.tokens(n)) } } } }
                }
            }
            .frame(width: 300)
        }
    }

    // MARK: Tables

    @ViewBuilder
    private var table: some View {
        let provider = usage.provider
        switch section {
        case .agents:
            let agents = store.snapshot.agents
            if agents.isEmpty {
                card { Text("No agents running right now.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            } else {
                card {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(agents) { a in
                                VStack(alignment: .leading, spacing: 4) {
                                    AIAgentRow(agent: a, large: true)
                                    if let p = a.currentPrompt, !hide { Text("Task: \(p)").font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                    ForEach(a.subagents) { s in
                                        Text("↳ \(s.type)\(s.detail.isEmpty ? "" : " — \(s.detail)")\(s.model.map { " · \(AIFormat.model($0))" } ?? "")")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Divider()
                            }
                        }
                    }
                }
            }
        case .tasks:
            Table(store.snapshot.tasks.filter { $0.provider == provider }) {
                TableColumn("Started") { Text(AIFormat.clock($0.start)).monospacedDigit() }.width(110)
                TableColumn("Task") { t in Text(hide ? "Prompt hidden" : t.prompt).lineLimit(1).help(hide ? "" : t.prompt) }
                TableColumn("Project") { Text(hide ? "—" : $0.project) }.width(110)
                TableColumn("Time") { Text(AIFormat.duration($0.duration)).monospacedDigit() }.width(60)
                TableColumn("Tokens") { Text(AIFormat.tokens($0.totals.tokens.total)).monospacedDigit() }.width(64)
                TableColumn("Output") { Text(AIFormat.tokens($0.totals.tokens.output)).monospacedDigit() }.width(60)
                TableColumn("≈ Cost") { Text(showCosts ? AIFormat.cost($0.totals.cost) : "—").monospacedDigit() }.width(60)
                TableColumn("Calls") { t in Text("\(t.totals.requests)\(t.subagentCalls > 0 ? " (\(t.subagentCalls) sub)" : "")").monospacedDigit() }.width(80)
                TableColumn("Models") { Text($0.models.map(AIFormat.model).joined(separator: ", ")).lineLimit(1) }.width(110)
            }
        case .sessions:
            Table(store.snapshot.sessions.filter { $0.provider == provider }) {
                TableColumn("Session") { s in Text(hide ? "Session" : s.displayTitle).lineLimit(1) }
                TableColumn("Project") { Text(hide ? "—" : $0.project) }.width(110)
                TableColumn("Started") { Text(AIFormat.clock($0.start)).monospacedDigit() }.width(110)
                TableColumn("Last") { Text(AIFormat.ago($0.end)) }.width(80)
                TableColumn("Active") { Text(AIFormat.duration($0.activeSeconds)).monospacedDigit() }.width(64)
                TableColumn("Tasks") { Text("\($0.taskCount)").monospacedDigit() }.width(44)
                TableColumn("Tokens") { Text(AIFormat.tokens($0.totals.tokens.total)).monospacedDigit() }.width(64)
                TableColumn("≈ Cost") { s in
                    Text(showCosts ? AIFormat.cost(s.totals.cost) : "—").monospacedDigit()
                        .help(s.reportedCost.map { "\(s.provider.name)'s own figure: \(AIFormat.cost($0))" } ?? "")
                }.width(64)
                TableColumn("Where") { Text($0.host ?? "—") }.width(80)
            }
        case .models:
            Table(usage.byModel) {
                TableColumn("Model (this week)") { Text(AIFormat.model($0.model)).help($0.model) }
                TableColumn("Calls") { Text("\($0.totals.requests)").monospacedDigit() }.width(60)
                TableColumn("Input") { Text(AIFormat.tokens($0.totals.tokens.input)).monospacedDigit() }.width(70)
                TableColumn("Output") { Text(AIFormat.tokens($0.totals.tokens.output)).monospacedDigit() }.width(70)
                TableColumn("Cache read") { Text(AIFormat.tokens($0.totals.tokens.cacheRead)).monospacedDigit() }.width(80)
                TableColumn("Cache write") { Text(AIFormat.tokens($0.totals.tokens.cacheWrite)).monospacedDigit() }.width(80)
                TableColumn("Total") { Text(AIFormat.tokens($0.totals.tokens.total)).monospacedDigit() }.width(70)
                TableColumn("≈ Cost") { Text(showCosts ? AIFormat.cost($0.totals.cost) : "—").monospacedDigit() }.width(70)
            }
        case .projects:
            Table(usage.byProject) {
                TableColumn("Project (this week)") { Text(hide ? "Project" : $0.project) }
                TableColumn("Sessions") { Text("\($0.sessions)").monospacedDigit() }.width(70)
                TableColumn("Calls") { Text("\($0.totals.requests)").monospacedDigit() }.width(60)
                TableColumn("Tokens") { Text(AIFormat.tokens($0.totals.tokens.total)).monospacedDigit() }.width(80)
                TableColumn("Output") { Text(AIFormat.tokens($0.totals.tokens.output)).monospacedDigit() }.width(80)
                TableColumn("≈ Cost") { Text(showCosts ? AIFormat.cost($0.totals.cost) : "—").monospacedDigit() }.width(80)
            }
        case .log:
            let sessions = Dictionary(store.snapshot.sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            Table(logRows(provider)) {
                TableColumn("Time") { Text(AIFormat.clock($0.r.time)).monospacedDigit() }.width(110)
                TableColumn("Model") { r in Text(AIFormat.model(r.r.model) + (r.r.isSubagent ? " · subagent" : "")) }.width(140)
                TableColumn("Session") { r in Text(hide ? "—" : (sessions[r.r.sessionID]?.displayTitle ?? "—")).lineLimit(1) }
                TableColumn("Input") { Text(AIFormat.tokens($0.r.tokens.input)).monospacedDigit() }.width(56)
                TableColumn("Output") { Text(AIFormat.tokens($0.r.tokens.output)).monospacedDigit() }.width(56)
                TableColumn("Cache R") { Text(AIFormat.tokens($0.r.tokens.cacheRead)).monospacedDigit() }.width(60)
                TableColumn("Cache W") { Text(AIFormat.tokens($0.r.tokens.cacheWrite)).monospacedDigit() }.width(60)
                TableColumn("≈ Cost") { r in Text(showCosts ? (r.r.cost.map(AIFormat.cost) ?? "—") : "—").monospacedDigit() }.width(60)
            }
        }
    }

    private struct LogRow: Identifiable { let id: Int; let r: AIRequestRecord }
    private func logRows(_ provider: AIProvider) -> [LogRow] {
        store.snapshot.log.filter { $0.provider == provider }.enumerated().map { LogRow(id: $0.offset, r: $0.element) }
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    // MARK: Export

    private func export() {
        let provider = usage.provider
        func csv(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let iso = ISO8601DateFormatter()
        var lines: [String] = []
        switch section {
        case .agents:
            return
        case .tasks:
            lines.append("started,task,project,seconds,input,output,cache_read,cache_write,total_tokens,cost_usd,calls,subagent_calls,models")
            for t in store.snapshot.tasks where t.provider == provider {
                let k = t.totals.tokens
                lines.append([iso.string(from: t.start), csv(hide ? "" : t.prompt), csv(hide ? "" : t.project), "\(Int(t.duration))", "\(k.input)", "\(k.output)",
                              "\(k.cacheRead)", "\(k.cacheWrite)", "\(k.total)", String(format: "%.4f", t.totals.cost), "\(t.totals.requests)",
                              "\(t.subagentCalls)", csv(t.models.joined(separator: " "))].joined(separator: ","))
            }
        case .sessions:
            lines.append("session,project,started,ended,active_seconds,tasks,total_tokens,cost_usd,reported_cost_usd,where")
            for s in store.snapshot.sessions where s.provider == provider {
                lines.append([csv(hide ? "" : s.displayTitle), csv(hide ? "" : s.project), iso.string(from: s.start), iso.string(from: s.end),
                              "\(Int(s.activeSeconds))", "\(s.taskCount)", "\(s.totals.tokens.total)", String(format: "%.4f", s.totals.cost),
                              s.reportedCost.map { String(format: "%.4f", $0) } ?? "", csv(s.host ?? "")].joined(separator: ","))
            }
        case .models:
            lines.append("model,calls,input,output,cache_read,cache_write,total_tokens,cost_usd")
            for m in usage.byModel {
                let k = m.totals.tokens
                lines.append([csv(m.model), "\(m.totals.requests)", "\(k.input)", "\(k.output)", "\(k.cacheRead)", "\(k.cacheWrite)",
                              "\(k.total)", String(format: "%.4f", m.totals.cost)].joined(separator: ","))
            }
        case .projects:
            lines.append("project,sessions,calls,total_tokens,output,cost_usd")
            for p in usage.byProject {
                lines.append([csv(hide ? "" : p.project), "\(p.sessions)", "\(p.totals.requests)", "\(p.totals.tokens.total)", "\(p.totals.tokens.output)",
                              String(format: "%.4f", p.totals.cost)].joined(separator: ","))
            }
        case .log:
            lines.append("time,model,session,subagent,input,output,cache_read,cache_write_5m,cache_write_1h,web_searches,cost_usd")
            for r in store.snapshot.log where r.provider == provider {
                let k = r.tokens
                lines.append([iso.string(from: r.time), csv(r.model), csv(r.sessionID), r.isSubagent ? "1" : "0", "\(k.input)", "\(k.output)",
                              "\(k.cacheRead)", "\(k.cacheWrite5m)", "\(k.cacheWrite1h)", "\(r.webSearches)",
                              r.cost.map { String(format: "%.5f", $0) } ?? ""].joined(separator: ","))
            }
        }
        let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd HH.mm"
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? AIFiles.home
        let url = downloads.appendingPathComponent("AI Usage – \(provider.name) \(section.rawValue) \(stamp.string(from: Date())).csv")
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSSound.beep()
        }
    }
}
