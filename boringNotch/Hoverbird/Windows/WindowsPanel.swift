//
//  WindowsPanel.swift
//  Hoverbird
//
//  The Windows panel (header button, right side):
//   • Snap — Windows-style Snap Layouts: click a zone, the front window glides there.
//   • Arrange — pick how many windows share the screen (2–6) and the layout, then click
//     windows in the order you want them (zone 1, 2, 3…). Swap zones by dragging one onto
//     another or clicking two; after Arrange, changes move the windows right away.
//   • Apps — every open app; ✕ to quit one, or Quit All (Hoverbird stays open).
//

import AppKit
import SwiftUI

// MARK: - Header button

struct WindowsHeaderButton: View {
    @ObservedObject private var coordinator = BoringViewCoordinator.shared

    var body: some View {
        let active = coordinator.currentView == .windows
        HeaderCircleButton(title: "Windows",
                           help: "Snap & arrange windows, quit apps — hold for quick actions",
                           tap: toggle,
                           menu: { IslandMenus.windowsMenu() },
                           selected: active) {
            Image(systemName: "uiwindow.split.2x1")
                .foregroundStyle(.white)
                .imageScale(.medium)
        }
        .accessibilityIdentifier("header.windows")
    }

    /// Shows the Windows section inside the island, or goes back Home. (Only its Expand button
    /// opens the larger panel.)
    private func toggle() {
        withAnimation(.smooth) {
            coordinator.currentView = coordinator.currentView == .windows ? .home : .windows
        }
    }
}

/// The larger Windows panel (the island section's Expand button): a floating glass panel that stays
/// open while you snap and arrange, and clicking it doesn't take focus away from the app whose
/// windows you're arranging.
final class WindowsPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class WindowsPanelController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = WindowsPanelController()
    @Published private(set) var isShown = false
    /// Snap, Arrange or Apps — shared by the island section and the panel, so Expand keeps your place.
    @Published var section: WindowsPanel.Section = .snap
    private var panel: WindowsPanelWindow?

    func toggle() { isShown ? close() : show() }

    /// Room for the tallest tab; the glass card hugs its content, the rest is see-through.
    static let size = NSSize(width: 480, height: 520)

    func show() {
        if panel == nil {
            let panel = WindowsPanelWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                                           styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                                           backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.title = "Hoverbird Windows"
            // Fixed frame, content pinned to the top: switching tabs never makes the panel jump.
            let host = NSHostingView(rootView: WindowsPanel(onClose: { WindowsPanelController.shared.close() })
                .frame(width: Self.size.width, height: Self.size.height, alignment: .top))
            host.sizingOptions = []
            host.frame = NSRect(origin: .zero, size: Self.size)
            panel.contentView = host
            panel.delegate = self
            self.panel = panel
        }
        guard let panel else { return }
        // Under the notch, like the island's own panels.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        panel.setFrame(NSRect(x: screen.frame.midX - Self.size.width / 2, y: screen.visibleFrame.maxY - Self.size.height - 10,
                              width: Self.size.width, height: Self.size.height), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
        isShown = true
        NotificationCenter.default.post(name: .islandCloseAll, object: nil) // the island tucks itself away
    }

    func close() {
        guard let panel, isShown else { return }
        isShown = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }
}

extension IslandMenus {
    static func windowsMenu() -> NSMenu {
        let tiler = WindowTiler.shared
        let menu = NSMenu()
        menu.autoenablesItems = false
        let count = AppQuitter.shared.apps.count
        menu.addItem(ClosureMenuItem(count > 0 ? "Quit All Apps (\(count))" : "Quit All Apps", symbol: "xmark.app",
                                     enabled: count > 0) { AppQuitter.shared.quitAll() })
        menu.addItem(.separator())
        let quick: [(String, String, Tile)] = [
            ("Left Half", "rectangle.lefthalf.filled", TileLayouts.halves.tiles[0]),
            ("Right Half", "rectangle.righthalf.filled", TileLayouts.halves.tiles[1]),
            ("Top Half", "rectangle.tophalf.filled", TileLayouts.rows.tiles[0]),
            ("Bottom Half", "rectangle.bottomhalf.filled", TileLayouts.rows.tiles[1]),
            ("Fill Screen", "rectangle.inset.filled", TileLayouts.fill.tiles[0]),
            ("Center", "rectangle.center.inset.filled", TileLayouts.center.tiles[0]),
        ]
        for (title, symbol, tile) in quick {
            menu.addItem(ClosureMenuItem(title, symbol: symbol) { tiler.snapFront(to: tile) })
        }
        menu.addItem(ClosureMenuItem("Restore", symbol: "arrow.uturn.backward") { tiler.restoreFront() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Arrange Side by Side", symbol: "rectangle.split.2x1") {
            tiler.arrange(TileLayouts.halves, windows: tiler.windows())
        })
        menu.addItem(ClosureMenuItem("Arrange in Quarters", symbol: "rectangle.split.2x2") {
            tiler.arrange(TileLayouts.quarters, windows: tiler.windows())
        })
        return menu
    }
}

