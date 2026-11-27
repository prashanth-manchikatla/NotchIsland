//
//  IslandWindowsSection.swift
//  Hoverbird
//
//  The Windows section inside the island (header button, right side): Snap, Arrange and Apps
//  without opening another window. Only Expand opens the larger panel (WindowsPanelController).
//

import AppKit
import ScreenCaptureKit
import SwiftUI

struct IslandWindowsSection: View {
    @ObservedObject private var controller = WindowsPanelController.shared

    var body: some View {
        Group {
            switch controller.section {
            case .snap: IslandSnapView()
            case .arrange: IslandArrangeView()
            case .apps: IslandAppsView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 134, alignment: .top)
        .padding(.top, 2)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: controller.section)
    }
}

/// Snap · Arrange · Apps, with the bird's plumage on the selected one.
struct WindowsSegments: View {
    @ObservedObject private var controller = WindowsPanelController.shared
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 1) {
            ForEach(WindowsPanel.Section.allCases) { item in
                let on = controller.section == item
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { controller.section = item }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: item.symbol).font(.system(size: 9.5, weight: .semibold))
                        Text(item.rawValue).font(.system(size: 10.5, weight: .semibold))
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .foregroundStyle(on ? Color.white : Color.white.opacity(0.6))
                    .background {
                        if on { PlumageCapsule().matchedGeometryEffect(id: "segment", in: selection) }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("windows.segment.\(item.rawValue.lowercased())")
            }
        }
        .padding(1)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }
}

/// The only way this section opens another window.
struct WindowsExpandButton: View {
    var body: some View {
        GlassButton(title: "Expand", symbol: "arrow.up.left.and.arrow.down.right") {
            WindowsPanelController.shared.show()
        }
        .help("Open the larger Windows panel")
        .accessibilityIdentifier("windows.expand")
    }
}

/// A screen in miniature with a layout's zones. With `onZone`, every zone is a button.
struct IslandLayoutThumb: View {
    let layout: TileLayout
    let size: CGSize
    var selected = false
    var onZone: ((Int, Tile) -> Void)? = nil
    var onHoverZone: ((String, Bool) -> Void)? = nil
    @State private var hovered: Int?

