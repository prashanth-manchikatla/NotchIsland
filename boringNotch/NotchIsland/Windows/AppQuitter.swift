//
//  AppQuitter.swift
//  NotchIsland
//
//  Quit apps from the island — one at a time or all at once. Quitting is the
//  normal, polite kind (like ⌘Q): apps with unsaved work ask first. NotchIsland
//  itself and Finder are never included. The island tells you what happened.
//

import AppKit
import SwiftUI

struct RunningAppInfo: Identifiable, Equatable {
    let id: pid_t
    let name: String
    let bundleID: String?
    let isHidden: Bool
    let isActive: Bool
}

@MainActor
final class AppQuitter: ObservableObject {
    static let shared = AppQuitter()

    @Published private(set) var apps: [RunningAppInfo] = []
    /// Asked to quit but still open (usually waiting on a "Save changes?" dialog).
    @Published private(set) var waiting: [RunningAppInfo] = []
    @Published private(set) var isQuitting = false
    private var observers: [Any] = []

    private static let keep: Set<String> = ["com.apple.finder"]

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppQuitter.shared.refresh() }
            })
        }
        refresh()
    }

    func refresh() {
        let list = NSWorkspace.shared.runningApplications
            .filter { app in
                app.activationPolicy == .regular && !app.isTerminated && app.processIdentifier != getpid()
                    && !Self.keep.contains(app.bundleIdentifier ?? "")
            }
            .map { RunningAppInfo(id: $0.processIdentifier, name: $0.localizedName ?? $0.bundleIdentifier ?? "App",
                                  bundleID: $0.bundleIdentifier, isHidden: $0.isHidden, isActive: $0.isActive) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if list != apps { withAnimation(.smooth) { apps = list } }
        let alive = Set(list.map(\.id))
        let stillWaiting = waiting.filter { alive.contains($0.id) }
        if stillWaiting != waiting { withAnimation(.smooth) { waiting = stillWaiting } }
    }

    func quit(_ app: RunningAppInfo) {
        NSRunningApplication(processIdentifier: app.id)?.terminate()
    }

    /// Quits every app except NotchIsland (and Finder), then reports back in the island.
    func quitAll() {
        let targets = apps
        guard !targets.isEmpty, !isQuitting else { return }
        isQuitting = true
        IslandActivityHub.shared.showPill(.info(symbol: "xmark.app.fill",
                                                text: "Quitting \(targets.count) app\(targets.count == 1 ? "" : "s") — NotchIsland stays open",
                                                tint: .orange), duration: 3)
        for app in targets { NSRunningApplication(processIdentifier: app.id)?.terminate() }
        Task { @MainActor in
            // Give apps a moment to close (or to show their save dialogs).
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(500))
                if targets.allSatisfy({ NSRunningApplication(processIdentifier: $0.id)?.isTerminated ?? true }) { break }
            }
            let open = targets.filter { !(NSRunningApplication(processIdentifier: $0.id)?.isTerminated ?? true) }
            withAnimation(.smooth) { waiting = open }
            isQuitting = false
            refresh()
            let closed = targets.count - open.count
            let text = open.isEmpty
                ? "Closed \(closed) app\(closed == 1 ? "" : "s")"
                : "Closed \(closed) · \(open.count) waiting (\(open.map(\.name).prefix(2).joined(separator: ", ")))"
            IslandActivityHub.shared.showPill(.info(symbol: open.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                                                    text: text, tint: open.isEmpty ? .green : .orange), duration: 4)
        }
    }

    /// For apps stuck after Quit (e.g. a dialog you don't want): force them closed.
    func forceQuitWaiting() {
        for app in waiting { NSRunningApplication(processIdentifier: app.id)?.forceTerminate() }
        withAnimation(.smooth) { waiting = [] }
    }
}
