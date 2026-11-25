//
//  AppleBatteryGlyph.swift
//  NotchIsland
//
//  A battery that looks like Apple's own (iPhone status bar / Dynamic Island):
//  rounded body with a grey track, level fill, the percentage knocked out of
//  the glyph, a small terminal cap, and a bolt beside it while charging.
//

import SwiftUI

struct AppleBatteryGlyph: View {
    var level: Float
    var isCharging: Bool
    var isPluggedIn: Bool
    var isLowPower: Bool
    /// iPhone style: the number sits inside the battery.
    var showPercentInside: Bool = true
    /// Body height in points (width follows Apple's ~2:1 proportions).
    var height: CGFloat = 12

    private var clamped: CGFloat { CGFloat(max(0, min(100, level))) }

    private var fillColor: Color {
        if isLowPower { return .yellow }
        if isCharging || (isPluggedIn && clamped >= 99) { return Color(red: 0.2, green: 0.84, blue: 0.29) }
        if clamped <= 20 { return Color(red: 1, green: 0.27, blue: 0.23) }
        return .white
    }

    var body: some View {
        let h = height
        let w = (h * 2.08).rounded()
        let corner = h * 0.34
        HStack(spacing: h * 0.1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color.white.opacity(0.32))
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(fillColor)
                    .frame(width: max(corner * 1.4, w * clamped / 100))
                if showPercentInside {
                    Text("\(Int(clamped.rounded()))")
                        .font(.system(size: h * 0.8, weight: .bold, design: .default))
                        .monospacedDigit()
                        .kerning(-0.3)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: w)
                        .foregroundStyle(.black)
                        .blendMode(.destinationOut) // knock the digits out of the glyph
                }
            }
            .frame(width: w, height: h)
            .compositingGroup()

            Capsule()
                .fill(Color.white.opacity(0.32))
                .frame(width: max(1.5, h * 0.13), height: h * 0.36)

            if isCharging || isPluggedIn {
                Image(systemName: isCharging ? "bolt.fill" : "powerplug.fill")
                    .font(.system(size: h * 0.78, weight: .bold))
                    .foregroundStyle(isCharging ? fillColor : .white.opacity(0.85))
                    .padding(.leading, 1)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(Int(clamped))%\(isCharging ? ", charging" : "")")
    }
}

/// The Dynamic Island charging/plug-in event: status on the left, battery on the right.
struct IslandChargingActivity: View {
    @ObservedObject var battery = BatteryStatusViewModel.shared

    private var title: String {
        if battery.isInLowPowerMode && !battery.isPluggedIn { return "Low Power" }
        if battery.isCharging { return "Charging" }
        if battery.isPluggedIn { return battery.levelBattery >= 99 ? "Charged" : "Plugged In" }
        return battery.statusText.isEmpty ? "Battery" : battery.statusText
    }

    private var tint: Color {
        if battery.isInLowPowerMode { return .yellow }
        if battery.isCharging || battery.isPluggedIn { return Color(red: 0.2, green: 0.84, blue: 0.29) }
        return battery.levelBattery <= 20 ? .red : .white
    }

    /// The left side grows to fit the text ("Low Power: Off" was cut off at a fixed width).
    private var sideWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        let width = (title as NSString).size(withAttributes: [.font: font]).width
        return max(78, ceil(width) + 8)
    }

    var body: some View {
        IslandCompactRow(sideWidth: sideWidth) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
        } trailing: {
            HStack(spacing: 5) {
                Text("\(Int(battery.levelBattery))%")
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .fixedSize()
                AppleBatteryGlyph(level: battery.levelBattery, isCharging: battery.isCharging,
                                  isPluggedIn: battery.isPluggedIn, isLowPower: battery.isInLowPowerMode,
                                  showPercentInside: false, height: 11)
            }
        }
    }
}