    var body: some View {
        let corner = size.height * 0.19
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.10 : 0.05))
                .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(selected ? Plumage.wingLight.opacity(0.85) : Color.white.opacity(0.14), lineWidth: selected ? 1.5 : 0.5))
            ForEach(Array(layout.tiles.enumerated()), id: \.offset) { index, tile in
                let small = size.height < 36
                zone(index: index, tile: tile, rect: LayoutThumb.zone(tile, in: size, inset: small ? 3 : 4, gap: small ? 2 : 3))
            }
        }
        .frame(width: size.width, height: size.height)
    }

    @ViewBuilder
    private func zone(index: Int, tile: Tile, rect: CGRect) -> some View {
        let name = layout.names[min(index, layout.names.count - 1)]
        let shape = RoundedRectangle(cornerRadius: max(2, min(4, rect.height * 0.14)), style: .continuous)
        let fill: AnyShapeStyle = hovered == index ? AnyShapeStyle(Plumage.sheen(0.95))
            : (selected ? AnyShapeStyle(Plumage.sheen(0.45)) : AnyShapeStyle(Color.white.opacity(0.16)))
        if let onZone {
            Button { onZone(index, tile) } label: {
                shape.fill(fill).frame(width: rect.width, height: rect.height).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: rect.minX, y: rect.minY)
            .onHover { inside in
                withAnimation(.easeOut(duration: 0.12)) {
                    if inside { hovered = index } else if hovered == index { hovered = nil }
                }
                onHoverZone?(name, inside)
            }
            .help(name)
            .accessibilityIdentifier("island.snap.\(layout.id).\(index)")
        } else {
            shape.fill(fill)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Snap

private struct IslandSnapView: View {
    @State private var front: WindowInfo?
    @State private var hoveredZone: String?
    @State private var snapped: String?
    @State private var clearTask: Task<Void, Never>?
    private static let thumb = CGSize(width: 75, height: 47)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                WindowsSegments()
                frontLine
                GlassButton(title: "Restore", symbol: "arrow.uturn.backward") {
                    WindowTiler.shared.restoreFront()
                    refresh(after: 0.5)
                }
                .help("Put the front window back where it was")
                WindowsExpandButton()
            }
            .frame(height: 22)
            HStack(alignment: .top, spacing: 12) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.thumb.width), spacing: 9), count: 6), spacing: 6) {
                    ForEach(TileLayouts.snap) { layout in
                        IslandLayoutThumb(layout: layout, size: Self.thumb,
                                          onZone: { index, tile in snap(layout, index: index, tile: tile) },
                                          onHoverZone: { name, inside in
                                              if inside { hoveredZone = name } else if hoveredZone == name { hoveredZone = nil }
                                          })
                    }
                }
                .frame(width: Self.thumb.width * 6 + 9 * 5, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Click a zone to snap the front window.")
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("⌃⌥ ← → ↑ ↓  halves")
                    Text("⌃⌥ ↩  fill · ⌃⌥ ⌫  restore")
                    Text("⌃⌥ D F G  thirds")
                }
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { refresh(after: 0) }
        .onDisappear { clearTask?.cancel() }
    }

    private var frontLine: some View {
        HStack(spacing: 6) {
            if let front {
                AppIconView(bundleID: front.bundleID, size: 15)
                Text(front.appName).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text(detail(for: front))
                    .font(.system(size: 10.5))
                    .foregroundStyle(snapped != nil ? Plumage.wingLight : (front.isFullScreen && hoveredZone == nil ? .orange : .white.opacity(0.55)))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Image(systemName: "macwindow").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                Text("Click a window, then pick where it goes").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detail(for window: WindowInfo) -> String {
        if let snapped { return "Snapped to \(snapped)" }
        if let hoveredZone { return "Snap to \(hoveredZone)" }
        if window.isFullScreen { return "In full screen — it leaves full screen to snap" }
        return window.title.isEmpty ? "Front window" : window.title
    }

    private func snap(_ layout: TileLayout, index: Int, tile: Tile) {
        WindowTiler.shared.snapFront(to: tile)
        withAnimation(.smooth) { snapped = layout.names[min(index, layout.names.count - 1)] }
        clearTask?.cancel()
        clearTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            if !Task.isCancelled { withAnimation(.smooth) { snapped = nil } }
        }
        refresh(after: 0.6)
    }

    private func refresh(after seconds: Double) {
        Task { @MainActor in
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            withAnimation(.smooth) { front = WindowTiler.shared.frontWindow() }
        }
    }
}

// MARK: - Arrange

/// Arrange's state, shared by the island section and the larger panel.
@MainActor
final class ArrangeModel: ObservableObject {
    @Published private(set) var layout: TileLayout = TileLayouts.halves
    @Published private(set) var windows: [WindowInfo] = []
    @Published private(set) var slots: [String?] = []
    @Published private(set) var applied = false
    @Published private(set) var thumbnails: [String: NSImage] = [:]

    private let spring = Animation.spring(response: 0.32, dampingFraction: 0.82)

    func load(thumbnails wanted: Bool) {
        windows = WindowTiler.shared.windows()
        autofill()
        if wanted { Task { await loadThumbnails() } }
    }

    func window(_ id: String?) -> WindowInfo? { id.flatMap { id in windows.first { $0.id == id } } }

    /// Windows not placed in the layout.
    var unplaced: [WindowInfo] {
        let placed = Set(slots.compactMap { $0 })
        return windows.filter { !placed.contains($0.id) }
    }

    func choose(_ item: TileLayout) {
        let kept = slots.compactMap { $0 }
        let others = windows.map(\.id).filter { !kept.contains($0) }
        withAnimation(spring) {
            layout = item
            slots = Array((kept + others).prefix(item.tiles.count)).map { Optional($0) }
            while slots.count < item.tiles.count { slots.append(nil) }
        }
        if applied { apply() }
    }

    func autofill() {
        withAnimation(spring) {
            slots = Array(windows.prefix(layout.tiles.count)).map { Optional($0.id) }
            while slots.count < layout.tiles.count { slots.append(nil) }
        }
    }

    func apply() {
        WindowTiler.shared.arrange(layout, windows: slots.map { window($0) })
        applied = true
    }

    /// Puts a window into a zone (swapping with whatever was there), or takes it out of the layout
    /// (`zone` nil). Once arranged, the real windows follow right away.
    func drop(_ id: String, into zone: Int?) {
        let source = slots.firstIndex(of: id)
        withAnimation(spring) {
            if let zone, zone < slots.count {
                let occupant = slots[zone]
                slots[zone] = id
                if let source, source != zone { slots[source] = occupant }
            } else if zone == nil, let source {
                slots[source] = nil
            }
        }
        if applied { apply() }
    }

    func close(_ window: WindowInfo) {
        AppQuitter.shared.quit(RunningAppInfo(id: window.pid, name: window.appName, bundleID: window.bundleID, isHidden: false, isActive: false))
        withAnimation(spring) {
            windows.removeAll { $0.pid == window.pid }
            slots = slots.map { id in id.flatMap { id in windows.contains { $0.id == id } ? id : nil } }
        }
    }

    /// Small live pictures of the windows (only the larger panel shows them; needs Screen Recording).
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

private struct IslandArrangeView: View {
    @StateObject private var model = ArrangeModel()
    @State private var dragging: (id: String, point: CGPoint)?
    @State private var dropTarget: Int?

    private static let pickerThumb = CGSize(width: 44, height: 28)
    private static let pickerWidth: CGFloat = 44 * 5 + 6 * 4
    private static let mapSize = CGSize(width: 166, height: 104)
    private static let mapOrigin = CGPoint(x: pickerWidth + 10, y: 0)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                WindowsSegments()
                Text(model.applied ? "Drop to move — the windows follow" : "\(model.layout.name) · drag windows between zones")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                GlassButton(title: "Auto-fill", symbol: "wand.and.stars") { model.autofill() }
                GlassButton(title: "Arrange", symbol: "rectangle.split.2x2.fill", prominent: true) { model.apply() }
                    .accessibilityIdentifier("windows.arrange.apply")
                WindowsExpandButton()
            }
            .frame(height: 22)
            ZStack(alignment: .topLeading) {
                HStack(alignment: .top, spacing: 10) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.pickerThumb.width), spacing: 6), count: 5), spacing: 6) {
                        ForEach(TileLayouts.arrange) { item in
                            Button { model.choose(item) } label: {
                                IslandLayoutThumb(layout: item, size: Self.pickerThumb, selected: item == model.layout)
                            }
                            .buttonStyle(.plain)
                            .help(item.name)
                            .accessibilityIdentifier("island.arrange.layout.\(item.id)")
                        }
                    }
                    .frame(width: Self.pickerWidth, alignment: .topLeading)
                    map
                    otherWindows
                }
                if let dragging, let window = model.window(dragging.id) {
                    WindowChip(window: window)
                        .scaleEffect(1.06)
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                        .position(dragging.point)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "islandArrange")
            .frame(height: 104, alignment: .topLeading)
        }
        .onAppear { model.load(thumbnails: false) }
    }

    /// The screen in miniature with the windows in their zones.
    private var map: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(LinearGradient(colors: [Plumage.wingLight.opacity(0.10), Plumage.tail.opacity(0.10)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
            ForEach(Array(model.layout.tiles.enumerated()), id: \.offset) { index, tile in
                let rect = LayoutThumb.zone(tile, in: Self.mapSize, inset: 6, gap: 6)
                zoneView(index: index)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .accessibilityIdentifier("island.arrange.zone.\(index)")
            }
        }
        .frame(width: Self.mapSize.width, height: Self.mapSize.height)
    }

    @ViewBuilder
    private func zoneView(index: Int) -> some View {
        let window = model.window(index < model.slots.count ? model.slots[index] : nil)
        let highlighted = dropTarget == index
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(highlighted ? AnyShapeStyle(Plumage.sheen(0.4)) : AnyShapeStyle(Color.white.opacity(window == nil ? 0.03 : 0.10)))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(highlighted ? Plumage.wingLight : Color.white.opacity(0.22),
                                  style: StrokeStyle(lineWidth: highlighted ? 1.2 : 0.8, dash: window == nil ? [4, 3] : [])))
            if let window {
                HStack(spacing: 4) {
                    AppIconView(bundleID: window.bundleID, size: 14)
                    Text(window.appName).font(.system(size: 9, weight: .semibold)).lineLimit(1)
                }
                .padding(5)
                .opacity(dragging?.id == window.id ? 0.35 : 1)
            } else {
                Text("Drop").font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .contentShape(Rectangle())
        .gesture(window.map { drag(for: $0.id) })
        .onTapGesture { if let window { WindowTiler.shared.raise(window) } }
        .help(window.map { "\($0.appName) — drag to another zone, click to bring it forward" } ?? "Drag a window here")
        .animation(.easeOut(duration: 0.12), value: highlighted)
    }

    private var otherWindows: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.unplaced.isEmpty ? "All windows are placed" : "Other windows")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.unplaced) { window in
                        WindowChip(window: window)
                            .opacity(dragging?.id == window.id ? 0.35 : 1)
                            .gesture(drag(for: window.id))
                            .help(window.title.isEmpty ? window.appName : window.title)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func drag(for id: String) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("islandArrange"))
            .onChanged { value in
                dragging = (id, value.location)
                let target = zoneIndex(at: value.location)
                if target != dropTarget { withAnimation(.easeOut(duration: 0.12)) { dropTarget = target } }
            }
            .onEnded { value in
                if let target = zoneIndex(at: value.location) {
                    model.drop(id, into: target)
                } else if value.location.x > Self.mapOrigin.x + Self.mapSize.width {
                    model.drop(id, into: nil)   // onto the list: out of the layout
                }
                dragging = nil
                dropTarget = nil
            }
    }

    private func zoneIndex(at point: CGPoint) -> Int? {
        let local = CGPoint(x: point.x - Self.mapOrigin.x, y: point.y - Self.mapOrigin.y)
        for (index, tile) in model.layout.tiles.enumerated()
        where LayoutThumb.zone(tile, in: Self.mapSize, inset: 6, gap: 6).contains(local) {
            return index
        }
        return nil
    }
}

