//
//  AIKeychain.swift
//  Hoverbird · AI Usage
//
//  • API keys you add in Settings › AI Usage live in Hoverbird's own Keychain items
//    (service "app.hoverbird.ai", one account per provider) — never in a file.
//  • Claude Code's sign-in is read the way Claude Code itself reads it: through Apple's
//    `security` tool, which that item already trusts, so macOS doesn't ask for a password.
//    (Reading it directly would ask after every update: for an app signed without an Apple
//    Developer ID, "Always Allow" only covers that exact build.)
//  Every call can block (a prompt, or the tool): call off the main thread.
//

import Foundation
import Security

enum AIKeychain {
    private static let service = "app.hoverbird.ai"

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

    /// Reads another tool's item through `/usr/bin/security`, the way that tool reads it.
    /// Prints nothing and passes no secret on the command line; gives up after 30 s.
    static func readWithSecurityTool(service: String) -> ReadResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return .failed(errSecIO) }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30, execute: timeout)
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        switch process.terminationStatus {
        case 0: break
        case 44: return .notFound            // errSecItemNotFound
        default: return .failed(OSStatus(process.terminationStatus))
        }
        guard let text = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return .notFound }
        // `-w` prints data that isn't plain text as hex.
        if !text.hasPrefix("{"), text.count.isMultiple(of: 2), text.allSatisfy(\.isHexDigit) {
            var bytes = Data(capacity: text.count / 2)
            var index = text.startIndex
            while index < text.endIndex {
                let next = text.index(index, offsetBy: 2)
                guard let byte = UInt8(text[index..<next], radix: 16) else { return .found(Data(text.utf8)) }
                bytes.append(byte)
                index = next
            }
            return .found(bytes)
        }
        return .found(Data(text.utf8))
    }

    // MARK: Hoverbird's own items (API keys)

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
        add[kSecAttrLabel as String] = "Hoverbird · \(provider.name) API key"
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
