//
//  TabButton.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-24.
//

import SwiftUI

struct TabButton: View {
    let label: String
    let icon: String
    let selected: Bool
    /// Hoverbird: narrower when many tabs share the space beside the notch.
    var width: CGFloat = 26
    let onClick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onClick) {
            Image(systemName: icon)
                .frame(width: width, height: 28)
                .background {
                    // Hoverbird: same hover circle as the header buttons on the right.
                    Circle()
                        .fill(Color.white.opacity(hovering && !selected ? 0.14 : 0))
                        .frame(width: width, height: width)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .overlay(alignment: .bottom) {
            if hovering {
                HoverNameTag(text: label)
                    .offset(y: 17)
                    .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .top)))
            }
        }
        .zIndex(hovering ? 5 : 0)
    }
}
