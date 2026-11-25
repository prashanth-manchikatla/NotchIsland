//
//  IslandHelperProcesses.swift
//  Hoverbird
//
//  Hoverbird runs Apple's /usr/bin/perl with the bundled MediaRemote adapter as a
//  long-lived child (the Now Playing stream). A child process doesn't die with its
//  parent, and the stream only writes when media changes, so every quit, crash or
//  reinstall used to leave one behind, running for days.
//  Now the stream helper is stopped when Hoverbird quits, and any helper orphaned
//  by an earlier run (its parent is launchd) is cleaned up at launch.
//

import AppKit

enum IslandHelperProcesses {
    private static let adapterPathMarker = "Hoverbird.app/Contents/Resources/mediaremote-adapter.pl"

    /// Kills MediaRemote adapter helpers from a Hoverbird bundle whose Hoverbird has gone.
    static func reapOrphanedAdapters() {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-Ao", "pid=,ppid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        do { try ps.run() } catch { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") where line.contains(adapterPathMarker) {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), let ppid = Int32(parts[1]),
                  ppid == 1, pid != getpid() else { continue }
            kill(pid, SIGTERM)
            NSLog("Hoverbird: stopped an orphaned media helper (pid \(pid))")
        }
    }

    /// Stops `process` when Hoverbird quits normally.
    static func terminateOnQuit(_ process: Process) {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: nil) { [weak process] _ in
            if let process, process.isRunning { process.terminate() }
        }
    }
}
