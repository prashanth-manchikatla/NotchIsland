//
//  AISettingsView.swift
//  NotchIsland · AI Usage
//
//  Settings › AI Usage: what's detected, live limits (opt-in per provider), API accounts
//  (keys stored in the Keychain), the closed island, alerts, privacy and prices.
//

import Defaults
import SwiftUI

struct AISettingsView: View {
    @ObservedObject private var store = AIUsageStore.shared
    @Default(.aiUsageEnabled) private var enabled

    var body: some View {
        Form {
            Section {
                Toggle("Track AI usage", isOn: Binding(get: { enabled }, set: { enabled = $0; store.setEnabled($0) }))
            } footer: {
                aiFootnote("Reads the logs your AI tools already keep on this Mac — nothing is uploaded, and prompts never leave your Mac. Token counts are exact; “≈ $” is what the same tokens would cost at API prices (on a flat plan you don't pay this).")
            }

            Section {
                ForEach(AIProvider.allCases.filter(\.isLocal)) { provider in providerRow(provider) }
            } header: {
                Text("On this Mac")
            } footer: {
                aiFootnote("Live limits use the CLI's own sign-in to read the numbers it shows you (Claude: /usage). Claude's sign-in is in your Keychain, so macOS asks once — choose Always Allow. Sign-ins are never saved, changed or sent anywhere except their own provider.")
            }

            Section {
                ForEach(AIAPIAccounts.providers) { provider in APIKeyRow(provider: provider) }
            } header: {
                Text("API accounts")
            } footer: {
                aiFootnote("For usage through an API key. Keys are stored in your Keychain and only sent to their provider. OpenAI needs an organization Admin key to read usage and costs.")
            }

            Section {
                Defaults.Toggle("Show working agents in the closed island", key: .aiWorkingInIsland)
                Defaults.Toggle("Take over the island when an agent needs you (permission, a question)", key: .aiAttentionInIsland)
                Defaults.Toggle("“Finished” pill when an agent stops after working 30 s or more", key: .aiFinishedPill)
                Defaults.Toggle("Keep the tightest limit's % in the closed island", key: .aiUsageInIsland)
            } header: { Text("Closed island") }

            Section {
                Defaults.Toggle("Limit alerts: 50 / 80 / 95 %, “at this pace…”, reached, reset", key: .aiLimitAlerts)
            } header: { Text("Alerts") }

            Section {
                Defaults.Toggle("Show ≈ $ at API prices", key: .aiShowCosts)
                Defaults.Toggle("Hide prompts, commands and project names (for screen sharing)", key: .aiHideDetails)
                HStack {
                    Text("Model prices")
                    Spacer()
                    Button("Edit prices…") { AIPricingFile.open() }
                }
            } header: {
                Text("Display & privacy")
            } footer: {
                aiFootnote("Prices are per 1M tokens, Anthropic / OpenAI / Google / xAI list prices. Add or override a model in ai-pricing.json (it's created with an example when you click Edit).")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("AI Usage")
        .onAppear { store.attach(.settings) }
        .onDisappear { store.detach(.settings) }
    }

    @ViewBuilder
    private func providerRow(_ provider: AIProvider) -> some View {
        let usage = store.snapshot.usage(for: provider)
        HStack(spacing: 10) {
            Image(systemName: provider.symbol).foregroundStyle(provider.tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name)
                Group {
                    if let usage, usage.detected {
                        Text("Found · \(usage.lastActivity.map { "last used \(AIFormat.ago($0))" } ?? "no activity yet") · \(provider.sourceDescription)")
                    } else {
                        Text("Not found on this Mac · \(provider.sourceDescription)")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let note = usage?.limitsNote { Text(note).font(.caption).foregroundStyle(.orange) }
            }
            Spacer()
            if let key = liveKey(provider) {
                Toggle("Live limits", isOn: Binding(
                    get: { Defaults[key] },
                    set: { on in if on { AIConnect.ask(provider) } else { Defaults[key] = false } }))
                    .toggleStyle(.switch).controlSize(.small)
            }
        }
    }

    private func liveKey(_ provider: AIProvider) -> Defaults.Key<Bool>? {
        switch provider {
        case .claude: return .aiClaudeLiveLimits
        case .codex: return .aiCodexLiveLimits
        case .grok: return .aiGrokLiveLimits
        default: return nil
        }
    }
}

/// One API account: paste a key, Save (into the Keychain) or Remove.
private struct APIKeyRow: View {
    let provider: AIProvider
    @State private var key = ""
    @State private var saved = false
    @State private var checked = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: provider.symbol).foregroundStyle(provider.tint).frame(width: 18)
            Text(provider.name).frame(width: 90, alignment: .leading)
            if saved {
                Text("Key saved in Keychain").foregroundStyle(.secondary)
                Spacer()
                Button("Remove") {
                    AIKeychain.setAPIKey(nil, for: provider)
                    saved = false
                    AIUsageStore.shared.accountsChanged()
                }
            } else {
                SecureField("API key", text: $key, prompt: Text(AIAPIAccounts.keyHint(provider)))
                    .labelsHidden().textFieldStyle(.roundedBorder)
                Button("Save") {
                    if AIKeychain.setAPIKey(key, for: provider) { saved = true; key = "" }
                    AIUsageStore.shared.accountsChanged()
                }
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            guard !checked else { return }
            checked = true
            saved = AIKeychain.hasAPIKey(for: provider)
        }
    }
}

enum AIPricingFile {
    /// Opens ai-pricing.json (created with an example the first time).
    static func open() {
        let url = IslandPaths.appSupport.appendingPathComponent("ai-pricing.json")
        if !FileManager.default.fileExists(atPath: url.path) {
            let example = """
            {
              "_comment": "Prices in US$ per 1M tokens. A model id matches by prefix; this file wins over NotchIsland's table.",
              "my-custom-model": { "input": 1.0, "output": 4.0, "cacheRead": 0.1, "cacheWrite5m": 1.25, "cacheWrite1h": 2.0 }
            }
            """
            try? example.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }
}

private func aiFootnote(_ text: String) -> some View {
    Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
}
