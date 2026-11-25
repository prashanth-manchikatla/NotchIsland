//
//  AIKeychain.swift
//  NotchIsland · AI Usage
//
//  • API keys you add in Settings › AI Usage live in NotchIsland's own Keychain items
//    (service "app.notchisland.ai", one account per provider) — never in a file.
//  • Reading another app's item (Claude Code's sign-in) makes macOS ask you once;
//    "Always Allow" remembers NotchIsland by its signature, so rebuilds don't ask again.
//  Every call blocks while macOS shows its prompt: call off the main thread.
//

import Foundation
import Security

enum AIKeychain {
    private static let service = "app.notchisland.ai"

    enum ReadResult {
        case found(Data)
        case notFound
        case denied     // you clicked Deny / cancelled the prompt
        case failed(OSStatus)
    }

    /// Reads a generic password by service name (another app's item → macOS asks first).
    static func read(service: String, account: String? = nil) -> ReadResult {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess: return (out as? Data).map(ReadResult.found) ?? .notFound
        case errSecItemNotFound: return .notFound
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed: return .denied
        default: return .failed(status)
        }
    }

    // MARK: NotchIsland's own items (API keys)

    static func apiKey(for provider: AIProvider) -> String? {
        guard case .found(let data) = read(service: service, account: provider.rawValue) else { return nil }
        let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return key?.isEmpty == false ? key : nil
    }

    @discardableResult
    static func setAPIKey(_ key: String?, for provider: AIProvider) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
        SecItemDelete(base as CFDictionary)
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
              let data = key.data(using: .utf8) else { return true }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "NotchIsland · \(provider.name) API key"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func hasAPIKey(for provider: AIProvider) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}
