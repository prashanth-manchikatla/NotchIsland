//
//  IslandWindowsSection.swift
//  Hoverbird
//
//  The Windows section inside the island (header button, right side): Snap, Arrange and Apps
//  without opening another window. Only Expand opens the larger panel (WindowsPanelController).
//

import AppKit
import ApplicationServices
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
        .fixedSize()
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
///
/// The zone under the pointer comes from the zones' geometry, tracked once for the whole thumbnail.
/// (A per-zone `.onHover` after `.offset` also fired over the zone's un-offset spot at the top-left,
/// so hovering a left or top zone lit a different zone.) Zones are placed with `.position`, which
/// keeps drawing, clicks and Accessibility frames in the same place.
struct IslandLayoutThumb: View {
    let layout: TileLayout
    let size: CGSize
    var selected = false
    var idPrefix = "island.snap"
    var onZone: ((Int, Tile) -> Void)? = nil
    /// The name of the zone under the pointer, nil when it leaves.
    var onHoverZone: ((String?) -> Void)? = nil
    @State private var hovered: Int?
    @State private var inside = false

    private var small: Bool { size.height < 36 }
    private var gap: CGFloat { small ? 2 : 3 }
    private var rects: [CGRect] { layout.tiles.map { LayoutThumb.zone($0, in: size, inset: small ? 3 : 4, gap: gap) } }

    var body: some View {
        let corner = size.height * 0.19
        let zoneRects = rects
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.10 : (inside ? 0.08 : 0.05)))
                .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(selected ? Plumage.wingLight.opacity(0.85) : (inside ? Plumage.wingLight.opacity(0.4) : Color.white.opacity(0.14)),
                                  lineWidth: selected ? 1.5 : (inside ? 1 : 0.5)))
            ForEach(Array(zoneRects.enumerated()), id: \.offset) { index, rect in
                zone(index: index, rect: rect)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            var next: Int?
            var nowInside = false
            if case .active(let point) = phase {
                nowInside = true
                if onZone != nil { next = Self.zoneIndex(at: point, in: zoneRects, slack: gap / 2 + 0.5) }
            }
            if nowInside != inside { withAnimation(.easeOut(duration: 0.12)) { inside = nowInside } }
            if next != hovered {
                withAnimation(.easeOut(duration: 0.1)) { hovered = next }
                onHoverZone?(next.map { layout.names[min($0, layout.names.count - 1)] })
            }
        }
    }

    @ViewBuilder
    private func zone(index: Int, rect: CGRect) -> some View {
        let shape = RoundedRectangle(cornerRadius: max(2, min(4, rect.height * 0.14)), style: .continuous)
        let fill: AnyShapeStyle = hovered == index ? AnyShapeStyle(Plumage.sheen(0.95))
            : (selected ? AnyShapeStyle(Plumage.sheen(0.45)) : AnyShapeStyle(Color.white.opacity(0.16)))
        if let onZone {
            Button { onZone(index, layout.tiles[index]) } label: {
                shape.fill(fill).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: rect.width, height: rect.height)
            .help(layout.names[min(index, layout.names.count - 1)])
            .accessibilityIdentifier("\(idPrefix).\(layout.id).\(index)")
            .position(x: rect.midX, y: rect.midY)
        } else {
            shape.fill(fill)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
        }
    }

    /// The zone under `point`; in a gap between zones, the nearest one within `slack`.
    static func zoneIndex(at point: CGPoint, in rects: [CGRect], slack: CGFloat) -> Int? {
        if let index = rects.firstIndex(where: { $0.contains(point) }) { return index }
        var best: (index: Int, distance: CGFloat)?
        for (index, rect) in rects.enumerated() {
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance <= slack, distance < (best?.distance ?? .infinity) { best = (index, distance) }
        }
        return best?.index
    }
}

// MARK: - Snap

