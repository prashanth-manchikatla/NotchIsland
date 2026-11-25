//
//  ScreenCapturePermission.swift
//  NotchIsland
//
//  CGPreflightScreenCaptureAccess() is unreliable on macOS 15+ for apps that
//  aren't Developer-ID signed: it can report `false` even when Screen Recording
//  is switched on. The real test is whether ScreenCaptureKit hands us content,
//  so probe that (cheap, and cached for a minute).
//

import Foundation
import ScreenCaptureKit

@MainActor
enum ScreenCapturePermission {
    private static var cached: Bool?
    private static var checkedAt: Date = .distantPast
    private static var probing = false
    static private(set) var lastError: String?

    /// Best current knowledge (kicks off a background probe when stale).
    static var isGranted: Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if Date().timeIntervalSince(checkedAt) > 60 { Task { await probe() } }
        return cached ?? false
    }

    @discardableResult
    static func probe() async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            cached = true
            checkedAt = Date()
            return true
        }
        guard !probing else { return cached ?? false }
        probing = true
        defer { probing = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            cached = !content.displays.isEmpty
            lastError = nil
        } catch {
            cached = false
            lastError = (error as NSError).localizedDescription
        }
        checkedAt = Date()
        NotificationCenter.default.post(name: .screenCapturePermissionChanged, object: nil)
        return cached ?? false
    }
}

extension Notification.Name {
    static let screenCapturePermissionChanged = Notification.Name("NotchIsland.screenCapturePermissionChanged")
}
