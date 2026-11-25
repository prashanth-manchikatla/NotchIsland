//
//  IslandSettings.swift
//  NotchIsland
//
//  All preference keys added by NotchIsland on top of boring.notch.
//

import AppKit
import Defaults
import SwiftUI

// MARK: - Appearance

enum IslandGlassStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
    case blackGlass = "Black glass"
    case liquidGlass = "Liquid Glass"
    case solid = "Solid black"
    var id: String { rawValue }
}

enum IslandBlurStrength: String, CaseIterable, Identifiable, Defaults.Serializable {
    case off = "Off"
    case soft = "Soft"
    case strong = "Strong"
    var id: String { rawValue }

    var material: NSVisualEffectView.Material {
        switch self {
        case .off, .soft: return .popover
        case .strong: return .hudWindow
        }
    }
}

enum IslandMotionStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
    case iPhone = "iPhone (bouncy)"
    case smooth = "Smooth"
    case snappy = "Snappy"
    var id: String { rawValue }

    var open: Animation {
        switch self {
        case .iPhone: return .spring(response: 0.46, dampingFraction: 0.74, blendDuration: 0)
        case .smooth: return .spring(response: 0.42, dampingFraction: 0.86, blendDuration: 0)
        case .snappy: return .spring(response: 0.30, dampingFraction: 0.82, blendDuration: 0)
        }
    }

    var close: Animation {
        switch self {
        case .iPhone: return .spring(response: 0.40, dampingFraction: 0.86, blendDuration: 0)
        case .smooth: return .spring(response: 0.42, dampingFraction: 1.0, blendDuration: 0)
        case .snappy: return .spring(response: 0.28, dampingFraction: 0.95, blendDuration: 0)
        }
    }

    /// Used for hover "lift", proximity growth and compact live-activity changes.
    var interactive: Animation {
        switch self {
        case .iPhone: return .interactiveSpring(response: 0.36, dampingFraction: 0.72, blendDuration: 0)
        case .smooth: return .interactiveSpring(response: 0.38, dampingFraction: 0.85, blendDuration: 0)
        case .snappy: return .interactiveSpring(response: 0.26, dampingFraction: 0.8, blendDuration: 0)
        }
    }
}

// MARK: - Capture

enum RecordingQuality: String, CaseIterable, Identifiable, Defaults.Serializable {
    case standard = "30 fps"
    case smooth = "60 fps"
    var id: String { rawValue }
    var fps: Int { self == .smooth ? 60 : 30 }
}

extension Defaults.Keys {
    // MARK: Island appearance
    static let islandGlassStyle = Key<IslandGlassStyle>("islandGlassStyle", default: .blackGlass)
    /// Black tint over the blurred backdrop while the island is expanded (0 = clear glass, 1 = solid black).
    static let islandExpandedOpacity = Key<Double>("islandExpandedOpacity", default: 0.74)
    /// Black tint of the compact pill. 1.0 blends perfectly with the camera housing.
    static let islandCompactOpacity = Key<Double>("islandCompactOpacity", default: 1.0)
    static let islandBlurStrength = Key<IslandBlurStrength>("islandBlurStrength", default: .strong)
    static let islandGlassRim = Key<Bool>("islandGlassRim", default: true)
    static let islandMotionStyle = Key<IslandMotionStyle>("islandMotionStyle", default: .iPhone)

    // MARK: Island behaviour
    /// The pill grows a little as the pointer approaches the notch.
    static let islandProximityGrow = Key<Bool>("islandProximityGrow", default: true)
    /// Pushing the pointer against the top edge near the notch opens the island immediately.
    static let islandTopEdgeOpen = Key<Bool>("islandTopEdgeOpen", default: true)
    /// Extra distance (points) around the notch that counts as "near".
    static let islandProximityDistance = Key<Double>("islandProximityDistance", default: 70)
    /// Tabs you turned off in Settings › Island › Tabs (TabModel ids; Home is always shown).
    static let islandHiddenTabs = Key<[String]>("islandHiddenTabs", default: [])

