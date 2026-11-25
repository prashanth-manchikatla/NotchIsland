//
//  IslandPinState.swift
//  Hoverbird
//
//  📌 Pin: keeps the expanded island open even after the pointer leaves, until
//  you unpin it (or swipe it closed / use the toggle shortcut).
//

import SwiftUI

@MainActor
final class IslandPinState: ObservableObject {
    static let shared = IslandPinState()
    @Published var pinned = false

    func toggle() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { pinned.toggle() }
    }
}

struct PinHeaderButton: View {
    @ObservedObject private var pin = IslandPinState.shared

    var body: some View {
        HeaderCircleButton(
            title: pin.pinned ? "Unpin" : "Pin",
            help: pin.pinned ? "Pinned open — click to unpin" : "Pin the island open",
            tap: { pin.toggle() }
        ) {
            Image(systemName: pin.pinned ? "pin.fill" : "pin")
                .foregroundStyle(pin.pinned ? Color.orange : Color.white)
                .rotationEffect(.degrees(pin.pinned ? 0 : 45))
                .imageScale(.medium)
                .symbolEffect(.bounce, value: pin.pinned)
        }
    }
}