private struct IslandSnapView: View {
    @State private var front: WindowInfo?
    /// The zone under the pointer and the layout it belongs to.
    @State private var hoveredZone: (layout: String, name: String)?
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
                                          onHoverZone: { name in hover(layout.id, name) })
                    }
                }
                .frame(width: Self.thumb.width * 6 + 9 * 5, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Click a zone to snap the front window.")
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Group {
                        Text("⌃⌥ ← → ↑ ↓  halves")
                        Text("⌃⌥ ↩  fill")
                        Text("⌃⌥ ⌫  restore")
                        Text("⌃⌥ D F G  thirds")
                    }
                    .lineLimit(1)
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
                    .foregroundStyle(snapped != nil || hoveredZone != nil ? Plumage.wingLight
                                     : (front.isFullScreen ? .orange : .white.opacity(0.55)))
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
        if let hoveredZone { return "Snap to \(hoveredZone.name)" }
        if window.isFullScreen { return "In full screen — it leaves full screen to snap" }
        return window.title.isEmpty ? "Front window" : window.title
    }

    /// Moving between thumbnails, the next one can report before the last one lets go.
    private func hover(_ layout: String, _ name: String?) {
        if let name {
            hoveredZone = (layout, name)
        } else if hoveredZone?.layout == layout {
            hoveredZone = nil
        }
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

/// Arrange's state: which windows take part, the zone each one gets, and the layout. One shared
/// model for the island section and the larger panel, so Expand keeps your choice.
///
/// Zones are numbered in reading order (1 = the layout's first zone). Clicking windows in the list
/// fills zones 1, 2, 3… in that order; a full layout grows by one zone (up to six).
@MainActor
final class ArrangeModel: ObservableObject {
    static let shared = ArrangeModel()

    @Published private(set) var layout: TileLayout = TileLayouts.halves
    /// Windows that can be arranged, front to back (as of the last refresh).
    @Published private(set) var windows: [WindowInfo] = []
    /// The window in each zone (nil = empty). Always as long as the layout has zones.
    @Published private(set) var slots: [String?] = [nil, nil]
    /// A zone clicked once: another zone swaps with it, a window from the list goes into it.
    @Published private(set) var pickedZone: Int?
    /// After Arrange, every change moves the real windows right away.
    @Published private(set) var applied = false
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    /// A short note for the status line ("Up to 6 windows…").
    @Published private(set) var notice: String?

    private let spring = Animation.spring(response: 0.32, dampingFraction: 0.82)
    private var noticeTask: Task<Void, Never>?

    private init() {}

    var count: Int { layout.tiles.count }
    var placedCount: Int { slots.reduce(0) { $0 + ($1 == nil ? 0 : 1) } }

    func window(_ id: String?) -> WindowInfo? { id.flatMap { id in windows.first { $0.id == id } } }
    func zone(of id: String) -> Int? { slots.firstIndex(of: id) }
    func windowID(inZone zone: Int) -> String? { zone >= 0 && zone < slots.count ? slots[zone] : nil }

    /// Reads the windows again; picks stay as long as their windows are still open.
    func load(thumbnails wanted: Bool) {
        let fresh = WindowTiler.shared.windows()
        let open = Set(fresh.map(\.id))
        windows = fresh
        slots = slots.map { id in id.flatMap { open.contains($0) ? $0 : nil } }
        pickedZone = nil
        applied = false
        if wanted { Task { await loadThumbnails() } }
    }

    /// Splits the screen into `count` zones: picked windows keep their order, extras drop out.
    func setCount(_ count: Int) {
        guard count != self.count else { return }
        choose(TileLayouts.preferred(for: count))
    }

    func choose(_ item: TileLayout) {
        let zones = item.tiles.count
        var next = slots
        if zones != slots.count {
            let kept = slots.compactMap { $0 }
            if kept.count > zones {
                let out = kept.count - zones
                flash("\(out) window\(out == 1 ? "" : "s") left out — \(zones) zones")
            }
            next = Array(kept.prefix(zones)).map { Optional($0) } + Array(repeating: nil, count: max(0, zones - kept.count))
        }
        withAnimation(spring) {
            pickedZone = nil
            layout = item
            slots = next
        }
        if applied { apply() }
    }

    /// A click on a window in the list: into the picked zone if there is one; otherwise in (the
    /// first empty zone, growing the layout when it's full) or, when it's already in, out again.
    func tapWindow(_ id: String) {
        if let zone = pickedZone {
            place(id, in: zone)
            return
        }
        if let zone = zone(of: id) {
            withAnimation(spring) { slots[zone] = nil }
        } else if let empty = slots.firstIndex(where: { $0 == nil }) {
            withAnimation(spring) { slots[empty] = id }
        } else if count < TileLayouts.splitCounts.upperBound {
            let grown = TileLayouts.preferred(for: count + 1)
            withAnimation(spring) {
                layout = grown
                slots = slots + [Optional(id)]
            }
        } else {
            flash("Up to \(TileLayouts.splitCounts.upperBound) windows — take one out first")
            return
        }
        if applied { apply() }
    }

    /// Puts a window into a zone. A window already in another zone swaps places with what's
    /// there; a new one takes the zone (the window that was there leaves the layout).
    func place(_ id: String, in zone: Int) {
        guard zone >= 0, zone < slots.count else { return }
        withAnimation(spring) {
            pickedZone = nil
            let occupant = slots[zone]
            if let source = slots.firstIndex(of: id), source != zone { slots[source] = occupant }
            slots[zone] = id
        }
        if applied { apply() }
    }

    /// A click on a zone: the first click picks it, a click on another zone swaps the two,
    /// a second click on the same zone lets go.
    func tapZone(_ zone: Int) {
        guard zone >= 0, zone < slots.count else { return }
        guard let picked = pickedZone else {
            withAnimation(spring) { pickedZone = zone }
            return
        }
        withAnimation(spring) {
            pickedZone = nil
            if picked != zone, picked < slots.count { slots.swapAt(picked, zone) }
        }
        if applied, picked != zone { apply() }
    }

    /// A window dragged out of a zone: onto another zone (they swap) or off the map (it leaves).
    func move(fromZone source: Int, to target: Int?) {
        guard source >= 0, source < slots.count, target != source else { return }
        withAnimation(spring) {
            pickedZone = nil
            if let target, target >= 0, target < slots.count {
                slots.swapAt(source, target)
            } else {
                slots[source] = nil
            }
        }
        if applied { apply() }
    }

    func takeOut(zone: Int) {
        guard zone >= 0, zone < slots.count, slots[zone] != nil else { return }
        withAnimation(spring) {
            pickedZone = nil
            slots[zone] = nil
        }
    }

    func clear() {
        withAnimation(spring) {
            pickedZone = nil
            slots = Array(repeating: nil, count: count)
        }
        applied = false
    }

    /// Fills the empty zones with the front-most windows that aren't in yet.
    func autofill() {
        let placed = Set(slots.compactMap { $0 })
        var free = windows.map(\.id).filter { !placed.contains($0) }.makeIterator()
        withAnimation(spring) {
            pickedZone = nil
            slots = slots.map { $0 ?? free.next() }
        }
        if applied { apply() }
    }

    /// Moves the picked windows into their zones (empty zones stay empty).
    func apply() {
        guard placedCount > 0 else {
            flash("Pick the windows to arrange first")
            return
        }
        WindowTiler.shared.arrange(layout, windows: slots.map { window($0) })
        applied = true
    }

    func quitApp(of window: WindowInfo) {
        AppQuitter.shared.quit(RunningAppInfo(id: window.pid, name: window.appName, bundleID: window.bundleID, isHidden: false, isActive: false))
        withAnimation(spring) {
            windows.removeAll { $0.pid == window.pid }
            slots = slots.map { id in id.flatMap { id in windows.contains { $0.id == id } ? id : nil } }
        }
    }

    private func flash(_ text: String) {
        noticeTask?.cancel()
        withAnimation(.smooth) { notice = text }
        noticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.4))
            if !Task.isCancelled { withAnimation(.smooth) { self.notice = nil } }
        }
    }

    /// Small live pictures of the windows (only the larger panel shows them; needs Screen Recording).
    private func loadThumbnails() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
        for window in windows.prefix(12) {
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

/// A window being dragged between the list and the map, in the Arrange view's coordinate space.
struct ArrangeDrag: Equatable {
    let id: String
    var point: CGPoint
    /// The zone it came out of (nil = from the list).
    let fromZone: Int?
}

struct ArrangeMapFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private extension CGSize {
    var length: CGFloat { (width * width + height * height).squareRoot() }
}

/// 2 … 6: how many windows share the screen.
struct SplitCountPicker: View {
    @ObservedObject var model: ArrangeModel
    var idPrefix: String
    var large = false
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Array(TileLayouts.splitCounts), id: \.self) { count in
                let on = model.count == count
                Button { model.setCount(count) } label: {
                    Text("\(count)")
                        .font(.system(size: large ? 11.5 : 10.5, weight: .bold, design: .rounded))
                        .frame(width: large ? 28 : 21, height: large ? 22 : 18)
                        .foregroundStyle(on ? Color.white : Color.white.opacity(0.6))
                        .background {
                            if on { PlumageCapsule().matchedGeometryEffect(id: "count", in: selection) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Split the screen into \(count)")
                .accessibilityIdentifier("\(idPrefix).arrange.count.\(count)")
            }
        }
        .padding(1)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }
}

/// The layouts for the current split count.
struct ArrangeLayoutPicker: View {
    @ObservedObject var model: ArrangeModel
    let thumb: CGSize
    let columns: Int
    var idPrefix: String
    var showsNames = false

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(thumb.width), spacing: 6), count: columns),
                  alignment: .leading, spacing: showsNames ? 8 : 6) {
            ForEach(TileLayouts.arrange(for: model.count)) { item in
                let on = item == model.layout
                Button { model.choose(item) } label: {
                    VStack(spacing: 3) {
                        IslandLayoutThumb(layout: item, size: thumb, selected: on)
                        if showsNames {
                            Text(item.name)
                                .font(.system(size: 9.5, weight: on ? .semibold : .medium))
                                .foregroundStyle(.white.opacity(on ? 0.9 : 0.55))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.name)
                .accessibilityIdentifier("\(idPrefix).arrange.layout.\(item.id)")
            }
        }
        .frame(width: thumb.width * CGFloat(columns) + 6 * CGFloat(columns - 1), alignment: .leading)
    }
}

