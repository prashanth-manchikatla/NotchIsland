//
//  WindowsPanel.swift
//  NotchIsland
//
//  The Windows panel (header button, right side):
//   • Snap — Windows-style Snap Layouts: click a zone, the front window glides there.
//   • Arrange — a live mini-map of your screen: pick a layout, drag windows between
//     zones (they swap and move as you drop), drop new ones in, close apps from there.
//   • Apps — every open app; ✕ to quit one, or Quit All (NotchIsland stays open).
//

import AppKit
import ScreenCaptureKit
import SwiftUI

// MARK: - Header button

struct WindowsHeaderButton: View {
    @ObservedObject private var controller = WindowsPanelController.shared

    var body: some View {
        HeaderCircleButton(title: controller.isShown ? nil : "Windows",
                           help: "Snap & arrange windows, quit apps — hold for quick actions",
                           tap: { controller.toggle() },
                           menu: { IslandMenus.windowsMenu() }) {
            Image(systemName: "uiwindow.split.2x1")
                .foregroundStyle(controller.isShown ? Color.cyan : Color.white)
                .imageScale(.medium)
        }
    }
}

/// The Windows panel lives in its own floating glass panel: it stays open while you snap and
/// arrange (a popover closes as soon as another app comes forward), and clicking it doesn't
/// take focus away from the app whose windows you're arranging.
final class WindowsPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class WindowsPanelController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = WindowsPanelController()
    @Published private(set) var isShown = false
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
            panel.title = "NotchIsland Windows"
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

    @State private var section: Section = .snap
    @Namespace private var segment

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "uiwindow.split.2x1").font(.system(size: 14, weight: .semibold)).foregroundStyle(.cyan)
                Text("Windows").font(.system(size: 14, weight: .bold))
                Spacer()
                HStack(spacing: 2) {
                    ForEach(Section.allCases) { item in
                        Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { section = item } } label: {
                            Label(item.rawValue, systemImage: item.symbol)
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .foregroundStyle(section == item ? Color.primary : Color.secondary)
                                .background {
                                    if section == item {
                                        Capsule().fill(.thinMaterial)
                                            .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 0.5))
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
                switch section {
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
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: section)
    }
}

// MARK: - Layout thumbnail

