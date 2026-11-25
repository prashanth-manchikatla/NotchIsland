//
//  IslandBackground.swift
//  NotchIsland
//
//  The "black glass" fill behind the island: a behind-window blur of whatever is
//  under the notch, darkened by an adjustable black tint. The compact pill stays
//  solid black by default so it melts into the camera housing like the iPhone.
//

import Defaults
import SwiftUI

struct IslandBackground: View {
    let isOpen: Bool

    @Default(.islandGlassStyle) private var style
    @Default(.islandExpandedOpacity) private var expandedOpacity
    @Default(.islandCompactOpacity) private var compactOpacity
    @Default(.islandBlurStrength) private var blurStrength

    /// Keeps the blur alive for a moment after closing so the tint can fade
    /// back to black without the un-blurred desktop flashing through.
    @State private var blurAlive = false
    @State private var releaseTask: Task<Void, Never>?

    private var tint: Double {
        guard style != .solid else { return 1 }
        return isOpen ? expandedOpacity : compactOpacity
    }

    private var wantsBlur: Bool {
        style != .solid && blurStrength != .off && (isOpen || compactOpacity < 0.995)
    }

    var body: some View {
        ZStack {
            if blurAlive {
                glassLayer
                    .transition(.identity)
            }
            Color.black.opacity(tint)
        }
        .animation(.easeInOut(duration: 0.28), value: tint)
        .onAppear { blurAlive = wantsBlur }
        .onChange(of: wantsBlur) { _, newValue in
            releaseTask?.cancel()
            if newValue {
                blurAlive = true
            } else {
                releaseTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(650))
                    guard !Task.isCancelled, !wantsBlur else { return }
                    blurAlive = false
                }
            }
        }
    }

    @ViewBuilder
    private var glassLayer: some View {
        if style == .liquidGlass, #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular.tint(.black.opacity(0.35)), in: Rectangle())
        } else {
            IslandBlurView(material: blurStrength.material)
        }
    }
}

/// Behind-window blur that never dims when the app is inactive (the island never becomes key).
struct IslandBlurView: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context _: Context) {
        if view.material != material { view.material = material }
    }
}

/// A faint specular edge that makes the glass read as a solid object on busy wallpapers.
struct IslandRim<S: Shape>: View {
    let shape: S
    let visible: Bool
    @Default(.islandGlassRim) private var rimEnabled
    @Default(.islandGlassStyle) private var style

    var body: some View {
        if rimEnabled && style != .solid {
            shape
                .stroke(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.0), location: 0.0),
                            .init(color: .white.opacity(0.10), location: 0.55),
                            .init(color: .white.opacity(0.22), location: 1.0),
                        ],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
                .opacity(visible ? 1 : 0)
                .allowsHitTesting(false)
        }
    }
}
