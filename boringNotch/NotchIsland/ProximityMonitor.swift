//
//  ProximityMonitor.swift
//  NotchIsland
//
//  Makes the island easy to reach:
//   • As the pointer approaches the notch the compact pill swells slightly
//     ("it noticed you"), like an iPhone island reacting to a touch.
//   • Pushing the pointer against the top edge right at the notch opens the
//     island instantly — the top edge is an infinitely tall target, so this
//     is the fastest possible way to open it.
//
//  Cost: one cheap global mouse-moved monitor. Work per event is a few float
//  comparisons, and SwiftUI is only notified when the state actually changes.
//

import AppKit
import Combine
import Defaults

@MainActor
final class ProximityMonitor: ObservableObject {
    static let shared = ProximityMonitor()

    /// Display UUID whose notch the pointer is currently near (nil = none).
    @Published private(set) var nearScreenUUID: String?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var screenObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var zones: [(uuid: String, near: CGRect, edge: CGRect)] = []
    private var lastEdgeFire: Date = .distantPast
    private var lastEdgeUUID: String?
    private var growEnabled = true
    private var edgeEnabled = true

    private init() {
        Publishers.CombineLatest3(
            Defaults.publisher(.islandProximityGrow).map(\.newValue),
            Defaults.publisher(.islandTopEdgeOpen).map(\.newValue),
            Defaults.publisher(.islandProximityDistance).map(\.newValue)
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] grow, edge, _ in
            guard let self else { return }
            self.growEnabled = grow
            self.edgeEnabled = edge
            self.rebuildZones()
            if grow || edge { self.start() } else { self.stop() }
        }
        .store(in: &cancellables)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildZones() }
        }
        NotificationCenter.default.publisher(for: .notchHeightChanged)
            .sink { [weak self] _ in Task { @MainActor in self?.rebuildZones() } }
            .store(in: &cancellables)
    }

    func start() {
        guard globalMonitor == nil else { return }
        rebuildZones()
        // Event monitors are delivered on the main thread.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.handle(location) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.handle(location) }
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        if nearScreenUUID != nil { nearScreenUUID = nil }
    }

    private func rebuildZones() {
        let distance = CGFloat(Defaults[.islandProximityDistance])
        zones = NSScreen.screens.compactMap { screen in
            guard let uuid = screen.displayUUID else { return nil }
            let size = getClosedNotchSize(screenUUID: uuid)
            let frame = screen.frame
            let notch = CGRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height,
                               width: size.width, height: size.height)
            let near = notch.insetBy(dx: -distance, dy: 0)
                .union(CGRect(x: notch.minX - distance, y: notch.minY - distance,
                              width: notch.width + 2 * distance, height: distance))
            // The 2-point strip along the top edge directly above the notch.
            let edge = CGRect(x: notch.minX + 6, y: frame.maxY - 2, width: notch.width - 12, height: 3)
            return (uuid, near, edge)
        }
    }

    private func handle(_ point: CGPoint) {
        var newNear: String?
        for zone in zones {
            if edgeEnabled, zone.edge.contains(point) {
                fireEdge(zone.uuid)
            }
            if zone.near.contains(point) {
                newNear = zone.uuid
                break
            }
        }
        if !growEnabled { newNear = nil }
        if newNear != nearScreenUUID { nearScreenUUID = newNear }
        if newNear == nil { lastEdgeUUID = nil }
    }

    private func fireEdge(_ uuid: String) {
        // Fire once per approach; re-arm after the pointer leaves the zone.
        guard lastEdgeUUID != uuid || Date().timeIntervalSince(lastEdgeFire) > 1.2 else { return }
        lastEdgeUUID = uuid
        lastEdgeFire = Date()
        NotificationCenter.default.post(name: .islandTopEdgeHit, object: uuid)
    }
}

extension Notification.Name {
    /// Posted (object: display UUID) when the pointer is pushed against the top edge at the notch.
    static let islandTopEdgeHit = Notification.Name("NotchIsland.topEdgeHit")
}