/// The screen in miniature with numbered zones and the windows in them. Click a zone, then
/// another, to swap them (or click a zone, then a window in the list, to put it there); dragging
/// works too.
struct ArrangeMap: View {
    @ObservedObject var model: ArrangeModel
    let size: CGSize
    /// The Arrange view's coordinate space: drags report their location in it.
    let space: String
    var idPrefix: String
    var large = false
    var drag: ArrangeDrag?
    var dropTarget: Int?
    let onDrag: (ArrangeDrag) -> Void
    let onDrop: (ArrangeDrag) -> Void
    @State private var hovered: Int?

    static func inset(large: Bool) -> CGFloat { large ? 8 : 6 }

    static func rects(_ layout: TileLayout, in size: CGSize, large: Bool) -> [CGRect] {
        layout.tiles.map { LayoutThumb.zone($0, in: size, inset: inset(large: large), gap: inset(large: large)) }
    }

    /// The zone under a point given in the Arrange view's space (`mapFrame` is the map in that space).
    static func zone(at point: CGPoint, mapFrame: CGRect, layout: TileLayout, large: Bool) -> Int? {
        guard mapFrame.width > 0, mapFrame.insetBy(dx: -2, dy: -2).contains(point) else { return nil }
        let local = CGPoint(x: point.x - mapFrame.minX, y: point.y - mapFrame.minY)
        return IslandLayoutThumb.zoneIndex(at: local, in: rects(layout, in: mapFrame.size, large: large), slack: inset(large: large) / 2 + 1)
    }

