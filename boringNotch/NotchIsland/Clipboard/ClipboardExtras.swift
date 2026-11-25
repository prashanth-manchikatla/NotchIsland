//
//  ClipboardExtras.swift
//  NotchIsland · Clipboard
//
//  • Clean links: when you copy a link, well-known tracking parameters (utm_*, fbclid, gclid,
//    YouTube / Spotify "si", X "s"/"t"…) are removed before it lands on the clipboard.
//  • Paste as plain text (⌃⌥V): pastes without fonts / colours / links in any app, then puts
//    your original (rich) clipboard back.
//

import AppKit
import Defaults

extension Defaults.Keys {
    static let clipboardCleanLinks = Key<Bool>("clipboardCleanLinks", default: true)
}

enum LinkCleaner {
    private static let tracking: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "mc_eid", "mc_cid", "igshid", "igsh",
        "yclid", "twclid", "ttclid", "li_fat_id", "_hsenc", "_hsmi", "mkt_tok", "ref_src", "oly_anon_id", "oly_enc_id",
    ]

    /// The link without tracking parameters, or nil when it isn't a single web link or had none.
    static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count < 4_000, !trimmed.contains(where: \.isWhitespace),
              var parts = URLComponents(string: trimmed),
              let scheme = parts.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let items = parts.queryItems, !items.isEmpty else { return nil }
        let host = parts.host?.lowercased() ?? ""
        let kept = items.filter { !isTracking($0.name.lowercased(), host: host) }
        guard kept.count != items.count else { return nil }
        parts.queryItems = kept.isEmpty ? nil : kept
        return parts.string
    }

    private static func isTracking(_ name: String, host: String) -> Bool {
        if name.hasPrefix("utm_") || tracking.contains(name) { return true }
        let youtube = host.hasSuffix("youtube.com") || host == "youtu.be"
        if name == "si" && (youtube || host.hasSuffix("spotify.com")) { return true }
        if (name == "s" || name == "t") && (host == "x.com" || host.hasSuffix(".x.com") || host.hasSuffix("twitter.com")) { return true }
        return false
    }
}

@MainActor
enum PlainTextPaste {
    static func paste() {
        let pb = NSPasteboard.general
        guard let string = pb.string(forType: .string) else { return }
        guard AXIsProcessTrusted() else {
            IslandActivityHub.shared.showPill(.info(symbol: "hand.raised.fill", text: "Allow Accessibility to paste", tint: .orange), duration: 2.4)
            return
        }
        // What's on the clipboard now (every flavour), to put back after the paste.
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        pb.clearContents()
        pb.setString(string, forType: .string)
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            pb.clearContents()
            let items = saved.map { flavours -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in flavours { item.setData(data, forType: type) }
                return item
            }
            pb.writeObjects(items)
        }
    }
}
