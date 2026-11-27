//
//  WindowTiler.swift
//  Hoverbird
//
//  Snap and arrange windows like Windows' Snap Layouts, the macOS way: halves,
//  thirds, two-thirds, quarters and mixed layouts, with a frosted-glass preview
//  that glides from where the window is to where it's going before the window
//  settles into place (macOS doesn't let apps animate other apps' windows, so
//  the glass carries the motion — the same idea as macOS's own tiling preview).
//  Uses Accessibility (already granted).
//

import AppKit
import ApplicationServices
import SwiftUI

// MARK: - Layouts

/// A tile as a fraction of the screen's usable area, origin top-left.
struct Tile: Hashable {
    let x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
    init(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) { self.x = x; self.y = y; self.w = w; self.h = h }
}

struct TileLayout: Identifiable, Hashable {
    let id: String
    let name: String
    let tiles: [Tile]
    let names: [String]
}

enum TileLayouts {
    static let halves = TileLayout(id: "halves", name: "Halves", tiles: [Tile(0, 0, 0.5, 1), Tile(0.5, 0, 0.5, 1)],
                                   names: ["Left Half", "Right Half"])
    static let rows = TileLayout(id: "rows", name: "Top & Bottom", tiles: [Tile(0, 0, 1, 0.5), Tile(0, 0.5, 1, 0.5)],
                                 names: ["Top Half", "Bottom Half"])
    static let thirds = TileLayout(id: "thirds", name: "Thirds", tiles: [Tile(0, 0, 1 / 3, 1), Tile(1 / 3, 0, 1 / 3, 1), Tile(2 / 3, 0, 1 / 3, 1)],
                                   names: ["Left Third", "Center Third", "Right Third"])
    static let twoThirdsLeft = TileLayout(id: "twoThirdsLeft", name: "⅔ + ⅓", tiles: [Tile(0, 0, 2 / 3, 1), Tile(2 / 3, 0, 1 / 3, 1)],
                                          names: ["Left Two-Thirds", "Right Third"])
    static let twoThirdsRight = TileLayout(id: "twoThirdsRight", name: "⅓ + ⅔", tiles: [Tile(0, 0, 1 / 3, 1), Tile(1 / 3, 0, 2 / 3, 1)],
                                           names: ["Left Third", "Right Two-Thirds"])
    static let quarters = TileLayout(id: "quarters", name: "Quarters",
                                     tiles: [Tile(0, 0, 0.5, 0.5), Tile(0.5, 0, 0.5, 0.5), Tile(0, 0.5, 0.5, 0.5), Tile(0.5, 0.5, 0.5, 0.5)],
                                     names: ["Top Left", "Top Right", "Bottom Left", "Bottom Right"])
    static let halfAndQuarters = TileLayout(id: "halfQuarters", name: "Half + Quarters",
                                            tiles: [Tile(0, 0, 0.5, 1), Tile(0.5, 0, 0.5, 0.5), Tile(0.5, 0.5, 0.5, 0.5)],
                                            names: ["Left Half", "Top Right", "Bottom Right"])
    static let quartersAndHalf = TileLayout(id: "quartersHalf", name: "Quarters + Half",
                                            tiles: [Tile(0, 0, 0.5, 0.5), Tile(0, 0.5, 0.5, 0.5), Tile(0.5, 0, 0.5, 1)],
                                            names: ["Top Left", "Bottom Left", "Right Half"])
    static let topAndTwo = TileLayout(id: "topTwo", name: "Top + Two",
                                      tiles: [Tile(0, 0, 1, 0.5), Tile(0, 0.5, 0.5, 0.5), Tile(0.5, 0.5, 0.5, 0.5)],
                                      names: ["Top Half", "Bottom Left", "Bottom Right"])
    static let wideCenter = TileLayout(id: "wideCenter", name: "Wide Center",
                                       tiles: [Tile(0, 0, 0.25, 1), Tile(0.25, 0, 0.5, 1), Tile(0.75, 0, 0.25, 1)],
                                       names: ["Left Quarter", "Center Half", "Right Quarter"])
    static let twoAndBottom = TileLayout(id: "twoBottom", name: "Two + Bottom",
                                         tiles: [Tile(0, 0, 0.5, 0.5), Tile(0.5, 0, 0.5, 0.5), Tile(0, 0.5, 1, 0.5)],
                                         names: ["Top Left", "Top Right", "Bottom Half"])
    static let columns4 = TileLayout(id: "columns4", name: "4 Columns",
                                     tiles: [Tile(0, 0, 0.25, 1), Tile(0.25, 0, 0.25, 1), Tile(0.5, 0, 0.25, 1), Tile(0.75, 0, 0.25, 1)],
                                     names: ["First Column", "Second Column", "Third Column", "Fourth Column"])
    static let mainAndThree = TileLayout(id: "mainThree", name: "Main + 3",
                                         tiles: [Tile(0, 0, 0.5, 1), Tile(0.5, 0, 0.5, 1 / 3), Tile(0.5, 1 / 3, 0.5, 1 / 3),
                                                 Tile(0.5, 2 / 3, 0.5, 1 / 3)],
                                         names: ["Left Half", "Right Top", "Right Middle", "Right Bottom"])
    static let topAndThree = TileLayout(id: "topThree", name: "Top + 3",
                                        tiles: [Tile(0, 0, 1, 0.5), Tile(0, 0.5, 1 / 3, 0.5), Tile(1 / 3, 0.5, 1 / 3, 0.5),
                                                Tile(2 / 3, 0.5, 1 / 3, 0.5)],
                                        names: ["Top Half", "Bottom Left", "Bottom Center", "Bottom Right"])
    static let twoOverThree = TileLayout(id: "twoThree", name: "2 + 3",
                                         tiles: [Tile(0, 0, 0.5, 0.5), Tile(0.5, 0, 0.5, 0.5),
                                                 Tile(0, 0.5, 1 / 3, 0.5), Tile(1 / 3, 0.5, 1 / 3, 0.5), Tile(2 / 3, 0.5, 1 / 3, 0.5)],
                                         names: ["Top Left", "Top Right", "Bottom Left", "Bottom Center", "Bottom Right"])
    static let threeOverTwo = TileLayout(id: "threeTwo", name: "3 + 2",
                                         tiles: [Tile(0, 0, 1 / 3, 0.5), Tile(1 / 3, 0, 1 / 3, 0.5), Tile(2 / 3, 0, 1 / 3, 0.5),
                                                 Tile(0, 0.5, 0.5, 0.5), Tile(0.5, 0.5, 0.5, 0.5)],
                                         names: ["Top Left", "Top Center", "Top Right", "Bottom Left", "Bottom Right"])
    static let mainAndFour = TileLayout(id: "mainFour", name: "Main + 4",
                                        tiles: [Tile(0, 0, 0.5, 1), Tile(0.5, 0, 0.25, 0.5), Tile(0.75, 0, 0.25, 0.5),
                                                Tile(0.5, 0.5, 0.25, 0.5), Tile(0.75, 0.5, 0.25, 0.5)],
                                        names: ["Left Half", "Top Middle", "Top Right", "Bottom Middle", "Bottom Right"])
    static let grid3x2 = TileLayout(id: "grid3x2", name: "3 × 2",
                                    tiles: [Tile(0, 0, 1 / 3, 0.5), Tile(1 / 3, 0, 1 / 3, 0.5), Tile(2 / 3, 0, 1 / 3, 0.5),
                                            Tile(0, 0.5, 1 / 3, 0.5), Tile(1 / 3, 0.5, 1 / 3, 0.5), Tile(2 / 3, 0.5, 1 / 3, 0.5)],
                                    names: ["Top Left", "Top Center", "Top Right", "Bottom Left", "Bottom Center", "Bottom Right"])
    static let grid2x3 = TileLayout(id: "grid2x3", name: "2 × 3",
                                    tiles: [Tile(0, 0, 0.5, 1 / 3), Tile(0.5, 0, 0.5, 1 / 3), Tile(0, 1 / 3, 0.5, 1 / 3),
                                            Tile(0.5, 1 / 3, 0.5, 1 / 3), Tile(0, 2 / 3, 0.5, 1 / 3), Tile(0.5, 2 / 3, 0.5, 1 / 3)],
                                    names: ["Top Left", "Top Right", "Middle Left", "Middle Right", "Bottom Left", "Bottom Right"])
    static let fill = TileLayout(id: "fill", name: "Fill", tiles: [Tile(0, 0, 1, 1)], names: ["Fill Screen"])
    static let center = TileLayout(id: "center", name: "Center", tiles: [Tile(0.17, 0.1, 0.66, 0.8)], names: ["Center"])
    static let almost = TileLayout(id: "almost", name: "Almost Full", tiles: [Tile(0.04, 0.04, 0.92, 0.92)], names: ["Almost Full"])