    var body: some View {
        let rects = Self.rects(model.layout, in: size, large: large)
        let corner: CGFloat = large ? 14 : 11
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(LinearGradient(colors: [Plumage.wingLight.opacity(0.10), Plumage.tail.opacity(0.10)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
            ForEach(Array(rects.enumerated()), id: \.offset) { index, rect in
                zoneView(index: index, size: rect.size)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            var next: Int?
            if case .active(let point) = phase {
                next = IslandLayoutThumb.zoneIndex(at: point, in: rects, slack: Self.inset(large: large) / 2 + 1)
            }
            if next != hovered { withAnimation(.easeOut(duration: 0.1)) { hovered = next } }
        }
        .background(GeometryReader { geo in
            Color.clear.preference(key: ArrangeMapFrameKey.self, value: geo.frame(in: .named(space)))
        })
    }

    @ViewBuilder
    private func zoneView(index: Int, size: CGSize) -> some View {
        let id = model.windowID(inZone: index)
        let window = model.window(id)
        let zone = ArrangeZone(number: index + 1, window: window,
                               thumbnail: large ? id.flatMap { model.thumbnails[$0] } : nil,
                               large: large,
                               hovered: hovered == index && drag == nil,
                               picked: model.pickedZone == index,
                               targeted: dropTarget == index && drag?.fromZone != index,
                               dimmed: drag != nil && drag?.id == id,
                               onTakeOut: large ? { model.takeOut(zone: index) } : nil)
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(gesture(zone: index))
            .help(window.map { "\($0.appName) — click, then click another zone to swap; or drag" }
                  ?? "Zone \(index + 1) — click it, then a window in the list")
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("\(idPrefix).arrange.zone.\(index)")
        if large, let window {
            zone.contextMenu {
                Button("Take Out of Layout") { model.takeOut(zone: index) }
                Button("Bring to Front") { WindowTiler.shared.raise(window) }
                Divider()
                Button("Quit \(window.appName)") { model.quitApp(of: window) }
            }
        } else {
            zone
        }
    }

    /// One gesture for both: a press that doesn't move is a click, otherwise a drag.
    private func gesture(zone index: Int) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { value in
                guard value.translation.length > 4, let id = model.windowID(inZone: index) else { return }
                onDrag(ArrangeDrag(id: id, point: value.location, fromZone: index))
            }
            .onEnded { value in
                if value.translation.length > 4 {
                    if let id = model.windowID(inZone: index) {
                        onDrop(ArrangeDrag(id: id, point: value.location, fromZone: index))
                    }
                } else {
                    model.tapZone(index)
                }
            }
    }
}

/// One zone of the map: its number and the window in it (a live picture in the larger panel).
private struct ArrangeZone: View {
    let number: Int
    let window: WindowInfo?
    let thumbnail: NSImage?
    let large: Bool
    let hovered: Bool
    let picked: Bool
    let targeted: Bool
    let dimmed: Bool
    var onTakeOut: (() -> Void)?

    private var corner: CGFloat { large ? 10 : 7 }

    var body: some View {
        GeometryReader { geo in
            let roomy = geo.size.width >= (large ? 120 : 62) && geo.size.height >= (large ? 56 : 30)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: corner, style: .continuous).fill(fill)
                if let thumbnail, window != nil {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .overlay(LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom))
                        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                        .opacity(dimmed ? 0.3 : 0.9)
                }
                content(roomy: roomy, size: geo.size)
                    .opacity(dimmed ? 0.35 : 1)
            }
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(stroke, style: StrokeStyle(lineWidth: picked || targeted ? 1.6 : (hovered ? 1.2 : 0.8),
                                                         dash: window == nil && !picked && !targeted ? [4, 3] : [])))
            .overlay(alignment: .topTrailing) {
                if let onTakeOut, window != nil, hovered {
                    Button(action: onTakeOut) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .padding(5)
                    .help("Take out of the layout")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .scaleEffect(picked ? 0.97 : 1)
            .shadow(color: picked ? Plumage.wingDeep.opacity(0.55) : .clear, radius: picked ? 8 : 0)
        }
    }