// MARK: - Panel

struct WindowsPanel: View {
    var onClose: (() -> Void)?
    enum Section: String, CaseIterable, Identifiable {
        case snap = "Snap", arrange = "Arrange", apps = "Apps"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .snap: return "rectangle.split.2x1"
            case .arrange: return "rectangle.split.2x2"
            case .apps: return "square.grid.2x2"
            }
        }
    }

    @ObservedObject private var controller = WindowsPanelController.shared
    @Namespace private var segment

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "uiwindow.split.2x1").font(.system(size: 14, weight: .semibold)).foregroundStyle(Plumage.wingLight)
                Text("Windows").font(.system(size: 14, weight: .bold))
                Spacer()
                HStack(spacing: 2) {
                    ForEach(Section.allCases) { item in
                        Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { controller.section = item } } label: {
                            Label(item.rawValue, systemImage: item.symbol)
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .foregroundStyle(controller.section == item ? Color.primary : Color.secondary)
                                .background {
                                    if controller.section == item {
                                        PlumageCapsule()
                                            .matchedGeometryEffect(id: "segment", in: segment)
                                    }
                                }
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.primary.opacity(0.08)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Close")
                }
            }
            Group {
                switch controller.section {
                case .snap: SnapSection()
                case .arrange: ArrangeSection()
                case .apps: AppsSection()
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
        .padding(16)
        .frame(width: 468)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: controller.section)
    }
}

// MARK: - Layout thumbnail

/// A tiny screen with the layout's zones. Click a zone (Snap) or the whole thing (Arrange).
/// Zones and thumbnails are real buttons: plain tap gestures miss the first click in a panel
/// that isn't the key window. The zone under the pointer comes from the zones' geometry (see
/// IslandLayoutThumb), and zones are placed with `.position`, not `.offset`.
struct LayoutThumb: View {
    let layout: TileLayout
    var selected = false
    var onZone: ((Tile) -> Void)?
    var onSelect: (() -> Void)?
    @State private var hoveredZone: Int?
    @State private var hovering = false

