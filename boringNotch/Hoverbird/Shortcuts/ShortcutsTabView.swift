//
//  ShortcutsTabView.swift
//  Hoverbird
//
//  ⚡️ Shortcuts tab: every shortcut synced from your iPhone as a tile.
//  Tap to run; ones that need the phone run through iPhone Mirroring.
//

import SwiftUI

struct ShortcutsTabView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var manager = ShortcutsManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.purple)
                Text("Shortcuts").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                if !manager.shortcuts.isEmpty {
                    Text("\(manager.shortcuts.count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.gray)
                }
                Spacer(minLength: 6)
                Text("Tap to run · right-click for iPhone options")
                    .font(.system(size: 9.5)).foregroundStyle(.gray).lineLimit(1)
                Button { manager.refresh() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold)).foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
                .help("Reload shortcuts")
                Button { manager.openInShortcutsApp(nil) } label: {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 10, weight: .semibold)).foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
                .help("Open the Shortcuts app")
            }
            content
        }
        .frame(height: 128, alignment: .top)
        .padding(.top, 2)
        .onAppear { manager.refreshIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        if !manager.loaded {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading your shortcuts…").font(.system(size: 11)).foregroundStyle(.gray)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if manager.shortcuts.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(manager.loadError ?? "No shortcuts yet.")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                Text("Shortcuts made on your iPhone appear here when iCloud Sync is on in Shortcuts → Settings on both your iPhone and this Mac.")
                    .font(.system(size: 10.5)).foregroundStyle(.gray).lineLimit(3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: [GridItem(.fixed(46), spacing: 6), GridItem(.fixed(46), spacing: 6)], spacing: 6) {
                    ForEach(manager.shortcuts) { item in
                        ShortcutTile(item: item)
                    }
                }
                .padding(.horizontal, 1)
            }
        }
    }
}

private struct ShortcutTile: View {
    let item: ShortcutItem
    @ObservedObject private var manager = ShortcutsManager.shared
    @State private var hovering = false

    var body: some View {
        let tint = ShortcutsManager.color(for: item.id)
        let onIPhone = manager.runsOnIPhone(item)
        Button { manager.run(item) } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(colors: [tint, tint.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    stateIcon
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let caption {
                        Text(caption).font(.system(size: 9, weight: .medium)).foregroundStyle(captionColor).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if onIPhone {
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .help("Runs on your iPhone through iPhone Mirroring")
                }
            }
            .padding(.horizontal, 8)
            .frame(width: 178, height: 46)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(hovering ? 0.32 : 0.2)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(hovering ? 0.18 : 0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hovering)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Run on Mac") { manager.run(item, forceMac: true) }
            Button("Run on iPhone (iPhone Mirroring)") { manager.run(item, forceIPhone: true) }
            Divider()
            Button(onIPhone ? "✓ Always Run on iPhone" : "Always Run on iPhone") { manager.setRunsOnIPhone(item, !onIPhone) }
            Divider()
            Button("Edit in Shortcuts…") { manager.openInShortcutsApp(item) }
        }
        .help(item.name)
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch manager.states[item.id] {
        case .running:
            ProgressView().controlSize(.small).tint(.white)
        case .done:
            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
        case .failed:
            Image(systemName: "exclamationmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
        case nil:
            Image(systemName: ShortcutsManager.symbol(for: item.name)).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
        }
    }

    private var caption: String? {
        switch manager.states[item.id] {
        case .running(let onIPhone): return onIPhone ? "Running on iPhone…" : "Running…"
        case .done(let onIPhone): return onIPhone ? "Sent to iPhone" : "Done"
        case .failed(let reason): return reason
        case nil: return manager.runsOnIPhone(item) ? "via iPhone Mirroring" : nil
        }
    }

    private var captionColor: Color {
        switch manager.states[item.id] {
        case .failed: return .orange
        case .done: return .green
        default: return .white.opacity(0.6)
        }
    }
}
