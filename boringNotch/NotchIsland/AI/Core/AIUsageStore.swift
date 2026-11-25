//
//  AIUsageStore.swift
//  NotchIsland · AI Usage
//
//  The main-thread face of AI Usage: the latest snapshot for the views, the agent that
//  needs you and the working agents for the closed island, live-limit polling, alerts.
//  Polling is slow unless it matters: every 90 s while you look at the tab / window,
//  3 min while an agent works, 10 min otherwise (and only for providers you switched on).
//

import Combine
import Defaults
import SwiftUI

@MainActor
final class AIUsageStore: ObservableObject {
    static let shared = AIUsageStore()

    @Published private(set) var snapshot = AIUsageSnapshot.empty
    /// An agent waiting for you (a permission prompt, a question).
    @Published private(set) var attention: AIAgent?
    @Published private(set) var workingAgents: [AIAgent] = []
    @Published private(set) var fetchingLive: Set<AIProvider> = []

    enum Viewer: Hashable { case tab, window, settings }
    private var viewers = Set<Viewer>()
    private var started = false
    private var pollTask: Task<Void, Never>?
    private var lastLiveFetch: [AIProvider: Date] = [:]
    private var lastAccountsFetch = Date.distantPast
    private var cancellables = Set<AnyCancellable>()
    private let alerts = AIAlerts()

    private init() {}

    func start() {
        guard !started, Defaults[.aiUsageEnabled] else { return }
        started = true
        AIUsageEngine.shared.onSnapshot = { [weak self] snapshot in self?.apply(snapshot) }
        AIUsageEngine.shared.start()
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            while !Task.isCancelled {
                await self?.poll(force: false)
                try? await Task.sleep(for: .seconds(self?.pollInterval ?? 600))
            }
        }
        for key in [Defaults.Keys.aiClaudeLiveLimits, .aiCodexLiveLimits, .aiGrokLiveLimits] {
            Defaults.publisher(key, options: []).sink { [weak self] _ in
                Task { @MainActor in await self?.poll(force: true) }
            }.store(in: &cancellables)
        }
    }

    func stop() {
        guard started else { return }
        started = false
        pollTask?.cancel(); pollTask = nil
        cancellables.removeAll()
        AIUsageEngine.shared.stop()
        snapshot = .empty; attention = nil; workingAgents = []
    }

    /// Settings › AI Usage › "AI Usage" switch.
    func setEnabled(_ on: Bool) { if on { start() } else { stop() } }

    func attach(_ viewer: Viewer) {
        let first = viewers.isEmpty
        viewers.insert(viewer)
        if first {
            AIUsageEngine.shared.setViewing(true)
            Task { await poll(force: false) }
        }
    }

    func detach(_ viewer: Viewer) {
        viewers.remove(viewer)
        if viewers.isEmpty { AIUsageEngine.shared.setViewing(false) }
    }

    func refresh() {
        AIUsageEngine.shared.refreshNow()
        Task { await poll(force: true) }
    }

    /// API keys changed in Settings.
    func accountsChanged() {
        lastAccountsFetch = .distantPast
        Task { await poll(force: false) }
    }

    private var pollInterval: TimeInterval {
        if !viewers.isEmpty { return 90 }
        if !workingAgents.isEmpty || attention != nil { return 180 }
        return 600
    }

    private func apply(_ new: AIUsageSnapshot) {
        let old = snapshot
        snapshot = new
        let needsYou = new.agents.first { $0.status == .needsYou }
        if needsYou?.id != attention?.id || needsYou?.waitingFor != attention?.waitingFor { attention = needsYou }
        let working = new.agents.filter { $0.status == .working }
        if working.map(\.id) != workingAgents.map(\.id) || working.map(\.title) != workingAgents.map(\.title) {
            workingAgents = working
        }
        alerts.evaluate(old: old, new: new)
    }

    // MARK: Live limits & API accounts

    private func poll(force: Bool) async {
        guard started else { return }
        let switches: [(AIProvider, Bool)] = [(.claude, Defaults[.aiClaudeLiveLimits]),
                                              (.codex, Defaults[.aiCodexLiveLimits]),
                                              (.grok, Defaults[.aiGrokLiveLimits])]
        for (provider, on) in switches {
            guard on else {
                if lastLiveFetch[provider] != nil { lastLiveFetch[provider] = nil; AIUsageEngine.shared.setLive(nil, for: provider) }
                continue
            }
            if !force, let last = lastLiveFetch[provider], Date().timeIntervalSince(last) < 45 { continue }
            guard !fetchingLive.contains(provider) else { continue }
            fetchingLive.insert(provider)
            lastLiveFetch[provider] = Date()
            let state = await AILiveLimits.fetch(provider)
            fetchingLive.remove(provider)
            AIUsageEngine.shared.setLive(state, for: provider)
        }
        if force || Date().timeIntervalSince(lastAccountsFetch) > 600 {
            lastAccountsFetch = Date()
            let accounts = await AIAPIAccounts.fetchAll()
            AIUsageEngine.shared.setExtraProviders(accounts)
        }
    }
}