    /// Snap Layouts grid (click a zone to put the front window there).
    static let snap: [TileLayout] = [halves, rows, thirds, twoThirdsLeft, twoThirdsRight, quarters,
                                     halfAndQuarters, quartersAndHalf, topAndTwo, wideCenter, fill, center]

    /// How many windows Arrange can split the screen into.
    static let splitCounts = 2...6

    /// Arrange layouts for each split count; the first one is the default for that count.
    static let arrangeByCount: [Int: [TileLayout]] = [
        2: [halves, rows, twoThirdsLeft, twoThirdsRight],
        3: [thirds, halfAndQuarters, quartersAndHalf, topAndTwo, twoAndBottom, wideCenter],
        4: [quarters, columns4, mainAndThree, topAndThree],
        5: [twoOverThree, threeOverTwo, mainAndFour],
        6: [grid3x2, grid2x3],
    ]

    static func arrange(for count: Int) -> [TileLayout] {
        arrangeByCount[min(max(count, splitCounts.lowerBound), splitCounts.upperBound)] ?? [halves]
    }

    static func preferred(for count: Int) -> TileLayout { arrange(for: count)[0] }
}

// MARK: - Windows

struct WindowInfo: Identifiable, Equatable {
    let id: String
    let pid: pid_t
    let windowNumber: CGWindowID?
    let appName: String
    let bundleID: String?
    let title: String
    let element: AXUIElement
    /// In macOS full screen (its own Space) — it leaves full screen before it's tiled.
    var isFullScreen = false

    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool { lhs.id == rhs.id && lhs.title == rhs.title }
}

