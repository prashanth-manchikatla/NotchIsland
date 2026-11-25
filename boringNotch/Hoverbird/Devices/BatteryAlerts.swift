//
//  BatteryAlerts.swift
//  Hoverbird · Devices
//
//  This Mac's battery, at your levels: "Charged to 80% — unplug to protect the battery"
//  while charging, and "Battery 20% — plug in soon" on battery. Once per charge / discharge.
//  Driven by the battery model's own power-source events (no polling).
//

import Combine
import Defaults
import SwiftUI

extension Defaults.Keys {
    static let batteryFullAlert = Key<Bool>("batteryFullAlert", default: false)
    static let batteryFullAlertLevel = Key<Int>("batteryFullAlertLevel", default: 80)
    static let batteryLowAlert = Key<Bool>("batteryLowAlert", default: false)
    static let batteryLowAlertLevel = Key<Int>("batteryLowAlertLevel", default: 20)
}

@MainActor
final class BatteryAlerts {
    static let shared = BatteryAlerts()
    private var cancellable: AnyCancellable?
    private var fullShown = false
    private var lowShown = false

    private init() {}

    func start() {
        let battery = BatteryStatusViewModel.shared
        cancellable = Publishers.CombineLatest(battery.$levelBattery, battery.$isPluggedIn)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .receive(on: RunLoop.main)
            .sink { [weak self] level, pluggedIn in self?.check(level: level, pluggedIn: pluggedIn) }
    }

    private func check(level: Float, pluggedIn: Bool) {
        let battery = BatteryStatusViewModel.shared
        let percent = battery.maxCapacity > 0 ? Int((level / battery.maxCapacity * 100).rounded()) : Int(level.rounded())
        guard percent > 0 else { return }
        if pluggedIn {
            lowShown = false
            let target = Defaults[.batteryFullAlertLevel]
            if Defaults[.batteryFullAlert], percent >= target, !fullShown {
                fullShown = true
                IslandActivityHub.shared.showPill(.info(symbol: "battery.100percent.bolt",
                                                        text: target >= 100 ? "Fully charged" : "Charged to \(percent)% — unplug to protect the battery",
                                                        tint: .green), duration: 5)
            }
        } else {
            fullShown = false
            let low = Defaults[.batteryLowAlertLevel]
            if percent > low + 5 { lowShown = false }
            if Defaults[.batteryLowAlert], percent <= low, !lowShown {
                lowShown = true
                IslandActivityHub.shared.showPill(.info(symbol: "battery.25percent", text: "Battery \(percent)% — plug in soon",
                                                        tint: percent <= 10 ? .red : .orange), duration: 5)
            }
        }
    }
}
