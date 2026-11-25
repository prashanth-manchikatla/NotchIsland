//
//  MicCameraMonitor.swift
//  Hoverbird · Meeting kit
//
//  • Mute the microphone for every app at once (Zoom, Meet, Teams, FaceTime…): ⌃⌥M, the menu
//    bar, or Settings. Uses the input device's own mute; devices without one get their input
//    volume set to 0 and restored on unmute (and when Hoverbird quits).
//  • Knows when any app is using the microphone or a camera (CoreAudio / CoreMediaIO
//    "running somewhere" — event-driven, no polling), so the closed island can show
//    "Muted" while you're in a call, and optionally a pill when a camera / mic turns on.
//

import AppKit
import Combine
import CoreAudio
import CoreMediaIO
import Defaults
import SwiftUI

extension Defaults.Keys {
    /// Red "Muted" in the closed island while an app is using the (muted) microphone.
    static let micMutedIndicator = Key<Bool>("micMutedIndicator", default: true)
    /// A pill when an app turns a camera on (not Hoverbird's own mirror).
    static let cameraInUsePill = Key<Bool>("cameraInUsePill", default: true)
    /// A pill when an app starts using the microphone.
    static let micInUsePill = Key<Bool>("micInUsePill", default: false)
}

@MainActor
final class MicCameraMonitor: ObservableObject {
    static let shared = MicCameraMonitor()

    @Published private(set) var isMuted = false
    @Published private(set) var micInUse = false
    @Published private(set) var cameraInUse = false
    @Published private(set) var inputName: String?

