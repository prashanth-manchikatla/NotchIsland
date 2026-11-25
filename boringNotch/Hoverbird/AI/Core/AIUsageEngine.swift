//
//  AIUsageEngine.swift
//  Hoverbird · AI Usage
//
//  The background half of AI Usage (one serial utility queue):
//   • first scan of the last 35 days of logs, then FSEvents for whatever changes;
//   • a safety sweep every 5 minutes (new tools installed, missed events, pruning);
//   • a light agent check every 20 s, only while agents exist (a crashed agent's file);
//   • snapshots: the full rollup only while someone is looking (tab / window open),
//     otherwise just the agents list (what the closed island needs).
//

import Foundation

final class AIUsageEngine: @unchecked Sendable {
    static let shared = AIUsageEngine()

    private let queue = DispatchQueue(label: "app.hoverbird.ai-usage", qos: .utility)
    private let db = AIUsageDB()
    private let ingestors: [AILogIngestor] = [ClaudeCodeIngestor(), CodexIngestor(), GeminiIngestor(), GrokIngestor()]
    private var cursors: [String: AIFileCursor] = [:]
    private var watcher: FSEventsWatcher?
    private var watchedPaths: [String] = []
    private var live: [AIProvider: AILiveState] = [:]
    private var extra: [AIProviderUsage] = []
    private var running = false
    private var viewing = false
    private var rebuildPending = false
    private var lastFullBuild = Date.distantPast
    private var lastSnapshot = AIUsageSnapshot.empty
    private var sweepTimer: DispatchSourceTimer?
    private var agentTimer: DispatchSourceTimer?

    /// Delivered on the main queue.
    var onSnapshot: ((AIUsageSnapshot) -> Void)?

