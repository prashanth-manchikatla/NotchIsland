//
//  FSEventsWatcher.swift
//  NotchIsland · Shared
//
//  FSEvents on a few folders: the kernel tells us which files changed (coalesced over
//  `latency` seconds), so nothing polls. Used by AI Usage (agent logs) and Downloads.
//

import CoreServices
import Foundation

final class FSEventsWatcher {
    private var stream: FSEventStreamRef?
    private let paths: [String]
    private let latency: CFTimeInterval
    private let queue: DispatchQueue
    private let onChange: ([String]) -> Void

    init(paths: [String], latency: CFTimeInterval, queue: DispatchQueue, onChange: @escaping ([String]) -> Void) {
        self.paths = paths
        self.latency = latency
        self.queue = queue
        self.onChange = onChange
    }

    deinit { stop() }

    func start() {
        guard stream == nil, !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
            if !changed.isEmpty { watcher.onChange(changed) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}
