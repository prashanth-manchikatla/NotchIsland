//
//  DownloadsAndDrives.swift
//  NotchIsland · Files
//
//  • A download finishes (any browser or app) → "Downloaded report.pdf" in the island, and the
//    file goes on the Shelf so you can drag it straight where it's needed. FSEvents on
//    ~/Downloads; in-progress files (.crdownload, .download, .part…) are ignored until done.
//  • A drive is connected / ejected → a pill; eject it from the menu bar ("Safe to remove").
//

import AppKit
import Combine
import Defaults
import SwiftUI

extension Defaults.Keys {
    static let downloadAlerts = Key<Bool>("downloadAlerts", default: true)
    static let downloadsToShelf = Key<Bool>("downloadsToShelf", default: true)
    static let driveAlerts = Key<Bool>("driveAlerts", default: true)
}

@MainActor
final class DownloadsWatcher {
    static let shared = DownloadsWatcher()
    private var watcher: FSEventsWatcher?
    private var announced: [String: Date] = [:]
    private let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

    private static let partial: Set<String> = ["crdownload", "download", "part", "partial", "tmp", "opdownload", "aria2", "!ut", "dtapart", "crswap"]

    private init() {}

    func start() {
        guard watcher == nil, let folder else { return }
        let w = FSEventsWatcher(paths: [folder.path], latency: 1.0, queue: .main) { paths in
            MainActor.assumeIsolated { DownloadsWatcher.shared.changed(paths) }
        }
        w.start()
        watcher = w
    }

    /// Something changed in Downloads. The folder is listed (top level only) rather than trusting the
    /// event paths: FSEvents may report a rename or a burst of changes as the folder itself.
    private func changed(_ paths: [String]) {
        guard Defaults[.downloadAlerts] || Defaults[.downloadsToShelf], let folder else { return }
        let keys: [URLResourceKey] = [.isRegularFileKey, .creationDateKey, .fileSizeKey]
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                     options: [.skipsHiddenFiles])) ?? []
        let now = Date()
        for url in entries {
            guard announced[url.path] == nil, !Self.partial.contains(url.pathExtension.lowercased()),
                  !url.lastPathComponent.hasPrefix("AI Usage – "),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  (values.fileSize ?? 0) > 0, now.timeIntervalSince(values.creationDate ?? .distantPast) < 180 else { continue }
            announced[url.path] = now
            confirmFinished(url, size: values.fileSize ?? 0)
        }
        announced = announced.filter { now.timeIntervalSince($0.value) < 600 }
    }

    /// The size must hold still for a moment (some apps write in place).
    private func confirmFinished(_ url: URL, size: Int) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            // Fresh from the file system (URL resource values are cached on the URL).
            let now = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? -1
            guard now == size else { announced[url.path] = nil; return }
            if Defaults[.downloadsToShelf], Defaults[.boringShelf], let bookmark = try? Bookmark(url: url) {
                ShelfStateViewModel.shared.add([ShelfItem(kind: .file(bookmark: bookmark.data))])
            }
            if Defaults[.downloadAlerts] { IslandActivityHub.shared.showPill(.download(url), duration: 3.5) }
        }
    }
}

@MainActor
final class DrivesMonitor: ObservableObject {
    static let shared = DrivesMonitor()
    /// Ejectable volumes (USB drives, SD cards, disk images).
    @Published private(set) var drives: [URL] = []
    private var observers: [Any] = []

    private init() {}

    func start() {
        guard observers.isEmpty else { return }
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { note in
            let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated {
                let monitor = DrivesMonitor.shared
                monitor.refresh()
                guard Defaults[.driveAlerts], let url, monitor.drives.contains(url) else { return }
                IslandActivityHub.shared.showPill(.info(symbol: "externaldrive.fill", text: "“\(Self.name(url))” connected", tint: .white), duration: 2.6)
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DrivesMonitor.shared.refresh() }
        })
    }

    func refresh() {
        let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        drives = volumes.filter { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return false }
            return v.volumeIsEjectable == true || (v.volumeIsRemovable == true && v.volumeIsInternal != true)
        }
    }

    func eject(_ url: URL) {
        let name = Self.name(url)
        Task.detached(priority: .userInitiated) {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                await MainActor.run {
                    IslandActivityHub.shared.showPill(.info(symbol: "checkmark.circle.fill", text: "Safe to remove “\(name)”", tint: .green), duration: 2.8)
                }
            } catch {
                await MainActor.run {
                    IslandActivityHub.shared.showPill(.info(symbol: "exclamationmark.triangle.fill", text: "“\(name)” is in use — close its files first", tint: .orange), duration: 3.2)
                }
            }
        }
    }

    nonisolated static func name(_ url: URL) -> String {
        (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? url.lastPathComponent
    }
}