@MainActor
final class WindowTiler: ObservableObject {
    static let shared = WindowTiler()

    /// Gap between tiles and around the edges (macOS tiling uses margins too).
    static let gap: CGFloat = 8

    /// The last app you used (Hoverbird's own popover doesn't count).
    private(set) var lastUserApp: NSRunningApplication?
    private var previousFrames: [String: CGRect] = [:]
    private var observer: Any?

    private init() {
        lastUserApp = NSWorkspace.shared.frontmostApplication.flatMap { $0.processIdentifier == getpid() ? nil : $0 }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != getpid() else { return }
            MainActor.assumeIsolated { WindowTiler.shared.lastUserApp = app }
        }
    }

    func start() { _ = lastUserApp }

    // MARK: Front window

    func frontWindow() -> WindowInfo? {
        guard AXIsProcessTrusted() else { return nil }
        let app = (NSWorkspace.shared.frontmostApplication.flatMap { $0.processIdentifier == getpid() ? nil : $0 }) ?? lastUserApp
        guard let app, !app.isTerminated else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        let candidates = AX.elements(element, kAXFocusedWindowAttribute as String) + AX.elements(element, kAXMainWindowAttribute as String)
            + AX.elements(element, kAXWindowsAttribute as String)
        guard let window = candidates.first(where: isTileable) else { return nil }
        return info(for: window, app: app)
    }

    /// Standard, resizable-looking windows on the current Space, front to back.
    func windows() -> [WindowInfo] {
        guard AXIsProcessTrusted() else { return [] }
        var result: [WindowInfo] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isHidden && !app.isTerminated {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.3)
            // Windows on this Space, plus the app's main / focused window — full-screen windows sit
            // on their own Space and only show up there.
            var seen: [AXUIElement] = []
            let candidates = AX.elements(element, kAXWindowsAttribute as String)
                + AX.elements(element, kAXMainWindowAttribute as String) + AX.elements(element, kAXFocusedWindowAttribute as String)
            for window in candidates where isTileable(window) && !seen.contains(where: { CFEqual($0, window) }) {
                seen.append(window)
                result.append(info(for: window, app: app))
            }
        }
        // Front-to-back order from the window server.
        let order = Self.zOrder()
        return result.sorted { (order[$0.windowNumber ?? 0] ?? Int.max) < (order[$1.windowNumber ?? 0] ?? Int.max) }
    }

    private func isTileable(_ window: AXUIElement) -> Bool {
        guard AX.subrole(window) == (kAXStandardWindowSubrole as String) else { return false }
        if (AX.attribute(window, kAXMinimizedAttribute as String) as? Bool) == true { return false }
        guard let size = AX.size(window) else { return false }
        return size.width >= 160 && size.height >= 100
    }

    private func info(for window: AXUIElement, app: NSRunningApplication) -> WindowInfo {
        let number = Self.windowNumber(of: window)
        let title = AX.string(window, kAXTitleAttribute as String) ?? ""
        return WindowInfo(id: "\(app.processIdentifier)-\(number.map(String.init) ?? title)", pid: app.processIdentifier,
                          windowNumber: number, appName: app.localizedName ?? "App", bundleID: app.bundleIdentifier,
                          title: title, element: window, isFullScreen: Self.isFullScreen(window))
    }

    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let getWindow: GetWindow? = {
        guard let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW),
              let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindow.self)
    }()

    private static func windowNumber(of window: AXUIElement) -> CGWindowID? {
        var number: CGWindowID = 0
        guard let getWindow, getWindow(window, &number) == .success, number != 0 else { return nil }
        return number
    }

    private static func zOrder() -> [CGWindowID: Int] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var order: [CGWindowID: Int] = [:]
        for (index, entry) in list.enumerated() {
            if let number = entry[kCGWindowNumber as String] as? CGWindowID { order[number] = index }
        }
        return order
    }

    // MARK: Geometry

    /// Cocoa (bottom-left) frame of a tile on a screen.
    static func frame(for tile: Tile, on screen: NSScreen) -> CGRect {
        let area = screen.visibleFrame.insetBy(dx: gap / 2, dy: gap / 2)
        let raw = CGRect(x: area.minX + area.width * tile.x,
                         y: area.maxY - area.height * (tile.y + tile.h),
                         width: area.width * tile.w,
                         height: area.height * tile.h)
        return raw.insetBy(dx: gap / 2, dy: gap / 2).integral
    }

    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// Current Cocoa frame of a window.
    static func cocoaFrame(of window: AXUIElement) -> CGRect? {
        guard let position = AX.position(window), let size = AX.size(window) else { return nil }
        return CGRect(x: position.x, y: primaryHeight - position.y - size.height, width: size.width, height: size.height)
    }

    static func screen(for frame: CGRect) -> NSScreen {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Moves + resizes a window to a Cocoa frame (size, position, size: apps clamp differently).
    static func setFrame(_ window: AXUIElement, pid: pid_t, to frame: CGRect) {
        let app = AXUIElementCreateApplication(pid)
        // Some apps animate AX frame changes slowly while "enhanced UI" is on — switch it off briefly.
        let enhanced = (AX.attribute(app, "AXEnhancedUserInterface") as? Bool) == true
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        var size = frame.size
        var origin = CGPoint(x: frame.minX, y: primaryHeight - frame.maxY)
        if let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) }
        if let value = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) }
        if let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) }
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
    }

    static func isFullScreen(_ window: AXUIElement) -> Bool {
        (AX.attribute(window, "AXFullScreen") as? Bool) == true
    }

    /// A full-screen window can't be moved — take it out of full screen first (like macOS tiling does).
    private static func leaveFullScreenIfNeeded(_ window: AXUIElement) async {
        guard isFullScreen(window) else { return }
        AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(80))
            if !isFullScreen(window) { break }
        }
        try? await Task.sleep(for: .milliseconds(450)) // the exit animation finishes
    }

    // MARK: Actions

    /// Puts the front window into a tile (glass preview glides there first).
    func snapFront(to tile: Tile) {
        guard let window = frontWindow() else {
            IslandActivityHub.shared.showPill(.info(symbol: "macwindow", text: "No window to snap", tint: .orange), duration: 2)
            return
        }
        snap(window, to: tile)
    }

    func snap(_ window: WindowInfo, to tile: Tile, on screen: NSScreen? = nil) {
        Task { @MainActor in
            await Self.leaveFullScreenIfNeeded(window.element)
            guard let start = Self.cocoaFrame(of: window.element) else { return }
            let display = screen ?? Self.screen(for: start)
            let target = Self.frame(for: tile, on: display)
            // Restore goes back to where it was before you started snapping it around.
            if previousFrames[window.id] == nil { previousFrames[window.id] = start }
            SnapOverlay.shared.animate([(start, target)]) {
                Self.setFrame(window.element, pid: window.pid, to: target)
            }
        }
    }

    /// Back to where it was before the last snap.
    func restoreFront() {
        guard let window = frontWindow(), let previous = previousFrames[window.id],
              let start = Self.cocoaFrame(of: window.element) else { return }
        previousFrames[window.id] = nil
        SnapOverlay.shared.animate([(start, previous)]) {
            Self.setFrame(window.element, pid: window.pid, to: previous)
        }
    }

    /// Lays out several windows at once (first window → first tile…), then brings them forward.
    func arrange(_ layout: TileLayout, windows: [WindowInfo?], on screen: NSScreen? = nil) {
        Task { @MainActor in await arrangeNow(layout, windows: windows, on: screen) }
    }

    private func arrangeNow(_ layout: TileLayout, windows: [WindowInfo?], on screen: NSScreen?) async {
        let display = screen ?? NSScreen.main ?? NSScreen.screens[0]
        for case let window? in windows.prefix(layout.tiles.count) { await Self.leaveFullScreenIfNeeded(window.element) }
        var moves: [(window: WindowInfo, from: CGRect, to: CGRect)] = []
        for (tile, window) in zip(layout.tiles, windows) {
            guard let window, let start = Self.cocoaFrame(of: window.element) else { continue }
            let target = Self.frame(for: tile, on: display)
            if previousFrames[window.id] == nil { previousFrames[window.id] = start }
            moves.append((window, start, target))
        }
        guard !moves.isEmpty else { return }
        SnapOverlay.shared.animate(moves.map { ($0.from, $0.to) }) {
            for move in moves { Self.setFrame(move.window.element, pid: move.window.pid, to: move.to) }
            // Raise them back-to-front so the first tile's window ends up in front.
            for move in moves.reversed() { AXUIElementPerformAction(move.window.element, kAXRaiseAction as CFString) }
            if let first = moves.first, let app = NSRunningApplication(processIdentifier: first.window.pid) {
                app.activate()
            }
        }
    }

    func raise(_ window: WindowInfo) {
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: window.pid)?.activate()
    }
}

