//
//  FilesSettingsViews.swift
//  NotchIsland · Files & Devices
//
//  Settings › Downloads & Drives, and the battery-alert section of Settings › Battery.
//

import Defaults
import SwiftUI

struct DownloadsDrivesSettingsView: View {
    @ObservedObject private var drives = DrivesMonitor.shared

    var body: some View {
        Form {
            Section {
                Defaults.Toggle("Show finished downloads in the island", key: .downloadAlerts)
                Defaults.Toggle("Put new downloads on the Shelf (drag them anywhere)", key: .downloadsToShelf)
            } header: {
                Text("Downloads")
            } footer: {
                Text("Works with every browser and app that saves to Downloads. Half-finished files (.crdownload, .download, .part) are ignored until they're complete. Click the island while it shows a download to open the Shelf.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Defaults.Toggle("Show when a drive is connected", key: .driveAlerts)
                if drives.drives.isEmpty {
                    Text("No drives connected").foregroundStyle(.secondary)
                } else {
                    ForEach(drives.drives, id: \.self) { url in
                        HStack {
                            Image(systemName: "externaldrive.fill").foregroundStyle(.secondary)
                            Text(DrivesMonitor.name(url))
                            Spacer()
                            Button("Eject") { drives.eject(url) }
                        }
                    }
                }
            } header: {
                Text("Drives")
            } footer: {
                Text("Eject is also in the NotchIsland menu bar menu. You'll see “Safe to remove” in the island when it's done.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Downloads & Drives")
    }
}

struct BatteryAlertSettingsSection: View {
    @Default(.batteryFullAlertLevel) private var full
    @Default(.batteryLowAlertLevel) private var low

    var body: some View {
        Section {
            Defaults.Toggle("Tell me when the battery is charged", key: .batteryFullAlert)
            Stepper("Charged at: \(full)%", value: $full, in: 50...100, step: 5)
            Defaults.Toggle("Tell me when the battery is low", key: .batteryLowAlert)
            Stepper("Low at: \(low)%", value: $low, in: 5...50, step: 5)
        } header: {
            Text("Battery alerts")
        } footer: {
            Text("Keeping a MacBook between about 20% and 80% is easier on the battery. Once per charge / discharge.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
