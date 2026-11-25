//
//  IslandSettingsViews.swift
//  NotchIsland
//
//  Settings pages for everything NotchIsland adds.
//

import AVFoundation
import CoreBluetooth
import Defaults
import EventKit
import KeyboardShortcuts
import SwiftUI

private func footnote(_ text: String) -> some View {
    Text(text)
        .foregroundStyle(.secondary)
        .font(.caption)
        .multilineTextAlignment(.leading)
}

// MARK: - Island (look & feel)

struct IslandAppearanceSettings: View {
    @Default(.islandGlassStyle) private var style
    @Default(.islandExpandedOpacity) private var expandedOpacity
    @Default(.islandCompactOpacity) private var compactOpacity
    @Default(.islandBlurStrength) private var blur
    @Default(.islandMotionStyle) private var motion
    @Default(.minimumHoverDuration) private var hoverDelay
    @Default(.islandProximityDistance) private var proximityDistance
    @Default(.islandProximityGrow) private var proximityGrow
    @Default(.liveVideoFrame) private var liveVideoFrame
    @Default(.liveVideoFPS) private var liveVideoFPS

    var body: some View {
        Form {
            Section {
                GlassPreview(style: style, opacity: expandedOpacity, blur: blur)
                    .frame(height: 120)
                    .listRowInsets(EdgeInsets())
                Picker("Style", selection: $style) {
                    ForEach(IslandGlassStyle.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                if style != .solid {
                    LabeledSlider(title: "Expanded transparency", value: Binding(
                        get: { 1 - expandedOpacity }, set: { expandedOpacity = 1 - $0 }), range: 0...0.7, percent: true)
                    LabeledSlider(title: "Compact pill transparency", value: Binding(
                        get: { 1 - compactOpacity }, set: { compactOpacity = 1 - $0 }), range: 0...0.6, percent: true)
                    Picker("Blur", selection: $blur) {
                        ForEach(IslandBlurStrength.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Defaults.Toggle("Glass rim highlight", key: .islandGlassRim)
                }
                Defaults.Toggle("Shadow", key: .enableShadow)
            } header: {
                Text("Black glass")
            } footer: {
                footnote("Transparency lets your wallpaper glow through the island like smoked glass. Keep the compact pill at 0% so it blends with the camera housing, just like iPhone. Liquid Glass uses macOS 26's system glass.")
            }

            Section {
                Picker("Motion", selection: $motion) {
                    ForEach(IslandMotionStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                Defaults.Toggle("Open on hover", key: .openNotchOnHover)
                LabeledSlider(title: "Hover delay", value: $hoverDelay, range: 0...0.6, step: 0.02, unit: "s")
                Defaults.Toggle("Grow when the pointer comes near", key: .islandProximityGrow)
                if proximityGrow {
                    LabeledSlider(title: "Reach", value: $proximityDistance, range: 30...160, step: 5, unit: "pt")
                }
                Defaults.Toggle("Open instantly when the pointer hits the top edge at the notch", key: .islandTopEdgeOpen)
                Defaults.Toggle("Haptic feedback", key: .enableHaptics)
            } header: {
                Text("Opening & motion")
            } footer: {
                footnote("Fastest way to open: flick the pointer straight up into the notch. Two-finger swipe down on the notch also opens it; swipe up closes it.")
            }

            Section {
                Defaults.Toggle("Play the video itself in the artwork (YouTube, IINA, VLC, QuickTime…)", key: .liveVideoEnabled)
                Picker("Video frame", selection: $liveVideoFrame) {
                    ForEach(LiveVideoFrame.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Video frame rate", selection: $liveVideoFPS) {
                    Text("15 fps (lighter)").tag(15)
                    Text("30 fps").tag(30)
                    Text("60 fps (smoothest)").tag(60)
                }
            } header: {
                Text("Live video")
            } footer: {
                footnote("When a video is playing, the island finds the moving player area in that app's window and plays it live where the thumbnail is. It runs only while the island is open on Home and needs Screen Recording. DRM-protected streams (Netflix, Prime, Apple TV+) appear black — that's macOS protecting them.")
            }

            Section {
                Defaults.Toggle("Show volume & brightness in the island (replaces macOS HUD)", key: .hudReplacement)
                Defaults.Toggle("Inline HUD (inside the pill, iPhone style)", key: .inlineHUD)
                Defaults.Toggle("Track title peek on song change", key: .enableSneakPeek)
                Defaults.Toggle("Show on lock screen", key: .showOnLockScreen)
                Defaults.Toggle("Hide the island from screenshots & screen sharing", key: .hideFromScreenRecording)
            } header: {
                Text("Island behaviour")
            }

            IslandTabsSection()
        }
        .formStyle(.grouped)
        .navigationTitle("Island")
    }
}

/// Settings › Island › Tabs: turn off tabs you don't use (the others get more room beside the notch).
private struct IslandTabsSection: View {
    @Default(.islandHiddenTabs) private var hidden

    var body: some View {
        Section {
            ForEach(tabs.filter { $0.view != .home }) { tab in
                Toggle(isOn: Binding(
                    get: { !hidden.contains(tab.id) },
                    set: { on in
                        if on { hidden.removeAll { $0 == tab.id } } else if !hidden.contains(tab.id) { hidden.append(tab.id) }
                    })) {
                    Label(tab.label, systemImage: tab.icon)
                }
            }
        } header: {
            Text("Tabs")
        } footer: {
            footnote("Home is always there. Tabs share the space left of the notch, so hiding the ones you don't use gives the rest more room. The Shelf tab also needs the shelf turned on.")
        }
    }
}

/// A sample of the island over a colourful backdrop so transparency is visible.
private struct GlassPreview: View {
    let style: IslandGlassStyle
    let opacity: Double
    let blur: IslandBlurStrength

    var body: some View {
        ZStack {
            LinearGradient(colors: [.purple, .blue, .teal, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 14) {
                ForEach(0..<6) { i in
                    Image(systemName: ["music.note", "calendar", "star.fill", "heart.fill", "bolt.fill", "leaf.fill"][i])
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            ZStack {
                if style != .solid && blur != .off {
                    Rectangle().fill(blur == .strong ? .ultraThinMaterial : .ultraThinMaterial)
                        .environment(\.colorScheme, .dark)
                        .opacity(blur == .strong ? 1 : 0.6)
                }
                Color.black.opacity(style == .solid ? 1 : opacity)
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 6).fill(LinearGradient(colors: [.orange, .pink], startPoint: .top, endPoint: .bottom))
                        .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Now Playing").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        Text("Artist").font(.system(size: 11)).foregroundStyle(.gray)
                    }
                    Spacer()
                    Image(systemName: "pause.fill").foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
            }
            .frame(width: 300, height: 62)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(style == .solid ? 0 : 0.18), lineWidth: 1))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var percent = false
    var unit = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(percent ? "\(Int((value * 100).rounded()))%" : String(format: unit == "s" ? "%.2f%@" : "%.0f %@", value, unit))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let step {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
        }
    }
}

// MARK: - Awake

struct AwakeSettings: View {
    @ObservedObject private var awake = AwakeManager.shared
    @Default(.awakeLowBatteryCutoff) private var cutoff

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: awake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .foregroundStyle(awake.isActive ? .orange : .secondary)
                    Text(awake.isActive ? "Keeping your Mac awake · \(awake.remainingText)" : "Off")
                    Spacer()
                    Button(awake.isActive ? "Turn Off" : "Turn On") { awake.toggle() }
                }
                KeyboardShortcuts.Recorder("Toggle shortcut:", name: .toggleAwake)
            } footer: {
                footnote("In the island: click the cup to toggle, click-and-hold (or right-click) for 15 min … 8 h, “until” a time, or indefinitely.")
            }
            Section {
                Defaults.Toggle("Keep the display on (not just the Mac)", key: .awakeKeepDisplayOn)
                Defaults.Toggle("Show a brief island when Awake turns on or off", key: .awakeShowPill)
                Defaults.Toggle("Show the cup in the island while Awake is on", key: .awakeShowIndicator)
                Defaults.Toggle("Show the stopwatch next to Awake", key: .awakeShowStopwatch)
            } header: { Text("Behaviour") }
            Section {
                Toggle("Stay awake with the lid closed", isOn: Binding(
                    get: { awake.lidClosedMode },
                    set: { on in Task { await awake.setLidClosedMode(on) } }))
                    .disabled(awake.isChangingLidMode)
                Defaults.Toggle("Turn this on whenever Awake starts", key: .awakeLidClosedDefault)
                LabeledSlider(title: "Stop on battery at", value: Binding(
                    get: { Double(cutoff) }, set: { cutoff = Int($0) }), range: 0...50, step: 5, unit: "%")
            } header: {
                Text("Lid closed")
            } footer: {
                footnote("Lid-closed mode runs `pmset disablesleep` and asks for your administrator password. It is switched back automatically when Awake ends, when the battery hits the cut-off, and on next launch after a crash. Don't put a running MacBook in a bag.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Awake")
    }
}

// MARK: - Clipboard

struct ClipboardSettings: View {
    @Default(.clipboardHistoryLimit) private var limit
    @Default(.clipboardIgnoredApps) private var ignoredApps
    @ObservedObject private var clipboard = ClipboardManager.shared

    var body: some View {
        Form {
            Section {
                Defaults.Toggle("Keep clipboard history", key: .clipboardEnabled)
                LabeledSlider(title: "History size", value: Binding(
                    get: { Double(limit) }, set: { limit = Int($0) }), range: 20...200, step: 10, unit: "items")
                KeyboardShortcuts.Recorder("Open clipboard:", name: .openClipboard)
                Defaults.Toggle("Press ⌘C twice to open the clipboard", key: .clipboardDoubleCopyOpens)
                Defaults.Toggle("Clicking an item pastes it into the front app", key: .clipboardPasteOnSelect)
                Defaults.Toggle("Flash the island when something is copied", key: .clipboardShowCopyPill)
                Defaults.Toggle("Clean links: remove tracking (utm_, fbclid, si…) when you copy a link", key: .clipboardCleanLinks)
                KeyboardShortcuts.Recorder("Paste as plain text:", name: .pastePlainText)
            } footer: {
                footnote("⌘C ⌘C and paste-on-click need Accessibility. History is stored only on this Mac (Application Support/NotchIsland).")
            }
            Section {
                Defaults.Toggle("Ignore passwords and concealed items", key: .clipboardIgnoreConcealed)
                ForEach(ignoredApps, id: \.self) { bundleID in
                    HStack {
                        if let icon = AppIconAsNSImage(for: bundleID) {
                            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                        }
                        Text(bundleID).font(.callout)
                        Spacer()
                        Button(role: .destructive) { ignoredApps.removeAll { $0 == bundleID } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Ignore an app…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.application]
                    panel.directoryURL = URL(fileURLWithPath: "/Applications")
                    if panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier, !ignoredApps.contains(id) {
                        ignoredApps.append(id)
                    }
                }
            } header: { Text("Privacy") }
            Section {
                Button("Clear history (\(clipboard.items.count) items, keeps pinned)", role: .destructive) {
                    clipboard.clear(keepPinned: true)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Clipboard")
    }
}

// MARK: - Capture

struct CaptureSettings: View {
    @Default(.captureSaveFolder) private var folder
    @Default(.recordQuality) private var quality

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Save to")
                    Spacer()
                    Text((folder as NSString).abbreviatingWithTildeInPath).foregroundStyle(.secondary)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
                    }
                }
                Defaults.Toggle("Copy to clipboard", key: .captureCopyToClipboard)
                Defaults.Toggle("Add to the Shelf", key: .captureAddToShelf)
                Defaults.Toggle("Play shutter sound", key: .capturePlaySound)
            } header: { Text("Screenshots & recordings") }
            Section {
                Picker("Frame rate", selection: $quality) {
                    ForEach(RecordingQuality.allCases) { Text($0.rawValue).tag($0) }
                }
                Defaults.Toggle("Record system audio", key: .recordSystemAudio)
                Defaults.Toggle("Record microphone", key: .recordMicrophone)
                Defaults.Toggle("Show clicks", key: .recordShowClicks)
                Defaults.Toggle("3-2-1 countdown", key: .recordCountdown)
            } header: {
                Text("Screen recording")
            } footer: {
                footnote("While recording, the island shows a red dot and timer — click the timer to stop. Recordings are HEVC .mov files; NotchIsland itself is kept out of the video.")
            }
            Section {
                KeyboardShortcuts.Recorder("Screenshot selection:", name: .screenshotSelection)
                KeyboardShortcuts.Recorder("Screenshot full screen:", name: .screenshotFullScreen)
                KeyboardShortcuts.Recorder("Record selection:", name: .recordSelection)
                KeyboardShortcuts.Recorder("Start/stop full-screen recording:", name: .toggleScreenRecording)
                KeyboardShortcuts.Recorder("Copy text from the screen:", name: .copyTextFromScreen)
                KeyboardShortcuts.Recorder("Pick a colour from the screen:", name: .pickColorFromScreen)
            } header: { Text("Shortcuts") }
        }
        .formStyle(.grouped)
        .navigationTitle("Capture")
    }
}

// MARK: - iPhone & notifications

struct IPhoneNotificationSettings: View {
    @ObservedObject private var mirror = NotificationMirror.shared
    @ObservedObject private var live = IPhoneLiveActivityMirror.shared
    @ObservedObject private var orders = OrderTracker.shared
    @Default(.notificationBannerSeconds) private var bannerSeconds
    @Default(.mutedNotificationApps) private var mutedApps
    @Default(.orderTrackingExtraKeywords) private var extraKeywords
    @State private var newMuted = ""
    @State private var newKeyword = ""
    @State private var diagnosticsURL: URL?

    var body: some View {
        Form {
            Section {
                PermissionRow(title: "Accessibility", granted: AXIsProcessTrusted(),
                              detail: "Required to read notifications and menu-bar Live Activities.") {
                    XPCHelperClient.shared.requestAccessibilityAuthorization()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            } footer: {
                footnote("On your iPhone: keep iPhone Mirroring set up. On this Mac: System Settings › Notifications › “Allow notifications from iPhone”, and Control Center › “Live Activities from iPhone” (menu bar). NotchIsland mirrors both into the island.")
            }
            Section {
                Defaults.Toggle("Show Live Activities from iPhone in the island", key: .iPhoneLiveActivitiesEnabled)
                if !live.activities.isEmpty {
                    ForEach(live.activities) { activity in
                        Label("\(activity.appName ?? "iPhone") — \(activity.title)", systemImage: "iphone.gen3")
                    }
                }
                Defaults.Toggle("Track orders, deliveries & rides from notifications", key: .orderTrackingEnabled)
                ForEach(orders.orders) { order in
                    Label("\(order.appName): \(order.stage.label)", systemImage: OrderTracker.symbol(for: order.category))
                }
                HStack {
                    TextField("Extra keyword or app to treat as an order", text: $newKeyword)
                    Button("Add") {
                        let k = newKeyword.trimmingCharacters(in: .whitespaces)
                        if !k.isEmpty, !extraKeywords.contains(k) { extraKeywords.append(k) }
                        newKeyword = ""
                    }
                }
                if !extraKeywords.isEmpty {
                    Text(extraKeywords.joined(separator: ", ")).foregroundStyle(.secondary).font(.callout)
                    Button("Clear extra keywords") { extraKeywords = [] }
                }
            } header: {
                Text("iPhone Live Activities & orders")
            } footer: {
                footnote("Swiggy, Zomato, Blinkit, Zepto, Instamart, BigBasket, Uber, Ola, Rapido, Amazon, Flipkart, DoorDash, Uber Eats and many more are recognised automatically, with stage and live ETA.")
            }
            Section {
                Defaults.Toggle("Mirror notifications into the island", key: .mirrorNotifications)
                Defaults.Toggle("Only show notifications from iPhone (and orders)", key: .notificationsOnlyFromIPhone)
                LabeledSlider(title: "Banner duration", value: $bannerSeconds, range: 2...12, step: 1, unit: "s")
                HStack {
                    TextField("Mute an app (exact name)", text: $newMuted)
                    Button("Mute") {
                        let k = newMuted.trimmingCharacters(in: .whitespaces)
                        if !k.isEmpty, !mutedApps.contains(k) { mutedApps.append(k) }
                        newMuted = ""
                    }
                }
                ForEach(mutedApps, id: \.self) { app in
                    HStack {
                        Text(app)
                        Spacer()
                        Button { mutedApps.removeAll { $0 == app } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Text(mirror.isActive ? "Listening for notifications ✓" : "Not listening (Accessibility off or mirroring disabled)")
                    .foregroundStyle(mirror.isActive ? .green : .secondary)
                    .font(.callout)
            } header: { Text("Notifications") }
            Section {
                Button("Export diagnostics…") {
                    live.refresh()
                    let url = live.exportDiagnostics()
                    diagnosticsURL = url
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                if let diagnosticsURL {
                    Text("Saved to \((diagnosticsURL.path as NSString).abbreviatingWithTildeInPath)").font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Troubleshooting")
            } footer: {
                footnote("Run this while a Live Activity (e.g. an iPhone timer or a food order) is showing in the menu bar. The file lists what macOS exposes so recognition can be tuned. It stays on this Mac.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("iPhone & Notifications")
    }
}

// MARK: - Live activities (timer, calendar, devices)

struct LiveActivitySettings: View {
    @Default(.calendarUpcomingLeadMinutes) private var lead

    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Open Notifications:", name: .openLiveTab)
                Defaults.Toggle("Play a sound when a timer ends", key: .timerPlaySound)
            } header: { Text("Timer & stopwatch") }
            Section {
                Defaults.Toggle("Show the next meeting as a Live Activity", key: .calendarUpcomingActivity)
                LabeledSlider(title: "Show it before the start", value: Binding(
                    get: { Double(lead) }, set: { lead = Int($0) }), range: 1...30, step: 1, unit: "min")
            } header: {
                Text("Calendar")
            } footer: {
                footnote("Zoom, Google Meet, Teams, Webex and FaceTime links get a one-click Join button.")
            }
            Section {
                Defaults.Toggle("AirPods & Bluetooth devices connecting (with battery)", key: .showBluetoothIsland)
                Defaults.Toggle("Audio output changes", key: .showAudioOutputIsland)
                Defaults.Toggle("Charging & battery", key: .showPowerStatusNotifications)
            } header: { Text("Device islands") }
        }
        .formStyle(.grouped)
        .navigationTitle("Live Activities")
    }
}

// MARK: - Permissions overview

struct PermissionsSettings: View {
    @State private var refresh = UUID()

    var body: some View {
        Form {
            Section {
                PermissionRow(title: "Accessibility", granted: AXIsProcessTrusted(),
                              detail: "Notifications, iPhone Live Activities, HUD, ⌘C ⌘C, paste") {
                    XPCHelperClient.shared.requestAccessibilityAuthorization()
                    open("Privacy_Accessibility")
                }
                PermissionRow(title: "Screen Recording", granted: ScreenCapturePermission.isGranted,
                              detail: "Screenshots and screen recordings") {
                    _ = CGRequestScreenCaptureAccess()
                    open("Privacy_ScreenCapture")
                }
                PermissionRow(title: "Calendars", granted: Self.calendarGranted,
                              detail: "Agenda and next-meeting Live Activity") {
                    Task {
                        _ = try? await EKEventStore().requestFullAccessToEvents()
                        refresh = UUID()
                    }
                }
                PermissionRow(title: "Camera", granted: AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
                              detail: "Mirror") {
                    AVCaptureDevice.requestAccess(for: .video) { _ in }
                }
                PermissionRow(title: "Bluetooth", granted: CBManager.authorization == .allowedAlways,
                              detail: "AirPods connect island") {
                    open("Privacy_Bluetooth")
                }
            } footer: {
                footnote("After allowing Accessibility or Screen Recording, macOS may ask you to quit and reopen NotchIsland. Use the menu bar icon › Restart NotchIsland.")
            }
            .id(refresh)
            Section {
                Button("Refresh") { refresh = UUID() }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Permissions")
    }

    private static var calendarGranted: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    private func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct PermissionRow: View {
    let title: String
    let granted: Bool
    let detail: String
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Allow…", action: action)
            }
        }
    }
}