    var body: some View {
        Group {
            if let onSelect {
                Button(action: onSelect) { content(interactiveZones: false) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("layout-\(layout.id)")
            } else {
                content(interactiveZones: true)
            }
        }
        .onHover { hovering = $0 }
    }

    private func content(interactiveZones: Bool) -> some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let rects = layout.tiles.map { Self.zone($0, in: geo.size, inset: 4, gap: 3) }
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(selected ? 0.12 : (hovering ? 0.09 : 0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(selected ? Plumage.wingLight.opacity(0.85) : Color.primary.opacity(0.12), lineWidth: selected ? 1.5 : 0.5))
                    ForEach(Array(rects.enumerated()), id: \.offset) { index, rect in
                        ThumbZone(size: rect.size,
                                  highlighted: hoveredZone == index, selected: selected,
                                  name: layout.names[min(index, layout.names.count - 1)],
                                  identifier: "snap-\(layout.id)-\(index)",
                                  interactive: interactiveZones,
                                  tap: { onZone?(layout.tiles[index]) })
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    guard interactiveZones else { return }
                    var next: Int?
                    if case .active(let point) = phase { next = IslandLayoutThumb.zoneIndex(at: point, in: rects, slack: 2) }
                    if next != hoveredZone { withAnimation(.easeOut(duration: 0.12)) { hoveredZone = next } }
                }
            }
            .aspectRatio(1.6, contentMode: .fit)
            .scaleEffect(hovering ? 1.04 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: hovering)
            Text(layout.name).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    private struct ThumbZone: View {
        let size: CGSize
        let highlighted: Bool
        let selected: Bool
        let name: String
        let identifier: String
        let interactive: Bool
        let tap: () -> Void

        var body: some View {
            let fill: AnyShapeStyle = highlighted ? AnyShapeStyle(Plumage.sheen(0.9))
                : (selected ? AnyShapeStyle(Plumage.sheen(0.4)) : AnyShapeStyle(Color.primary.opacity(0.16)))
            let shape = RoundedRectangle(cornerRadius: 4, style: .continuous).fill(fill)
            if interactive {
                Button(action: tap) { shape.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .frame(width: size.width, height: size.height)
                    .help(name)
                    .accessibilityIdentifier(identifier)
            } else {
                shape.frame(width: size.width, height: size.height).allowsHitTesting(false)
            }
        }
    }

    static func zone(_ tile: Tile, in size: CGSize, inset: CGFloat, gap: CGFloat) -> CGRect {
        let area = CGRect(origin: .zero, size: size).insetBy(dx: inset - gap / 2, dy: inset - gap / 2)
        return CGRect(x: area.minX + area.width * tile.x, y: area.minY + area.height * tile.y,
                      width: area.width * tile.w, height: area.height * tile.h).insetBy(dx: gap / 2, dy: gap / 2)
    }
}

// MARK: - Snap

private struct SnapSection: View {
    @State private var front: WindowInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                if let front {
                    AppIconView(bundleID: front.bundleID, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(front.appName).font(.system(size: 12, weight: .semibold))
                        Text(front.title.isEmpty ? "Front window" : front.title)
                            .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        if front.isFullScreen {
                            Text("In full screen — it leaves full screen to snap")
                                .font(.system(size: 9.5, weight: .medium)).foregroundStyle(.orange)
                        }
                    }
                } else {
                    Image(systemName: "macwindow").font(.system(size: 16)).foregroundStyle(.secondary)
                    Text("Click a window, then pick where it goes.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                GlassButton(title: "Restore", symbol: "arrow.uturn.backward") { WindowTiler.shared.restoreFront() }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                ForEach(TileLayouts.snap) { layout in
                    LayoutThumb(layout: layout, onZone: { tile in
                        WindowTiler.shared.snapFront(to: tile)
                        refresh(after: 0.6)
                    })
                }
            }
            Text("Click a zone to snap the front window there.  ⌃⌥ ← → ↑ ↓ halves · ⌃⌥↩ fill · ⌃⌥ D F G thirds · ⌃⌥⌫ restore")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
        }
        .onAppear { refresh(after: 0) }
    }

    private func refresh(after seconds: Double) {
        Task { @MainActor in
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            withAnimation(.smooth) { front = WindowTiler.shared.frontWindow() }
        }
    }
}

// MARK: - Arrange

/// The island's Arrange, larger: live pictures in the zones, two columns of windows. Same model, so
/// what you picked in the island is still picked here.
private struct ArrangeSection: View {
    @ObservedObject private var model = ArrangeModel.shared
    @State private var drag: ArrangeDrag?
    @State private var dropTarget: Int?
    @State private var mapFrame: CGRect = .zero

    private static let space = "panelArrange"
    private static let mapSize = CGSize(width: 436, height: 196)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Split into").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                SplitCountPicker(model: model, idPrefix: "panel", large: true)
                Spacer(minLength: 0)
                Text(model.placedCount == 0 ? "No windows picked yet" : "\(model.placedCount) of \(model.count) zones filled")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            ArrangeLayoutPicker(model: model, thumb: CGSize(width: 66, height: 41), columns: 6, idPrefix: "panel", showsNames: true)
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    ArrangeMap(model: model, size: Self.mapSize, space: Self.space, idPrefix: "panel", large: true,
                               drag: drag, dropTarget: dropTarget, onDrag: dragChanged, onDrop: dropped)
                    HStack(spacing: 6) {
                        Text("Windows — click them in the order you want them")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if model.placedCount > 0 {
                            Button("Clear") { model.clear() }
                                .buttonStyle(.plain)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Plumage.wingLight)
                                .accessibilityIdentifier("panel.arrange.clear")
                        }
                    }
                    ArrangeWindowList(model: model, space: Self.space, idPrefix: "panel", large: true, columns: 2,
                                      drag: drag, onDrag: dragChanged, onDrop: dropped)
                        .frame(height: 84)
                }
                if let drag, let window = model.window(drag.id) {
                    WindowChip(window: window)
                        .scaleEffect(1.06)
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
                        .position(drag.point)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: Self.space)
            .onPreferenceChange(ArrangeMapFrameKey.self) { mapFrame = $0 }
            HStack(spacing: 8) {
                ArrangeStatusText(model: model, large: true)
                GlassButton(title: "Auto-fill", symbol: "wand.and.stars") { model.autofill() }
                    .help("Fill the empty zones with your front-most windows")
                GlassButton(title: "Arrange", symbol: "rectangle.split.2x2.fill", prominent: true) { model.apply() }
                    .accessibilityIdentifier("panel.arrange.apply")
            }
        }
        .onAppear { model.load(thumbnails: true) }
    }

    private func dragChanged(_ value: ArrangeDrag) {
        drag = value
        let target = ArrangeMap.zone(at: value.point, mapFrame: mapFrame, layout: model.layout, large: true)
        if target != dropTarget { withAnimation(.easeOut(duration: 0.12)) { dropTarget = target } }
    }

    private func dropped(_ value: ArrangeDrag) {
        ArrangeDropHandler.drop(value, on: model, mapFrame: mapFrame, large: true)
        drag = nil
        dropTarget = nil
    }
}

