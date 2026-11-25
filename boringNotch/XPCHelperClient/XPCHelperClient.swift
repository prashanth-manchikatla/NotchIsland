//
//  XPCHelperClient.swift
//  Hoverbird
//
//  Originally an XPC bridge to a sandbox-escaping helper (boring.notch).
//  Hoverbird runs un-sandboxed for personal use, so the helper's work
//  (Accessibility checks, keyboard + display brightness) now runs in-process.
//  The public API is unchanged so existing callers keep working.
//

import ApplicationServices
import Cocoa
import CoreGraphics
import Foundation
import IOKit
import IOKit.graphics

final class XPCHelperClient: NSObject, @unchecked Sendable {
    nonisolated static let shared = XPCHelperClient()

    private var lastKnownAuthorization: Bool?
    private var monitoringTask: Task<Void, Never>?
    private let keyboardClient = KeyboardBrightnessClient()

    deinit {
        stopMonitoringAccessibilityAuthorization()
    }

    @MainActor
    private func notifyAuthorizationChange(_ granted: Bool) {
        guard lastKnownAuthorization != granted else { return }
        lastKnownAuthorization = granted
        NotificationCenter.default.post(
            name: .accessibilityAuthorizationChanged,
            object: nil,
            userInfo: ["granted": granted]
        )
    }

    // MARK: - Monitoring

    nonisolated func startMonitoringAccessibilityAuthorization(every interval: TimeInterval = 3.0) {
        stopMonitoringAccessibilityAuthorization()
        monitoringTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let granted = await self.isAccessibilityAuthorized()
                // Once granted there is nothing left to watch; stop polling to save energy.
                if granted { break }
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch { break }
            }
        }
    }

    nonisolated func stopMonitoringAccessibilityAuthorization() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    var isMonitoring: Bool { monitoringTask != nil }

    // MARK: - Accessibility

    nonisolated func requestAccessibilityAuthorization() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    nonisolated func isAccessibilityAuthorized() async -> Bool {
        let result = AXIsProcessTrusted()
        await MainActor.run { notifyAuthorizationChange(result) }
        return result
    }

    nonisolated func ensureAccessibilityAuthorization(promptIfNeeded: Bool) async -> Bool {
        if AXIsProcessTrusted() {
            await MainActor.run { notifyAuthorizationChange(true) }
            return true
        }
        if promptIfNeeded {
            requestAccessibilityAuthorization()
            // Keep watching so features turn on automatically once the user flips the switch.
            startMonitoringAccessibilityAuthorization(every: 2.0)
        }
        try? await Task.sleep(for: .milliseconds(500))
        let result = AXIsProcessTrusted()
        await MainActor.run { notifyAuthorizationChange(result) }
        return result
    }

    // MARK: - Keyboard Brightness

    nonisolated func isKeyboardBrightnessAvailable() async -> Bool {
        keyboardClient.isAvailable
    }

    nonisolated func currentKeyboardBrightness() async -> Float? {
        keyboardClient.currentBrightness()
    }

    nonisolated func setKeyboardBrightness(_ value: Float) async -> Bool {
        keyboardClient.setBrightness(value)
    }

    // MARK: - Screen Brightness

    nonisolated func isScreenBrightnessAvailable() async -> Bool {
        var b: Float = 0
        if Self.displayServicesGetBrightness(displayID: CGMainDisplayID(), out: &b) { return true }
        if let io = Self.ioServiceFor(displayID: CGMainDisplayID()) {
            IOObjectRelease(io)
            return true
        }
        return false
    }

    nonisolated func currentScreenBrightness() async -> Float? {
        var b: Float = 0
        if Self.displayServicesGetBrightness(displayID: CGMainDisplayID(), out: &b) {
            return b
        }
        if let io = Self.ioServiceFor(displayID: CGMainDisplayID()) {
            defer { IOObjectRelease(io) }
            var level: Float = 0
            if IODisplayGetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, &level) == kIOReturnSuccess {
                return level
            }
        }
        return nil
    }

    nonisolated func setScreenBrightness(_ value: Float) async -> Bool {
        let clamped = max(0, min(1, value))
        if Self.displayServicesSetBrightness(displayID: CGMainDisplayID(), value: clamped) {
            return true
        }
        if let io = Self.ioServiceFor(displayID: CGMainDisplayID()) {
            defer { IOObjectRelease(io) }
            return IODisplaySetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, clamped) == kIOReturnSuccess
        }
        return false
    }

    // MARK: - Private helpers (DisplayServices / IOKit)

    private static func displayServicesGetBrightness(displayID: CGDirectDisplayID, out: inout Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesGetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        var tmp: Float = 0
        if fn(displayID, &tmp) == 0 {
            out = tmp
            return true
        }
        return false
    }

    private static func displayServicesSetBrightness(displayID: CGDirectDisplayID, value: Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesSetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, Float) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(displayID, value) == 0
    }

    private static func ioServiceFor(displayID: CGDirectDisplayID) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == kIOReturnSuccess else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            let info = IODisplayCreateInfoDictionary(service, 0).takeRetainedValue() as NSDictionary
            if let vendorID = info[kDisplayVendorID] as? UInt32,
               let productID = info[kDisplayProductID] as? UInt32,
               vendorID == CGDisplayVendorNumber(displayID),
               productID == CGDisplayModelNumber(displayID) {
                return service
            }
            IOObjectRelease(service)
        }
        return nil
    }

    private enum DisplayServicesHandle {
        static let handle: UnsafeMutableRawPointer? = {
            for path in [
                "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/Current/DisplayServices",
            ] {
                if let h = dlopen(path, RTLD_LAZY) { return h }
            }
            return nil
        }()
    }
}

// MARK: - Keyboard backlight via CoreBrightness (private)

private final class KeyboardBrightnessClient: @unchecked Sendable {
    private static let keyboardID: UInt64 = 1
    private var clientInstance: NSObject?
    private let getSelector = NSSelectorFromString("brightnessForKeyboard:")
    private let setSelector = NSSelectorFromString("setBrightness:forKeyboard:")

    init() {
        var loaded = false
        for path in [
            "/System/Library/PrivateFrameworks/CoreBrightness.framework",
            "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
        ] where !loaded {
            if let bundle = Bundle(path: path) {
                loaded = bundle.load()
            }
        }
        if loaded, let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type {
            clientInstance = cls.init()
        }
    }

    var isAvailable: Bool { clientInstance != nil }

    func currentBrightness() -> Float? {
        guard let clientInstance,
              let fn = methodIMP(on: clientInstance, selector: getSelector, as: BrightnessGetter.self)
        else { return nil }
        return fn(clientInstance, getSelector, Self.keyboardID)
    }

    func setBrightness(_ value: Float) -> Bool {
        guard let clientInstance,
              let fn = methodIMP(on: clientInstance, selector: setSelector, as: BrightnessSetter.self)
        else { return false }
        return fn(clientInstance, setSelector, value, Self.keyboardID).boolValue
    }

    private typealias BrightnessGetter = @convention(c) (NSObject, Selector, UInt64) -> Float
    private typealias BrightnessSetter = @convention(c) (NSObject, Selector, Float, UInt64) -> ObjCBool

    private func methodIMP<T>(on object: NSObject, selector: Selector, as type: T.Type) -> T? {
        guard let cls = object_getClass(object),
              let method = class_getInstanceMethod(cls, selector)
        else { return nil }
        return unsafeBitCast(method_getImplementation(method), to: type)
    }
}

extension Notification.Name {
    static let accessibilityAuthorizationChanged = Notification.Name("accessibilityAuthorizationChanged")
}
