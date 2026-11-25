//
//  MeetingSettingsView.swift
//  Hoverbird · Meeting kit
//
//  Settings › Microphone & Camera.
//

import Defaults
import KeyboardShortcuts
import SwiftUI

struct MeetingSettingsView: View {
    @ObservedObject private var mic = MicCameraMonitor.shared

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: mic.isMuted ? "mic.slash.fill" : "mic.fill").foregroundStyle(mic.isMuted ? .red : .green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mic.isMuted ? "Muted" : "On")
                        Text(mic.inputName ?? "No microphone").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(mic.isMuted ? "Unmute" : "Mute") { mic.toggleMute() }
                }
                KeyboardShortcuts.Recorder("Mute / unmute:", name: .toggleMicMute)
                Defaults.Toggle("Show “Muted” in the closed island while an app uses the microphone", key: .micMutedIndicator)
            } header: {
                Text("Microphone")
            } footer: {
                Text("Mutes the microphone itself, so every app (Zoom, Meet, Teams, FaceTime, Discord…) hears silence at once — no hunting for each app's mute button. If you switch microphones while muted (e.g. AirPods connect), the new one is muted too.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Microphone in use", value: mic.micInUse ? "Yes" : "No")
                LabeledContent("A camera in use (other apps)", value: mic.cameraInUse ? "Yes" : "No")
                Defaults.Toggle("Pill when an app turns a camera on", key: .cameraInUsePill)
                Defaults.Toggle("Pill when an app starts using the microphone", key: .micInUsePill)
            } header: {
                Text("Privacy")
            } footer: {
                Text("Like the green / orange dots in the menu bar, but in the island where you'll notice. Hoverbird's own camera mirror isn't counted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Microphone & Camera")
    }
}
