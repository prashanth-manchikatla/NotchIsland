//
//  HoverbirdBootstrap.swift
//  Hoverbird
//
//  Starts Hoverbird's services at launch. Every service is event-driven or
//  uses a single low-frequency timer, so idle CPU stays near zero.
//

import AppKit
import Defaults
import KeyboardShortcuts
import ServiceManagement

@MainActor
enum HoverbirdBootstrap {
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true

        // Instantiate the services (each wires itself to its settings).
        _ = ProximityMonitor.shared
        _ = IslandInteractionLock.shared
        _ = ClipboardManager.shared
        _ = NotificationMirror.shared
        _ = IPhoneLiveActivityMirror.shared
        _ = OrderTracker.shared
        UpcomingEventMonitor.shared.evaluate()
        _ = IslandActivityHub.shared
        // AirPods / accessory batteries: event-driven (system power-source notifications).
        BluetoothBatteryMonitor.shared.start()
        // Header connectivity icon: event-driven network path + Wi-Fi change events.
        ConnectivityMonitor.shared.start()
        WindowTiler.shared.start()     // remembers the app you were in, for snapping
        _ = AppQuitter.shared
        // Live CPU readout in the closed island, if it was left on.
        if Defaults[.monitorInIsland] { SystemMonitor.shared.startIfNeeded() }
        // AI Usage: reads the AI tools' local logs (FSEvents-driven; idle when you're not using AI).
        AIUsageStore.shared.start()
        // Meeting kit: mic mute + "camera / mic in use" (CoreAudio / CoreMediaIO listeners, no polling).
        MicCameraMonitor.shared.start()
        _ = FocusManager.shared // eye-break reminders, if on
        BatteryAlerts.shared.start()
        CinemaMode.shared.start()     // full-screen video: quiet island, held banners, picture mode
        CinemaNowPlaying.shared.start() // streaming pages' title, episode, picture and time
        DownloadsWatcher.shared.start()
        DrivesMonitor.shared.start()

        IslandMemory.trimSoon(after: 25) // after startup work settles
        // On the very first launch, wait so the Bluetooth permission prompt
        // doesn't pop up on top of the onboarding window.
        if BoringViewCoordinator.shared.firstLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { DeviceMonitor.shared.start() }
        } else {
            DeviceMonitor.shared.start()
        }

        // Features that need Accessibility switch on by themselves once it's granted.
        if !AXIsProcessTrusted() {
            XPCHelperClient.shared.startMonitoringAccessibilityAuthorization(every: 3)
        }
        restoreLostPermissions()

        registerShortcuts()
        enableLaunchAtLoginOnce()

        // Lets a local script ask Hoverbird to show the system permission prompts.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("app.hoverbird.mac.requestPermissions"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                XPCHelperClient.shared.requestAccessibilityAuthorization()
                XPCHelperClient.shared.startMonitoringAccessibilityAuthorization(every: 2)
                _ = CGRequestScreenCaptureAccess()
            }
        }

        // `hoverbird diagnostics`: lets a local script ask for a fresh diagnostics file
        // (written to ~/Library/Application Support/Hoverbird/diagnostics.txt).
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("app.hoverbird.mac.diagnostics"), object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                await ScreenCapturePermission.probe()
                IPhoneLiveActivityMirror.shared.refresh()
                _ = IPhoneLiveActivityMirror.shared.exportDiagnostics()
            }
        }

        // If a previous session left lid-close sleep disabled, offer to restore it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            AwakeManager.shared.recoverLidSleepIfNeeded()
        }
    }

    /// macOS ties privacy permissions to the exact build of an ad-hoc-signed app,
    /// so after an update they can silently drop. If a permission that used to be
    /// granted is gone, ask for it again right away instead of failing quietly.
    private static func restoreLostPermissions() {
        let defaults = UserDefaults.standard
        let axKey = "Hoverbird.axWasGranted", srKey = "Hoverbird.screenWasGranted"
        if AXIsProcessTrusted() {
            defaults.set(true, forKey: axKey)
        } else if defaults.bool(forKey: axKey) && !BoringViewCoordinator.shared.firstLaunch {
            XPCHelperClient.shared.requestAccessibilityAuthorization()
        }
        if CGPreflightScreenCaptureAccess() {
            defaults.set(true, forKey: srKey)
        } else if defaults.bool(forKey: srKey) && !BoringViewCoordinator.shared.firstLaunch {
            _ = CGRequestScreenCaptureAccess()
        }
        NotificationCenter.default.addObserver(forName: .accessibilityAuthorizationChanged, object: nil, queue: .main) { note in
            if (note.userInfo?["granted"] as? Bool) == true { UserDefaults.standard.set(true, forKey: axKey) }
        }
    }

    /// First run from /Applications: start Hoverbird automatically at login.
    /// (Toggle it any time in Settings › General › Launch at login.)
    private static func enableLaunchAtLoginOnce() {
        let key = "Hoverbird.loginItemConfigured"
        guard !UserDefaults.standard.bool(forKey: key),
              Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }

    private static func registerShortcuts() {
        let snaps: [(KeyboardShortcuts.Name, Tile)] = [
            (.snapLeft, TileLayouts.halves.tiles[0]), (.snapRight, TileLayouts.halves.tiles[1]),
            (.snapTop, TileLayouts.rows.tiles[0]), (.snapBottom, TileLayouts.rows.tiles[1]),
            (.snapFill, TileLayouts.fill.tiles[0]), (.snapLeftThird, TileLayouts.thirds.tiles[0]),
            (.snapCenterThird, TileLayouts.thirds.tiles[1]), (.snapRightThird, TileLayouts.thirds.tiles[2]),
        ]
        for (name, tile) in snaps {
            KeyboardShortcuts.onKeyDown(for: name) { WindowTiler.shared.snapFront(to: tile) }
        }
        KeyboardShortcuts.onKeyDown(for: .snapRestore) { WindowTiler.shared.restoreFront() }
        KeyboardShortcuts.onKeyDown(for: .openClipboard) {
            NotificationCenter.default.post(name: .islandOpenTab, object: NotchViews.clipboard)
        }
        KeyboardShortcuts.onKeyDown(for: .openLiveTab) {
            NotificationCenter.default.post(name: .islandOpenTab, object: NotchViews.notifications)
        }
        KeyboardShortcuts.onKeyDown(for: .toggleAwake) {
            AwakeManager.shared.toggle()
        }
        KeyboardShortcuts.onKeyDown(for: .screenshotSelection) {
            CaptureManager.shared.screenshot(.area)
        }
        KeyboardShortcuts.onKeyDown(for: .screenshotFullScreen) {
            CaptureManager.shared.screenshot(.fullScreen)
        }
        KeyboardShortcuts.onKeyDown(for: .toggleScreenRecording) {
            CaptureManager.shared.toggleRecording(.fullScreen)
        }
        KeyboardShortcuts.onKeyDown(for: .toggleMicMute) { MicCameraMonitor.shared.toggleMute() }
        KeyboardShortcuts.onKeyDown(for: .pastePlainText) { PlainTextPaste.paste() }
        KeyboardShortcuts.onKeyDown(for: .copyTextFromScreen) { ScreenTools.copyText() }
        KeyboardShortcuts.onKeyDown(for: .pickColorFromScreen) { ScreenTools.pickColor() }
        KeyboardShortcuts.onKeyDown(for: .recordSelection) {
            if CaptureManager.shared.isRecording {
                CaptureManager.shared.stopRecording()
            } else {
                CaptureManager.shared.startRecording(.area)
            }
        }
    }
}