    private var device = AudioObjectID(kAudioObjectUnknown)
    /// Input volume before we muted a device that has no mute switch.
    private var savedVolume: Float32?
    private var deviceListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var cameraListeners: [(CMIOObjectID, CMIOObjectPropertyAddress, CMIOObjectPropertyListenerBlock)] = []
    private var started = false
    private var cameraChecked = false
    private var micChecked = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        var defaultInput = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultInput, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.attachToDefaultInput(keepMute: true) }
        }
        attachToDefaultInput(keepMute: false)
        watchCameras()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MicCameraMonitor.shared.restoreVolumeIfNeeded() }
        }
    }

    // MARK: Mute

    func toggleMute() { setMuted(!isMuted) }

    func setMuted(_ mute: Bool) {
        guard device != kAudioObjectUnknown else {
            IslandActivityHub.shared.showPill(.info(symbol: "mic.slash", text: "No microphone", tint: .orange), duration: 2)
            return
        }
        var ok = false
        var muteAddr = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput)
        if Self.isSettable(device, &muteAddr) {
            var value: UInt32 = mute ? 1 : 0
            ok = AudioObjectSetPropertyData(device, &muteAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
        } else if let channel = volumeElement(device) {
            var volAddr = Self.address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeInput, element: channel)
            if mute {
                savedVolume = Self.read(device, &volAddr, Float32(0.75))
                var zero: Float32 = 0
                ok = setVolume(&zero, channelOf: device)
            } else {
                var restore = savedVolume ?? 0.75
                ok = setVolume(&restore, channelOf: device)
                savedVolume = nil
            }
        }
        refreshMuteState()
        if ok {
            IslandActivityHub.shared.showPill(.info(symbol: mute ? "mic.slash.fill" : "mic.fill",
                                                    text: mute ? "Microphone muted" : "Microphone on",
                                                    tint: mute ? .red : .green), duration: 1.8)
        } else {
            IslandActivityHub.shared.showPill(.info(symbol: "mic.slash", text: "\(inputName ?? "This microphone") can't be muted", tint: .orange), duration: 2.4)
        }
    }

    private func restoreVolumeIfNeeded() {
        guard savedVolume != nil else { return }
        setMuted(false)
    }

    /// Sets the input volume on every channel that has one (some mics only expose L/R).
    private func setVolume(_ value: inout Float32, channelOf device: AudioObjectID) -> Bool {
        var done = false
        for element: UInt32 in [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = Self.address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeInput, element: element)
            if Self.isSettable(device, &addr),
               AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr {
                done = true
            }
        }
        return done
    }

    private func volumeElement(_ device: AudioObjectID) -> UInt32? {
        for element: UInt32 in [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = Self.address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeInput, element: element)
            if Self.isSettable(device, &addr) { return element }
        }
        return nil
    }

    // MARK: Default input device

    private func attachToDefaultInput(keepMute: Bool) {
        let wasMuted = isMuted
        for (id, addr, block) in deviceListeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(id, &a, .main, block)
        }
        deviceListeners.removeAll()
        var addr = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        device = Self.read(AudioObjectID(kAudioObjectSystemObject), &addr, AudioObjectID(kAudioObjectUnknown))
        inputName = Self.name(of: device)
        guard device != kAudioObjectUnknown else { micInUse = false; isMuted = false; return }

        let watched: [AudioObjectPropertyAddress] = [
            Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere),
            Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput),
            Self.address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeInput),
        ]
        for property in watched {
            var a = property
            guard AudioObjectHasProperty(device, &a) else { continue }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshMuteState(); self?.refreshMicInUse() }
            }
            if AudioObjectAddPropertyListenerBlock(device, &a, .main, block) == noErr {
                deviceListeners.append((device, property, block))
            }
        }
        refreshMuteState()
        refreshMicInUse()
        // You were muted on the old mic (e.g. AirPods connected mid-call): stay muted.
        if keepMute && wasMuted && !isMuted { setMuted(true) }
    }

    private func refreshMuteState() {
        var muteAddr = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput)
        let muted: Bool
        if AudioObjectHasProperty(device, &muteAddr) {
            muted = Self.read(device, &muteAddr, UInt32(0)) != 0
        } else if let element = volumeElement(device) {
            var volAddr = Self.address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeInput, element: element)
            muted = Self.read(device, &volAddr, Float32(1)) < 0.001
        } else {
            muted = false
        }
        if muted != isMuted { isMuted = muted }
    }

    private func refreshMicInUse() {
        var addr = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        let running = Self.read(device, &addr, UInt32(0)) != 0
        let first = !micChecked
        micChecked = true
        guard running != micInUse else { return }
        micInUse = running
        if running, !first, Defaults[.micInUsePill], !isMuted {
            IslandActivityHub.shared.showPill(.info(symbol: "mic.fill", text: "Microphone is on", tint: .orange), duration: 2.2)
        }
    }

    // MARK: Cameras

    private func watchCameras() {
        var listAddr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                                 mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                 mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        let refresh: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.rewatchCameras() }
        }
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &listAddr, .main, refresh)
        rewatchCameras()
    }

    private func rewatchCameras() {
        for (id, addr, block) in cameraListeners {
            var a = addr
            CMIOObjectRemovePropertyListenerBlock(id, &a, .main, block)
        }
        cameraListeners.removeAll()
        for camera in Self.cameraIDs() {
            var addr = Self.cameraRunningAddress
            let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshCameraInUse() }
            }
            if CMIOObjectAddPropertyListenerBlock(camera, &addr, .main, block) == noErr {
                cameraListeners.append((camera, Self.cameraRunningAddress, block))
            }
        }
        refreshCameraInUse()
    }

    private func refreshCameraInUse() {
        let running = Self.cameraIDs().contains { id in
            var addr = Self.cameraRunningAddress
            var value: UInt32 = 0
            var used: UInt32 = 0
            return CMIOObjectGetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value) == noErr && value != 0
        }
        // Hoverbird's own mirror counts as "in use" too — only tell you about other apps.
        let byOthers = running && !WebcamManager.shared.isSessionRunning
        let first = !cameraChecked
        cameraChecked = true
        guard byOthers != cameraInUse else { return }
        cameraInUse = byOthers
        // Only a change you'd want to know about — not "already on" when Hoverbird starts.
        if byOthers, !first, Defaults[.cameraInUsePill] {
            IslandActivityHub.shared.showPill(.info(symbol: "video.fill", text: "A camera turned on", tint: .green), duration: 2.4)
        }
    }

    private static let cameraRunningAddress = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))

    private static func cameraIDs() -> [CMIOObjectID] {
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &ids) == noErr else { return [] }
        return ids
    }

    // MARK: CoreAudio helpers

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// Reads a plain numeric property (UInt32, Float32, AudioObjectID).
    private static func read<T: Numeric>(_ object: AudioObjectID, _ addr: inout AudioObjectPropertyAddress, _ fallback: T) -> T {
        guard AudioObjectHasProperty(object, &addr) else { return fallback }
        var value = fallback
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) { raw in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, raw.baseAddress!)
        }
        return status == noErr ? value : fallback
    }

    private static func isSettable(_ object: AudioObjectID, _ addr: inout AudioObjectPropertyAddress) -> Bool {
        guard AudioObjectHasProperty(object, &addr) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &addr, &settable) == noErr && settable.boolValue
    }

    private static func name(of device: AudioObjectID) -> String? {
        guard device != kAudioObjectUnknown else { return nil }
        var addr = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &name) == noErr, let cf = name?.takeRetainedValue() else { return nil }
        return cf as String
    }
}
