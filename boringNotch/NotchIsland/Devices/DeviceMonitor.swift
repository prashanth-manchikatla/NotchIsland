//
//  DeviceMonitor.swift
//  NotchIsland
//
//  Event-driven device islands:
//   • AirPods / headphones / keyboards / mice connecting over Bluetooth
//     (with battery levels when the device reports them)
//   • Audio output switching ("Now playing on AirPods Pro")
//

import AppKit
import Combine
import CoreAudio
import Defaults
import IOBluetooth

@MainActor
final class DeviceMonitor: NSObject {
    static let shared = DeviceMonitor()

    private var connectNotification: IOBluetoothUserNotification?
    private var startedAt = Date()
    private var lastBluetoothPill: (name: String, date: Date)?
    private var lastOutputID: AudioObjectID = 0
    private var outputListenerInstalled = false
    private var cancellables = Set<AnyCancellable>()

    func start() {
        startedAt = Date()
        Defaults.publisher(.showBluetoothIsland)
            .map(\.newValue)
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled, self.connectNotification == nil {
                    self.startedAt = Date()
                    self.connectNotification = IOBluetoothDevice.register(
                        forConnectNotifications: self, selector: #selector(self.deviceConnected(_:device:)))
                } else if !enabled {
                    self.connectNotification?.unregister()
                    self.connectNotification = nil
                }
            }
            .store(in: &cancellables)

        lastOutputID = Self.defaultOutputDevice()
        installOutputListener()
    }

    // MARK: Bluetooth

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        // Registration replays already-connected devices; ignore that burst.
        BluetoothBatteryMonitor.shared.refreshSoon()
        guard Date().timeIntervalSince(startedAt) > 4 else { return }
        let name = device.name ?? "Bluetooth device"
        let symbol = Self.symbol(for: device)
        // AirPods report battery a moment after connecting.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            let battery = Self.batteryText(for: device)
            self.lastBluetoothPill = (name, Date())
            let earbuds = symbol.hasPrefix("airpod") || symbol.hasPrefix("beats")
            IslandActivityHub.shared.showPill(.device(name: name, symbol: symbol, battery: battery), duration: earbuds ? 5.5 : 3.5)
        }
    }

    private static func symbol(for device: IOBluetoothDevice) -> String {
        let name = (device.name ?? "").lowercased()
        if name.contains("airpods max") { return "airpodsmax" }
        if name.contains("airpods pro") { return "airpodspro" }
        if name.contains("airpods") { return "airpods" }
        if name.contains("beats") { return "beats.headphones" }
        if name.contains("keyboard") { return "keyboard.fill" }
        if name.contains("mouse") { return "magicmouse.fill" }
        if name.contains("trackpad") { return "rectangle.and.hand.point.up.left.fill" }
        if name.contains("controller") || name.contains("dualsense") || name.contains("xbox") { return "gamecontroller.fill" }
        if device.deviceClassMajor == kBluetoothDeviceClassMajorAudio { return "headphones" }
        if device.deviceClassMajor == kBluetoothDeviceClassMajorPeripheral { return "keyboard.fill" }
        return "dot.radiowaves.left.and.right"
    }

    /// Battery via IOBluetooth's private properties — read only if they exist.
    private static func batteryText(for device: IOBluetoothDevice) -> String? {
        func value(_ key: String) -> Int? {
            guard device.responds(to: NSSelectorFromString(key)),
                  let number = device.value(forKey: key) as? NSNumber else { return nil }
            let v = number.intValue
            return (1...100).contains(v) ? v : nil
        }
        let left = value("batteryPercentLeft"), right = value("batteryPercentRight")
        let single = value("batteryPercentSingle"), caseLevel = value("batteryPercentCase")
        if let left, let right {
            var text = "L \(left)%  R \(right)%"
            if let caseLevel { text += "  Case \(caseLevel)%" }
            return text
        }
        if let single { return "\(single)%" }
        if let level = left ?? right { return "\(level)%" }
        return nil
    }

    // MARK: Audio output

    private func installOutputListener() {
        guard !outputListenerInstalled else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { _, _ in
            MainActor.assumeIsolated { DeviceMonitor.shared.outputChanged() }
        }
        outputListenerInstalled = status == noErr
    }

    private func outputChanged() {
        let id = Self.defaultOutputDevice()
        guard id != 0, id != lastOutputID else { return }
        lastOutputID = id
        guard Defaults[.showAudioOutputIsland], Date().timeIntervalSince(startedAt) > 4 else { return }
        let name = Self.deviceName(id) ?? "Output"
        // AirPods connecting already showed an island.
        if let last = lastBluetoothPill, Date().timeIntervalSince(last.date) < 4, last.name == name { return }
        IslandActivityHub.shared.showPill(.audioOutput(name: name, symbol: Self.outputSymbol(id, name: name)), duration: 2.6)
    }

    private static func defaultOutputDevice() -> AudioObjectID {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    private static func deviceName(_ id: AudioObjectID) -> String? {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private static func outputSymbol(_ id: AudioObjectID, name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport)
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        case kAudioDeviceTransportTypeUSB: return "hifispeaker.fill"
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        default: return "speaker.wave.2.fill"
        }
    }
}