    private var fill: AnyShapeStyle {
        if targeted { return AnyShapeStyle(Plumage.sheen(0.42)) }
        if picked { return AnyShapeStyle(Plumage.sheen(0.32)) }
        if hovered { return AnyShapeStyle(Color.white.opacity(window == nil ? 0.08 : 0.16)) }
        return AnyShapeStyle(Color.white.opacity(window == nil ? 0.03 : 0.10))
    }

    private var stroke: Color {
        if picked || targeted { return Plumage.wingLight }
        if hovered { return Plumage.wingLight.opacity(0.6) }
        return Color.white.opacity(0.22)
    }

    @ViewBuilder
    private func content(roomy: Bool, size: CGSize) -> some View {
        if let window {
            if roomy {
                VStack(alignment: .leading, spacing: 3) {
                    ZoneBadge(number: number, filled: true, large: large)
                    Spacer(minLength: 0)
                    HStack(spacing: 5) {
                        AppIconView(bundleID: window.bundleID, size: large ? 20 : 15)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(window.appName).font(.system(size: large ? 11 : 9.5, weight: .semibold)).lineLimit(1)
                            if large, !window.title.isEmpty {
                                Text(window.title).font(.system(size: 9)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                            }
                        }
                    }
                }
                .padding(large ? 7 : 5)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
            } else {
                ZStack(alignment: .topLeading) {
                    AppIconView(bundleID: window.bundleID, size: min(18, max(12, min(size.width, size.height) * 0.45)))
                        .frame(width: size.width, height: size.height)
                    ZoneBadge(number: number, filled: true, large: false).padding(3)
                }
            }
        } else {
            VStack(spacing: 3) {
                ZoneBadge(number: number, filled: false, large: large)
                if roomy {
                    Text(picked ? "Now click a window" : (large ? "Click a window to add it" : "Empty"))
                        .font(.system(size: large ? 10.5 : 9, weight: .medium))
                        .foregroundStyle(.white.opacity(picked ? 0.85 : 0.45))
                        .lineLimit(1)
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }
}

/// The zone number: filled with the plumage sheen when a window is in the zone.
struct ZoneBadge: View {
    let number: Int
    var filled: Bool
    var large = false

    var body: some View {
        let d: CGFloat = large ? 18 : 14
        Text("\(number)")
            .font(.system(size: large ? 10.5 : 8.5, weight: .heavy, design: .rounded))
            .foregroundStyle(filled ? Plumage.eye : Color.white.opacity(0.7))
            .frame(width: d, height: d)
            .background(Circle().fill(filled ? AnyShapeStyle(Plumage.sheen(1)) : AnyShapeStyle(Color.white.opacity(0.12))))
            .overlay(Circle().strokeBorder(Color.white.opacity(filled ? 0.5 : 0.25), lineWidth: 0.5))
    }
}

/// The windows you can arrange, front-most first. Click one to put it in the next empty zone (or
/// into the zone you clicked), click it again to take it out; the badge shows its zone. Rows can
/// also be dragged onto the map.
struct ArrangeWindowList: View {
    @ObservedObject var model: ArrangeModel
    let space: String
    var idPrefix: String
    var large = false
    var columns = 1
    var drag: ArrangeDrag?
    let onDrag: (ArrangeDrag) -> Void
    let onDrop: (ArrangeDrag) -> Void

    var body: some View {
        if model.windows.isEmpty {
            Text(AXIsProcessTrusted() ? "No windows to arrange on this desktop" : "Allow Accessibility for Hoverbird to arrange windows")
                .font(.system(size: large ? 11 : 10)).foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 2) {
                    ForEach(model.windows) { window in
                        ArrangeWindowRow(window: window, zone: model.zone(of: window.id), pickedZone: model.pickedZone,
                                         large: large, dimmed: drag?.id == window.id)
                            .gesture(gesture(for: window.id))
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityIdentifier("\(idPrefix).arrange.window.\(window.id)")
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func gesture(for id: String) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { value in
                guard value.translation.length > 4 else { return }
                onDrag(ArrangeDrag(id: id, point: value.location, fromZone: nil))
            }
            .onEnded { value in
                if value.translation.length > 4 {
                    onDrop(ArrangeDrag(id: id, point: value.location, fromZone: nil))
                } else {
                    model.tapWindow(id)
                }
            }
    }
}

private struct ArrangeWindowRow: View {
    let window: WindowInfo
    let zone: Int?
    let pickedZone: Int?
    let large: Bool
    let dimmed: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            badge
            AppIconView(bundleID: window.bundleID, size: large ? 18 : 15)
            Text(window.appName)
                .font(.system(size: large ? 11 : 10.5, weight: .semibold))
                .lineLimit(1)
                .layoutPriority(1)
            if !window.title.isEmpty {
                Text(window.title)
                    .font(.system(size: large ? 10 : 9.5))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if hovering {
                Text(hint)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(pickedZone != nil ? Plumage.wingLight : .white.opacity(0.55))
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: large ? 26 : 21)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(background))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(zone != nil ? Plumage.wingLight.opacity(0.35) : Color.white.opacity(hovering ? 0.12 : 0), lineWidth: 0.5))
        .opacity(dimmed ? 0.4 : 1)
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .help(window.title.isEmpty ? window.appName : "\(window.appName) — \(window.title)")
    }

    private var hint: String {
        if let pickedZone { return "→ Zone \(pickedZone + 1)" }
        return zone == nil ? "Add" : "Take out"
    }

    private var background: AnyShapeStyle {
        if zone != nil { return AnyShapeStyle(Plumage.sheen(hovering ? 0.24 : 0.16)) }
        return AnyShapeStyle(Color.white.opacity(hovering ? 0.08 : 0))
    }

    private var badge: some View {
        Group {
            if let zone {
                ZoneBadge(number: zone + 1, filled: true, large: large)
            } else {
                Circle()
                    .strokeBorder(Color.white.opacity(hovering ? 0.6 : 0.3), lineWidth: 1)
                    .overlay {
                        if hovering {
                            Image(systemName: "plus").font(.system(size: large ? 8 : 7, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .frame(width: large ? 18 : 14, height: large ? 18 : 14)
            }
        }
    }
}

/// What Arrange is waiting for, or what just happened.
struct ArrangeStatusText: View {
    @ObservedObject var model: ArrangeModel
    var large = false

    var body: some View {
        Text(text)
            .font(.system(size: large ? 11 : 10.5))
            .foregroundStyle(model.notice != nil ? Color.orange : (model.pickedZone != nil ? Plumage.wingLight : Color.white.opacity(0.55)))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.smooth, value: text)
    }

    private var text: String {
        if let notice = model.notice { return notice }
        if let zone = model.pickedZone {
            return large ? "Zone \(zone + 1) picked — click a zone to swap, or a window"
                : "Zone \(zone + 1) picked — click a zone or a window"
        }
        if model.placedCount == 0 { return "Click windows in the order you want them" }
        if model.applied { return "Arranged — swaps now move the windows too" }
        return "Drag or click two zones to swap them"
    }
}

private struct IslandArrangeView: View {
    @ObservedObject private var model = ArrangeModel.shared
    @State private var drag: ArrangeDrag?
    @State private var dropTarget: Int?
    @State private var mapFrame: CGRect = .zero

    private static let space = "islandArrange"
    private static let mapSize = CGSize(width: 176, height: 104)
    private static let pickerThumb = CGSize(width: 44, height: 28)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                WindowsSegments()
                ArrangeStatusText(model: model)
                GlassButton(title: "Arrange", symbol: "rectangle.split.2x2.fill", prominent: true) { model.apply() }
                    .help("Move the windows into their zones")
                    .accessibilityIdentifier("windows.arrange.apply")
                WindowsExpandButton()
            }
            .frame(height: 22)
            ZStack(alignment: .topLeading) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Text("Split").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                            SplitCountPicker(model: model, idPrefix: "island")
                        }
                        ArrangeLayoutPicker(model: model, thumb: Self.pickerThumb, columns: 3, idPrefix: "island")
                    }
                    .frame(width: 144, alignment: .topLeading)
                    ArrangeMap(model: model, size: Self.mapSize, space: Self.space, idPrefix: "island",
                               drag: drag, dropTarget: dropTarget, onDrag: dragChanged, onDrop: dropped)
                    VStack(alignment: .leading, spacing: 3) {
                        listHeader
                        ArrangeWindowList(model: model, space: Self.space, idPrefix: "island", drag: drag,
                                          onDrag: dragChanged, onDrop: dropped)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                if let drag, let window = model.window(drag.id) {
                    WindowChip(window: window)
                        .scaleEffect(1.06)
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                        .position(drag.point)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: Self.space)
            .onPreferenceChange(ArrangeMapFrameKey.self) { mapFrame = $0 }
            .frame(height: 104, alignment: .topLeading)
        }
        .onAppear { model.load(thumbnails: false) }
    }

    private var listHeader: some View {
        HStack(spacing: 8) {
            Text(model.placedCount == 0 ? "Windows" : "\(model.placedCount) of \(model.count) filled")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
            Spacer(minLength: 0)
            if model.slots.contains(where: { $0 == nil }), model.windows.count > model.placedCount {
                Button("Auto-fill") { model.autofill() }
                    .buttonStyle(.plain)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Plumage.wingLight)
                    .help("Fill the empty zones with your front-most windows")
                    .accessibilityIdentifier("windows.arrange.autofill")
            }
            if model.placedCount > 0 {
                Button("Clear") { model.clear() }
                    .buttonStyle(.plain)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Plumage.wingLight)
                    .help("Take every window out")
                    .accessibilityIdentifier("windows.arrange.clear")
            }
        }
        .frame(height: 13)
    }

