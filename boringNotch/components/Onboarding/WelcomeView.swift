//
//  WelcomeView.swift
//  NotchIsland (based on boring.notch)
//

import SwiftUI

struct WelcomeView: View {
    var onGetStarted: (() -> Void)? = nil

    private let highlights: [(icon: String, text: String)] = [
        ("music.note", "Now Playing for every app — music, video and browsers"),
        ("iphone.gen3", "Order & ride updates from your iPhone"),
        ("doc.on.clipboard", "Clipboard history stack"),
        ("camera.viewfinder", "Screenshots and screen recording"),
        ("cup.and.saucer.fill", "Keep your Mac awake from the notch"),
    ]

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
                .padding(.top, 36)
            Text("NotchIsland")
                .font(.system(.largeTitle, design: .rounded))
                .fontWeight(.semibold)
            Text("Your Mac's Dynamic Island")
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(highlights, id: \.text) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.icon)
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 22)
                            .foregroundStyle(.white.opacity(0.9))
                        Text(item.text)
                            .font(.callout)
                            .foregroundStyle(.primary)
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 24)

            Button {
                onGetStarted?()
            } label: {
                Text("Get started")
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
            }
            .buttonStyle(BorderedProminentButtonStyle())
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .background {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()
        }
    }
}