// MARK: - Apps

private struct AppsSection: View {
    @ObservedObject private var quitter = AppQuitter.shared
    @State private var confirmAll = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(quitter.apps.count) open app\(quitter.apps.count == 1 ? "" : "s")").font(.system(size: 11.5, weight: .semibold))
                Spacer()
                Label("Hoverbird stays open", systemImage: "lock.shield").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 10) {
                    ForEach(quitter.apps) { app in AppTile(app: app) }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 210)
            if !quitter.waiting.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Waiting: \(quitter.waiting.map(\.name).joined(separator: ", ")) — probably asking to save.")
                        .font(.system(size: 10.5)).lineLimit(2)
                    Spacer()
                    GlassButton(title: "Force Quit", symbol: "bolt.fill", tint: .orange) { quitter.forceQuitWaiting() }
                }
            }
            Button {
                if confirmAll {
                    quitter.quitAll()
                    confirmAll = false
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { confirmAll = true }
                    resetTask?.cancel()
                    resetTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(4))
                        if !Task.isCancelled { withAnimation(.smooth) { confirmAll = false } }
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: quitter.isQuitting ? "hourglass" : "xmark.app.fill")
                    Text(quitter.isQuitting ? "Quitting…"
                         : (confirmAll ? "Click again to quit \(quitter.apps.count) apps" : "Quit All Apps"))
                }
                .font(.system(size: 12.5, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .foregroundStyle(.white)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.red.opacity(confirmAll ? 0.9 : 0.6)))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.white.opacity(0.25), lineWidth: 0.5))
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(quitter.apps.isEmpty || quitter.isQuitting)
            Text("Apps with unsaved work ask before they close. Finder and Hoverbird are never closed.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .onAppear { quitter.refresh() }
    }
}

private struct AppTile: View {
    let app: RunningAppInfo
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            AppIconView(bundleID: app.bundleID, size: 38)
                .opacity(app.isHidden ? 0.5 : 1)
                .overlay(alignment: .topTrailing) {
                    if hovering {
                        Button { AppQuitter.shared.quit(app) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 7.5, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 17, height: 17)
                                .background(Circle().fill(Color.red.opacity(0.9)))
                                .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 6, y: -6)
                        .help("Quit \(app.name)")
                        .transition(.scale.combined(with: .opacity))
                    }
                }
            Text(app.name).font(.system(size: 9.5, weight: .medium)).lineLimit(1).foregroundStyle(app.isHidden ? .secondary : .primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
        .scaleEffect(hovering ? 1.04 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { NSRunningApplication(processIdentifier: app.id)?.activate() }
        .help("Click to bring \(app.name) forward")
    }
}

// MARK: - Shared bits

struct AppIconView: View {
    let bundleID: String?
    var size: CGFloat = 20

    var body: some View {
        if let bundleID, let icon = AppIconAsNSImage(for: bundleID) {
            Image(nsImage: icon).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed").font(.system(size: size * 0.7)).foregroundStyle(.secondary).frame(width: size, height: size)
        }
    }
}

struct GlassButton: View {
    let title: String
    var symbol: String?
    var tint: Color = .primary
    var prominent = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(prominent ? Color.white : tint)
            .background {
                if prominent {
                    Capsule().fill(Color.cyan.opacity(hovering ? 0.85 : 0.7))
                } else {
                    Capsule().fill(.thinMaterial)
                }
            }
            .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 0.5))
            .scaleEffect(hovering ? 1.03 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
    }
}