    // MARK: Control (any thread)

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            AIPricing.reloadOverridesIfNeeded()
            let since = Date().addingTimeInterval(-AIUsageDB.retention)
            for ingestor in ingestors {
                for path in ingestor.files(modifiedSince: since) {
                    autoreleasepool { ingest(path, with: ingestor) }
                }
            }
            db.prune()
            malloc_zone_pressure_relief(nil, 0) // hand the parsing scratch memory back to the system
            restartWatcher()
            startTimers()
            rebuild(full: true)
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            watcher?.stop(); watcher = nil; watchedPaths = []
            sweepTimer?.cancel(); sweepTimer = nil
            agentTimer?.cancel(); agentTimer = nil
        }
    }

    /// The tab or window is showing: keep the full rollup fresh.
    func setViewing(_ on: Bool) {
        queue.async { [self] in
            let was = viewing
            viewing = on
            if on && !was && running { rebuild(full: true) }
        }
    }

    func setLive(_ state: AILiveState?, for provider: AIProvider) {
        queue.async { [self] in live[provider] = state; scheduleRebuild(full: true) }
    }

    func setExtraProviders(_ providers: [AIProviderUsage]) {
        queue.async { [self] in extra = providers; scheduleRebuild(full: true) }
    }

    func refreshNow() {
        queue.async { [self] in
            guard running else { return }
            sweep(since: Date().addingTimeInterval(-6 * 3_600))
            rebuild(full: true)
        }
    }

    // MARK: Ingest (queue)

    private func ingest(_ path: String, with ingestor: AILogIngestor) {
        var cursor = cursors[path] ?? AIFileCursor()
        ingestor.ingest(path: path, cursor: &cursor, into: db)
        cursors[path] = cursor
    }

    private func restartWatcher() {
        var paths = ingestors.flatMap { $0.roots.map(\.path) }
        let sessions = ClaudeAgents.sessionsDirectory.path
        if FileManager.default.fileExists(atPath: sessions) { paths.append(sessions) }
        guard paths != watchedPaths || watcher == nil else { return }
        watcher?.stop()
        watchedPaths = paths
        guard !paths.isEmpty else { watcher = nil; return }
        let w = FSEventsWatcher(paths: paths, latency: 1.5, queue: queue) { [weak self] changed in self?.changed(changed) }
        w.start()
        watcher = w
    }

    private func changed(_ paths: [String]) {
        guard running else { return }
        let sessionsDir = ClaudeAgents.sessionsDirectory.path
        var anything = false
        for path in Set(paths) {
            if path.hasPrefix(sessionsDir) || path.hasSuffix(".meta.json") { anything = true; continue }
            guard let ingestor = ingestors.first(where: { $0.owns(path) }),
                  AIFileReader.hasChanges(path, cursor: cursors[path] ?? AIFileCursor()) else { continue }
            ingest(path, with: ingestor)
            anything = true
        }
        if anything { scheduleRebuild(full: viewing) }
    }

    private func sweep(since: Date) {
        for ingestor in ingestors {
            for path in ingestor.files(modifiedSince: since)
            where AIFileReader.hasChanges(path, cursor: cursors[path] ?? AIFileCursor()) {
                ingest(path, with: ingestor)
            }
        }
        db.prune()
        cursors = cursors.filter { FileManager.default.fileExists(atPath: $0.key) }
        restartWatcher()
    }

    private func startTimers() {
        let sweep = DispatchSource.makeTimerSource(queue: queue)
        sweep.schedule(deadline: .now() + 300, repeating: 300, leeway: .seconds(30))
        sweep.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            self.sweep(since: Date().addingTimeInterval(-6 * 3_600))
            self.scheduleRebuild(full: self.viewing)
        }
        sweep.resume()
        sweepTimer = sweep

        // Agents disappear without a file event when they crash; a cheap look every 20 s while any exist.
        let agents = DispatchSource.makeTimerSource(queue: queue)
        agents.schedule(deadline: .now() + 20, repeating: 20, leeway: .seconds(5))
        agents.setEventHandler { [weak self] in
            guard let self, self.running, !self.lastSnapshot.agents.isEmpty else { return }
            self.rebuild(full: false)
        }
        agents.resume()
        agentTimer = agents
    }

    // MARK: Snapshots (queue)

    private func scheduleRebuild(full: Bool) {
        guard !rebuildPending else { return }
        rebuildPending = true
        // Full rollups at most every 1.5 s while you watch; agents-only updates are cheap.
        let wait = full ? max(0.4, 1.5 - Date().timeIntervalSince(lastFullBuild)) : 0.4
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.rebuildPending = false
            self.rebuild(full: full || self.viewing)
        }
    }

    private func rebuild(full: Bool) {
        let claudeRoots = ingestors.first { $0.provider == .claude }?.roots ?? []
        let agents = ClaudeAgents.read(db: db, projectRoots: claudeRoots)
        var snapshot: AIUsageSnapshot
        if full || lastSnapshot.generated == .distantPast {
            AIPricing.reloadOverridesIfNeeded()
            let detected = Set(ingestors.filter { !$0.roots.isEmpty }.map(\.provider))
            snapshot = AIUsageAggregator.build(db: db, detected: detected, live: live, agents: agents, extra: extra)
            lastFullBuild = Date()
        } else {
            // Agents only: keep the last rollup, refresh who's running (with last known session totals).
            snapshot = lastSnapshot
            let previous = Dictionary(lastSnapshot.agents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            snapshot.agents = agents.map { agent in
                var a = agent
                if let old = previous[a.id] {
                    a.sessionTokens = old.sessionTokens; a.sessionCost = old.sessionCost
                    a.currentPrompt = old.currentPrompt
                }
                if let id = a.sessionID, let task = db.tasks.values.filter({ $0.sessionID == id }).max(by: { $0.start < $1.start }) {
                    a.currentPrompt = task.prompt
                }
                return a
            } + lastSnapshot.agents.filter { $0.provider != .claude }
        }
        lastSnapshot = snapshot
        DispatchQueue.main.async { [weak self] in self?.onSnapshot?(snapshot) }
    }
}