    // MARK: Awake (keep the Mac awake)
    static let awakeKeepDisplayOn = Key<Bool>("awakeKeepDisplayOn", default: true)
    static let awakeShowPill = Key<Bool>("awakeShowPill", default: true)
    static let awakeShowIndicator = Key<Bool>("awakeShowIndicator", default: true)
    static let awakeShowStopwatch = Key<Bool>("awakeShowStopwatch", default: true)
    static let awakeLidClosedDefault = Key<Bool>("awakeLidClosedDefault", default: false)
    static let awakeLowBatteryCutoff = Key<Int>("awakeLowBatteryCutoff", default: 15)
    /// Set while NotchIsland has disabled lid-close sleep, so it can be restored after a crash.
    static let awakeLidSleepDisabledByUs = Key<Bool>("awakeLidSleepDisabledByUs", default: false)

    // MARK: Clipboard
    static let clipboardEnabled = Key<Bool>("clipboardEnabled", default: true)
    static let clipboardHistoryLimit = Key<Int>("clipboardHistoryLimit", default: 60)
    static let clipboardIgnoreConcealed = Key<Bool>("clipboardIgnoreConcealed", default: true)
    static let clipboardDoubleCopyOpens = Key<Bool>("clipboardDoubleCopyOpens", default: true)
    static let clipboardShowCopyPill = Key<Bool>("clipboardShowCopyPill", default: false)
    static let clipboardPasteOnSelect = Key<Bool>("clipboardPasteOnSelect", default: false)
    static let clipboardIgnoredApps = Key<[String]>("clipboardIgnoredApps", default: [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.apple.keychainaccess", "com.apple.Passwords",
    ])

    // MARK: Capture
    static let captureSaveFolder = Key<String>("captureSaveFolder", default: "~/Desktop")
    static let captureCopyToClipboard = Key<Bool>("captureCopyToClipboard", default: true)
    static let captureAddToShelf = Key<Bool>("captureAddToShelf", default: true)
    static let capturePlaySound = Key<Bool>("capturePlaySound", default: true)
    static let recordSystemAudio = Key<Bool>("recordSystemAudio", default: false)
    static let recordMicrophone = Key<Bool>("recordMicrophone", default: false)
    static let recordShowClicks = Key<Bool>("recordShowClicks", default: true)
    static let recordQuality = Key<RecordingQuality>("recordQuality", default: .smooth)
    static let recordCountdown = Key<Bool>("recordCountdown", default: true)

    // MARK: Notifications & iPhone
    static let mirrorNotifications = Key<Bool>("mirrorNotifications", default: true)
    static let notificationBannerSeconds = Key<Double>("notificationBannerSeconds", default: 5)
    static let notificationsOnlyFromIPhone = Key<Bool>("notificationsOnlyFromIPhone", default: false)
    static let mutedNotificationApps = Key<[String]>("mutedNotificationApps", default: [])
    /// Clearing a notification in the island also clears it in Notification Center.
    static let clearNotificationsInCenter = Key<Bool>("clearNotificationsInCenter", default: true)
    static let orderTrackingEnabled = Key<Bool>("orderTrackingEnabled", default: true)
    static let orderTrackingExtraKeywords = Key<[String]>("orderTrackingExtraKeywords", default: [])
    static let iPhoneLiveActivitiesEnabled = Key<Bool>("iPhoneLiveActivitiesEnabled", default: true)

    // MARK: Timer & stopwatch
    static let timerPlaySound = Key<Bool>("timerPlaySound", default: true)
    static let timerLastMinutes = Key<Int>("timerLastMinutes", default: 5)

    // MARK: Devices
    static let showBluetoothIsland = Key<Bool>("showBluetoothIsland", default: true)
    static let showAudioOutputIsland = Key<Bool>("showAudioOutputIsland", default: true)

    // MARK: Calendar
    static let calendarUpcomingActivity = Key<Bool>("calendarUpcomingActivity", default: true)
    static let calendarUpcomingLeadMinutes = Key<Int>("calendarUpcomingLeadMinutes", default: 10)
}

// MARK: - Shared helpers

enum IslandPaths {
    static let appSupportPath: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("NotchIsland", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("NotchIsland", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var captureFolder: URL {
        let raw = (Defaults[.captureSaveFolder] as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: raw, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

extension Notification.Name {
    /// Posted to ask every notch to open on a specific tab (object: NotchViews).
    static let islandOpenTab = Notification.Name("NotchIsland.openTab")
}