// MARK: - Frosted-glass snap preview

@MainActor
final class SnapOverlay {
    static let shared = SnapOverlay()

    final class Model: ObservableObject {
        @Published var rects: [CGRect] = []
        @Published var visible = false
    }

    private let model = Model()
    private var panel: NSPanel?
    private var generation = 0

    /// Glass panels glide from each window's frame to its target; `apply` moves the real windows
    /// underneath just before the glass fades away.
    func animate(_ moves: [(from: CGRect, to: CGRect)], apply: @escaping () -> Void) {
        guard let first = moves.first else { return }
        let screen = WindowTiler.screen(for: first.to)
        let panel = makePanel(on: screen)
        generation += 1
        let current = generation
        func local(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
        var noAnimation = Transaction()
        noAnimation.disablesAnimations = true
        withTransaction(noAnimation) {
            model.rects = moves.map { local($0.from) }
            model.visible = false
        }
        panel.orderFrontRegardless()
        withAnimation(.easeOut(duration: 0.1)) { model.visible = true }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { model.rects = moves.map { local($0.to) } }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(240))
            apply()
            try? await Task.sleep(for: .milliseconds(110))
            guard current == self.generation else { return }
            withAnimation(.easeIn(duration: 0.2)) { self.model.visible = false }
            try? await Task.sleep(for: .milliseconds(240))
            if current == self.generation { panel.orderOut(nil) }
        }
    }

    private func makePanel(on screen: NSScreen) -> NSPanel {
        if let panel {
            if panel.frame != screen.frame { panel.setFrame(screen.frame, display: false) }
            return panel
        }
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingView(rootView: SnapOverlayView(model: model))
        host.frame = CGRect(origin: .zero, size: screen.frame.size)
        panel.contentView = host
        self.panel = panel
        return panel
    }
}

private struct SnapOverlayView: View {
    @ObservedObject var model: SnapOverlay.Model

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(model.rects.enumerated()), id: \.offset) { _, rect in
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.4), lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 22, y: 8)
                    .frame(width: max(1, rect.width), height: max(1, rect.height))
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(model.visible ? 1 : 0)
        .allowsHitTesting(false)
    }
}
