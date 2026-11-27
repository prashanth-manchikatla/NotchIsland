//
//  Plumage.swift
//  Hoverbird
//
//  The hummingbird's colours (taken from the app icon) and the iridescent "plumage" highlight
//  used for selected tabs, header buttons, segments and snap zones.
//

import SwiftUI

enum Plumage {
    static let wingLight = Color(red: 0x9B / 255, green: 0xE9 / 255, blue: 0xFF / 255)  // #9BE9FF
    static let wingDeep = Color(red: 0x2F / 255, green: 0x8C / 255, blue: 0xFF / 255)   // #2F8CFF
    static let plumeLight = Color(red: 0xD0 / 255, green: 0xA8 / 255, blue: 0xFF / 255) // #D0A8FF
    static let plumeDeep = Color(red: 0x6E / 255, green: 0x6C / 255, blue: 0xF0 / 255)  // #6E6CF0
    static let tail = Color(red: 0x8A / 255, green: 0x7D / 255, blue: 0xFF / 255)       // #8A7DFF
    static let bodyLight = Color(red: 0x7C / 255, green: 0xC8 / 255, blue: 0xFF / 255)  // #7CC8FF
    static let eye = Color(red: 0x0E / 255, green: 0x11 / 255, blue: 0x24 / 255)        // #0E1124

    /// Blue-to-violet sheen across a selected control.
    static func sheen(_ opacity: Double = 1) -> LinearGradient {
        LinearGradient(colors: [wingLight.opacity(opacity), tail.opacity(opacity)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Selected-state background: a soft iridescent capsule with a hairline edge.
struct PlumageCapsule: View {
    var strength: Double = 1

    var body: some View {
        Capsule(style: .continuous)
            .fill(Plumage.sheen(0.30 * strength))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.24 * strength), lineWidth: 0.5))
    }
}

/// The same highlight for rectangular things (zones, cards).
struct PlumageRoundedRect: View {
    let cornerRadius: CGFloat
    var strength: Double = 1

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Plumage.sheen(0.30 * strength))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.24 * strength), lineWidth: 0.5))
    }
}
