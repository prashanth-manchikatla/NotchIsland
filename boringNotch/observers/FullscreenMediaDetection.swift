//
//  FullscreenMediaDetection.swift
//  boringNotch
//
//  Created by Richard Kunkli on 06/09/2024.
//

import Foundation
import Combine
import Defaults
import MacroVisionKit

@MainActor
final class FullscreenMediaDetector: ObservableObject {
    static let shared = FullscreenMediaDetector()
    
    @Published var fullscreenStatus: [String: Bool] = [:]
    /// Hoverbird: apps in the full-screen Spaces showing right now (for Cinema mode).
    @Published private(set) var fullScreenApps: Set<String> = []
    
    private var monitorTask: Task<Void, Never>?
    private var lastSpaces: [MacroVisionKit.FullScreenMonitor.SpaceInfo] = []
    private var musicSource: AnyCancellable?
    
    private init() {
        startMonitoring()
        // Hoverbird: pressing play after going full screen changes the media app — re-check
        // then too, not only when Spaces change.
        musicSource = MusicManager.shared.$bundleIdentifier
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateStatus(with: self.lastSpaces)
            }
    }
    
    deinit {
        monitorTask?.cancel()
    }
    
    private func startMonitoring() {
        monitorTask = Task { @MainActor in
            let stream = await FullScreenMonitor.shared.spaceChanges()
            for await spaces in stream {
                updateStatus(with: spaces)
            }
        }
    }
    
    private func updateStatus(with spaces: [MacroVisionKit.FullScreenMonitor.SpaceInfo]) {
        lastSpaces = spaces
        let apps = Set(spaces.flatMap(\.runningApps))
        if apps != fullScreenApps { fullScreenApps = apps }
        var newStatus: [String: Bool] = [:]
        
        for space in spaces {
            if let uuid = space.screenUUID {
                let shouldDetect: Bool
                if Defaults[.hideNotchOption] == .nowPlayingOnly, let musicSourceBundle = MusicManager.shared.bundleIdentifier  {
                    shouldDetect = space.runningApps.contains(musicSourceBundle)
                } else {
                    shouldDetect = true
                }
                newStatus[uuid] = shouldDetect
            }
        }
        
        if newStatus != fullscreenStatus { self.fullscreenStatus = newStatus }
    }
}

