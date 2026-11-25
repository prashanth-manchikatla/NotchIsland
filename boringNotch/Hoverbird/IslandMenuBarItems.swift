//
//  IslandMenuBarItems.swift
//  Hoverbird
//
//  Extra items in the Hoverbird menu bar menu: Keep Awake, capture, timer.
//

import Defaults
import SwiftUI

struct IslandMenuBarItems: View {
    @ObservedObject private var awake = AwakeManager.shared
    @ObservedObject private var capture = CaptureManager.shared
    @ObservedObject private var timers = IslandTimerManager.shared
    @ObservedObject private var pin = IslandPinState.shared
    @ObservedObject private var mic = MicCameraMonitor.shared
    @ObservedObject private var drives = DrivesMonitor.shared

    var body: some View {
        Button(pin.pinned ? "📌 Unpin Island" : "Pin Island Open") {
            pin.toggle()
            if pin.pinned { NotificationCenter.default.post(name: .islandOpenTab, object: BoringViewCoordinator.shared.currentView) }
        }
        Menu("Lock") {
            Button("Lock Screen Now") { MacLock.shared.lockNow() }
            ForEach(MacLock.delays, id: \.self) { minutes in
                Button("Lock in \(minutes) min") { MacLock.shared.lock(afterMinutes: minutes) }
            }
            Divider()
            Button("Sleep Display") { MacLock.shared.sleepDisplay() }
            Button("Start Screen Saver") { MacLock.shared.startScreenSaver() }
        }
        Button(mic.isMuted ? "🎙 Unmute Microphone (⌃⌥M)" : "Mute Microphone (⌃⌥M)") { mic.toggleMute() }
        if !drives.drives.isEmpty {
            Menu("Eject") {
                ForEach(drives.drives, id: \.self) { url in
                    Button("Eject “\(DrivesMonitor.name(url))”") { drives.eject(url) }
                }
            }
        }
        Divider()
        Button(awake.isActive ? "☕️ Keep Awake: On (\(awake.remainingText)) — Turn Off" : "Keep Awake") {
            awake.toggle()
        }
        Menu("Keep Awake For") {
            Button("Indefinitely") { awake.start(minutes: nil) }
            ForEach(AwakeManager.presets, id: \.minutes) { preset in
                Button(preset.label) { awake.start(minutes: preset.minutes) }
            }
            Divider()
            Toggle("Keep display on", isOn: Binding(
                get: { Defaults[.awakeKeepDisplayOn] },
                set: { Defaults[.awakeKeepDisplayOn] = $0 }))
            Button(awake.lidClosedMode ? "Allow sleep with lid closed" : "Stay awake with lid closed…") {
                Task { await awake.setLidClosedMode(!awake.lidClosedMode) }
            }
        }
        Divider()
        Menu("Capture") {
            Button("Screenshot Selection") { capture.screenshot(.area) }
            Button("Screenshot Window") { capture.screenshot(.window) }
            Button("Screenshot Full Screen") { capture.screenshot(.fullScreen) }
            Divider()
            if capture.isRecording {
                Button("Stop Recording") { capture.stopRecording() }
            } else {
                Button("Record Selection") { capture.startRecording(.area) }
                Button("Record Full Screen") { capture.startRecording(.fullScreen) }
            }
        }
        Button("Camera Full Screen") { CameraFullScreen.shared.show() }
        Button("System Monitor…") { MonitorWindowController.shared.show() }
        Toggle("Show CPU in Island", isOn: Binding(get: { Defaults[.monitorInIsland] }, set: { Defaults[.monitorInIsland] = $0 }))
        Menu("Timers & Stopwatches") {
            Menu("Start a Timer") {
                ForEach(IslandTimerManager.presets, id: \.self) { minutes in
                    Button(IslandTimerManager.durationLabel(minutes: minutes)) { timers.startTimer(minutes: minutes) }
                }
            }
            ForEach(timers.timers) { timer in
                Menu("⏱ \(timer.label)\(timer.isPaused ? " (paused)" : timer.isRinging ? " (done)" : "")") {
                    if !timer.isRinging {
                        Button(timer.isRunning ? "Pause" : "Resume") { timers.togglePause(timer.id) }
                    }
                    Button("Add 1 Minute") { timers.addMinute(timer.id) }
                    Button(timer.isRinging ? "Stop" : "Cancel") { timers.remove(timer.id) }
                }
            }
            if timers.timers.count > 1 {
                Button("Cancel All Timers") { timers.cancelAllTimers() }
            }
            Divider()
            Button("New Stopwatch") { timers.addStopwatch() }
            ForEach(timers.stopwatches) { stopwatch in
                Menu(stopwatch.title) {
                    Button(stopwatch.isRunning ? "Pause" : "Start") { timers.toggleStopwatch(stopwatch.id) }
                    if stopwatch.isRunning { Button("Lap") { timers.lap(stopwatch.id) } }
                    Button("Reset") { timers.resetStopwatch(stopwatch.id) }
                    Button("Remove") { timers.removeStopwatch(stopwatch.id) }
                }
            }
        }
    }
}