    private func dragChanged(_ value: ArrangeDrag) {
        drag = value
        let target = ArrangeMap.zone(at: value.point, mapFrame: mapFrame, layout: model.layout, large: false)
        if target != dropTarget { withAnimation(.easeOut(duration: 0.12)) { dropTarget = target } }
    }

    private func dropped(_ value: ArrangeDrag) {
        ArrangeDropHandler.drop(value, on: model, mapFrame: mapFrame, large: false)
        drag = nil
        dropTarget = nil
    }
}

/// Where a dragged window lands: a zone (swap or place), or — dragged out of a zone — anywhere off
/// the map takes it out of the layout.
@MainActor
enum ArrangeDropHandler {
    static func drop(_ value: ArrangeDrag, on model: ArrangeModel, mapFrame: CGRect, large: Bool) {
        let target = ArrangeMap.zone(at: value.point, mapFrame: mapFrame, layout: model.layout, large: large)
        if let source = value.fromZone {
            if let target {
                model.move(fromZone: source, to: target)
            } else if !mapFrame.insetBy(dx: -6, dy: -6).contains(value.point) {
                model.move(fromZone: source, to: nil)
            }
        } else if let target {
            model.place(value.id, in: target)
        }
    }
}

/// A window as a small chip: app icon and name.
struct WindowChip: View {
    let window: WindowInfo

    var body: some View {
        HStack(spacing: 6) {
            AppIconView(bundleID: window.bundleID, size: 14)
            Text(window.appName).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 21)
        .background(Capsule().fill(Color.black.opacity(0.55)))
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
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