/// A window as a small chip: app icon and name.
private struct WindowChip: View {
    let window: WindowInfo

    var body: some View {
        HStack(spacing: 6) {
            AppIconView(bundleID: window.bundleID, size: 14)
            Text(window.appName).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 21)
        .background(Capsule().fill(Color.white.opacity(0.09)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .contentShape(Capsule())
    }
}

// MARK: - Apps

private struct IslandAppsView: View {
    @ObservedObject private var quitter = AppQuitter.shared
    @State private var confirmAll = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                WindowsSegments()
                if quitter.waiting.isEmpty {
                    HStack(spacing: 4) {
                        Text("\(quitter.apps.count) open app\(quitter.apps.count == 1 ? "" : "s")").font(.system(size: 11, weight: .semibold))
                        Text("· Finder and Hoverbird stay open").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.55))
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Waiting: \(quitter.waiting.map(\.name).joined(separator: ", "))").lineLimit(1)
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    GlassButton(title: "Force Quit", symbol: "bolt.fill", tint: .orange) { quitter.forceQuitWaiting() }
                }
                quitAllButton
                WindowsExpandButton()
            }
            .frame(height: 22)
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 9), spacing: 4) {
                    ForEach(quitter.apps) { app in IslandAppTile(app: app) }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 104)
        }
        .onAppear { quitter.refresh() }
        .onDisappear { resetTask?.cancel() }
    }

    /// Two clicks: the first asks, the second quits.
    private var quitAllButton: some View {
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
            HStack(spacing: 4) {
                if quitter.isQuitting {
                    BirdActivityIndicator(size: 12)
                } else {
                    Image(systemName: "xmark.app.fill")
                }
                Text(quitter.isQuitting ? "Quitting…" : (confirmAll ? "Quit \(quitter.apps.count) apps?" : "Quit All"))
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10)
            .frame(height: 22)
            .foregroundStyle(.white)
            .background(Capsule().fill(Color.red.opacity(confirmAll ? 0.9 : 0.6)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(quitter.apps.isEmpty || quitter.isQuitting)
        .help("Quit every open app (apps with unsaved work ask first)")
        .accessibilityIdentifier("windows.apps.quitAll")
    }
}

private struct IslandAppTile: View {
    let app: RunningAppInfo
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 3) {
            AppIconView(bundleID: app.bundleID, size: 30)
                .opacity(app.isHidden ? 0.5 : 1)
                .overlay(alignment: .topTrailing) {
                    if hovering {
                        Button { AppQuitter.shared.quit(app) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 15, height: 15)
                                .background(Circle().fill(Color.red.opacity(0.9)))
                                .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                        .help("Quit \(app.name)")
                        .transition(.scale.combined(with: .opacity))
                    }
                }
            Text(app.name).font(.system(size: 9, weight: .medium)).lineLimit(1)
                .foregroundStyle(app.isHidden ? .secondary : .primary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(hovering ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .onTapGesture { NSRunningApplication(processIdentifier: app.id)?.activate() }
        .help("Click to bring \(app.name) forward")
    }
}