/// A tiny screen with the layout's zones. Click a zone (Snap) or the whole thing (Arrange).
/// Zones and thumbnails are real buttons: plain tap gestures miss the first click in a panel
/// that isn't the key window.
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
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(selected ? 0.12 : (hovering ? 0.09 : 0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(selected ? Color.cyan.opacity(0.8) : Color.primary.opacity(0.12), lineWidth: selected ? 1.5 : 0.5))
                    ForEach(Array(layout.tiles.enumerated()), id: \.offset) { index, tile in
                        ThumbZone(rect: Self.zone(tile, in: geo.size, inset: 4, gap: 3),
                                  highlighted: hoveredZone == index, selected: selected,
                                  name: layout.names[min(index, layout.names.count - 1)],
                                  identifier: "snap-\(layout.id)-\(index)",
                                  interactive: interactiveZones,
                                  hover: { inside in
                                      withAnimation(.easeOut(duration: 0.12)) {
                                          if inside { hoveredZone = index } else if hoveredZone == index { hoveredZone = nil }
                                      }
                                  },
                                  tap: { onZone?(tile) })
                    }
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
        let rect: CGRect
        let highlighted: Bool
        let selected: Bool
        let name: String
        let identifier: String
        let interactive: Bool
        let hover: (Bool) -> Void
        let tap: () -> Void

        var body: some View {
            let fill: Color = highlighted ? Color.cyan.opacity(0.85) : (selected ? Color.cyan.opacity(0.35) : Color.primary.opacity(0.16))
            let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(fill)
                .frame(width: rect.width, height: rect.height)
            if interactive {
                Button(action: tap) { shape.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .offset(x: rect.minX, y: rect.minY)
                    .onHover(perform: hover)
                    .help(name)
                    .accessibilityIdentifier(identifier)
            } else {
                shape.offset(x: rect.minX, y: rect.minY).allowsHitTesting(false)
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

private struct ArrangeSection: View {
    @State private var layout: TileLayout = TileLayouts.halves
    @State private var windows: [WindowInfo] = []
    @State private var slots: [String?] = []
    @State private var dragging: (id: String, point: CGPoint)?
    @State private var dropTarget: Int?
    @State private var applied = false
    @State private var thumbnails: [String: NSImage] = [:]

    private let mapSize = CGSize(width: 436, height: 250)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(TileLayouts.arrange) { item in
                        LayoutThumb(layout: item, selected: item == layout, onSelect: { choose(item) })
                            .frame(width: 66)
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 1)
            }
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 10) {
                    map
                    strip
                }
                if let dragging, let window = windows.first(where: { $0.id == dragging.id }) {
                    WindowCard(window: window, thumbnail: thumbnails[window.id], compact: true)
                        .frame(width: 150, height: 54)
                        .scaleEffect(1.05)
                        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                        .position(dragging.point)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "arrange")
            HStack(spacing: 8) {
                Text(applied ? "Drag windows between zones — they move as you drop." : "Drag to rearrange, then Arrange.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
                GlassButton(title: "Auto-fill", symbol: "wand.and.stars") { autofill() }
                GlassButton(title: "Arrange", symbol: "rectangle.split.2x2.fill", prominent: true) { apply() }
            }
        }
        .onAppear(perform: load)
    }

    // The screen in miniature with the assigned windows.
    private var map: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [Color.cyan.opacity(0.10), Color.purple.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
            ForEach(Array(layout.tiles.enumerated()), id: \.offset) { index, tile in
                let rect = LayoutThumb.zone(tile, in: mapSize, inset: 8, gap: 8)
                zoneView(index: index)
                    .frame(width: rect.width, height: rect.height)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("arrange-zone-\(index)")
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
        .frame(width: mapSize.width, height: mapSize.height)
    }

    @ViewBuilder
    private func zoneView(index: Int) -> some View {
        let id = index < slots.count ? slots[index] : nil
        let window = id.flatMap { id in windows.first { $0.id == id } }
        let highlighted = dropTarget == index
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(highlighted ? Color.cyan.opacity(0.28) : Color.primary.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(highlighted ? Color.cyan : Color.primary.opacity(0.18),
                                  style: StrokeStyle(lineWidth: highlighted ? 1.5 : 0.8, dash: window == nil ? [5, 4] : [])))
            if let window {
                WindowCard(window: window, thumbnail: thumbnails[window.id]) {
                    close(window)
                }
                .opacity(dragging?.id == window.id ? 0.35 : 1)
                .gesture(drag(for: window.id))
                .onTapGesture { WindowTiler.shared.raise(window) }
            } else {
                Label("Drop a window", systemImage: "plus.rectangle.on.rectangle")
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: slots)
        .animation(.easeOut(duration: 0.12), value: highlighted)
    }

    // Windows not placed in the layout.
    private var strip: some View {
        let placed = Set(slots.compactMap { $0 })
        let rest = windows.filter { !placed.contains($0.id) }
        return VStack(alignment: .leading, spacing: 5) {
            Text(rest.isEmpty ? "All windows are placed" : "Other windows — drag into a zone")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(rest) { window in
                        HStack(spacing: 6) {
                            AppIconView(bundleID: window.bundleID, size: 16)
                            Text(window.appName).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.thinMaterial))
                        .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                        .opacity(dragging?.id == window.id ? 0.35 : 1)
                        .gesture(drag(for: window.id))
                        .help(window.title)
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(height: 30)
        }
        .frame(height: 46, alignment: .top)
    }

    private func drag(for id: String) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("arrange"))
            .onChanged { value in
                dragging = (id, value.location)
                let target = zoneIndex(at: value.location)
                if target != dropTarget { withAnimation(.easeOut(duration: 0.12)) { dropTarget = target } }
            }
            .onEnded { value in
                drop(id, at: value.location)
                dragging = nil
                dropTarget = nil
            }
    }

    private func zoneIndex(at point: CGPoint) -> Int? {
        for (index, tile) in layout.tiles.enumerated() where LayoutThumb.zone(tile, in: mapSize, inset: 8, gap: 8).contains(point) {
            return index
        }
        return nil
    }

    private func drop(_ id: String, at point: CGPoint) {
        let source = slots.firstIndex(of: id)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            if let target = zoneIndex(at: point) {
                let occupant = slots[target]
                slots[target] = id
                if let source, source != target { slots[source] = occupant }
            } else if point.y > mapSize.height, let source {
                slots[source] = nil // dropped on the strip: take it out of the layout
            }
        }
        if applied { apply() } // live: the real windows glide to their new places
    }

    private func load() {
        windows = WindowTiler.shared.windows()
        autofill()
        Task { await loadThumbnails() }
    }

    private func choose(_ item: TileLayout) {
        let kept = slots.compactMap { $0 }
        let others = windows.map(\.id).filter { !kept.contains($0) }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            layout = item
            slots = Array((kept + others).prefix(item.tiles.count)).map { Optional($0) }
            while slots.count < item.tiles.count { slots.append(nil) }
        }
        if applied { apply() }
    }

    private func autofill() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            slots = Array(windows.prefix(layout.tiles.count)).map { Optional($0.id) }
            while slots.count < layout.tiles.count { slots.append(nil) }
        }
    }

    private func apply() {
        let assigned = slots.map { id in id.flatMap { id in windows.first { $0.id == id } } }
        WindowTiler.shared.arrange(layout, windows: assigned)
        applied = true
    }

    private func close(_ window: WindowInfo) {
        AppQuitter.shared.quit(RunningAppInfo(id: window.pid, name: window.appName, bundleID: window.bundleID, isHidden: false, isActive: false))
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            windows.removeAll { $0.pid == window.pid }
            slots = slots.map { id in id.flatMap { id in windows.contains { $0.id == id } ? id : nil } }
        }
    }

    /// Small live pictures of the windows (Screen Recording is already allowed).
    private func loadThumbnails() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
        for window in windows.prefix(10) {
            guard let number = window.windowNumber, let scWindow = content.windows.first(where: { $0.windowID == number }) else { continue }
            let configuration = SCStreamConfiguration()
            configuration.width = 360
            configuration.height = max(60, Int(360 * scWindow.frame.height / max(1, scWindow.frame.width)))
            configuration.showsCursor = false
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: scWindow),
                                                                       configuration: configuration) {
                let picture = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                withAnimation(.easeOut(duration: 0.25)) { thumbnails[window.id] = picture }
            }
        }
    }
}

/// A window inside a zone: live picture, app icon + name, ✕ to quit the app.
private struct WindowCard: View {
    let window: WindowInfo
    let thumbnail: NSImage?
    var compact = false
    var close: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let thumbnail, !compact {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                    .clipped()
                    .overlay(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom))
            } else {
                Rectangle().fill(.thinMaterial)
            }
            HStack(spacing: 6) {
                AppIconView(bundleID: window.bundleID, size: compact ? 18 : 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(window.appName).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    if !window.title.isEmpty {
                        Text(window.title).font(.system(size: 9)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.white.opacity(0.25), lineWidth: 0.5))
        .overlay(alignment: .topTrailing) {
            if let close, hovering {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.red.opacity(0.85)))
                }
                .buttonStyle(.plain)
                .padding(5)
                .help("Quit \(window.appName)")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(3)
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
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
                Label("NotchIsland stays open", systemImage: "lock.shield").font(.system(size: 10)).foregroundStyle(.secondary)
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
            Text("Apps with unsaved work ask before they close. Finder and NotchIsland are never closed.")
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
