//
//  VideoElementLocator.swift
//  Hoverbird
//
//  Finds the on-screen rectangle of the video player inside a browser window
//  through the Accessibility tree (e.g. YouTube's "YouTube Video Player", or
//  any HTML5 <video>, which browsers expose with a "video" role description).
//  Much more precise than motion detection when the video has a still
//  background. Runs off the main thread, with a node budget.
//

import AppKit
import ApplicationServices

enum VideoElementLocator {
    struct Result {
        let frame: CGRect      // global, top-left origin (same space as SCWindow.frame)
        let label: String
        let element: AXUIElement
    }

    private static let batchAttributes = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXRoleDescriptionAttribute, kAXDescriptionAttribute,
        kAXTitleAttribute, kAXChildrenAttribute, kAXPositionAttribute, kAXSizeAttribute,
    ] as CFArray

    /// Searches the app's window matching `windowTitle` / `windowFrame`.
    static func locate(pid: pid_t, windowFrame: CGRect, windowTitle: String? = nil, budget: Int = 4500,
                       log: ((String) -> Void)? = nil) -> Result? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        // Chromium-based browsers only build their web accessibility tree on request.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var windows = AX.elements(app, kAXWindowsAttribute as String)
        if windows.isEmpty {
            // On another desktop: still reachable as the main / focused window.
            windows = AX.elements(app, kAXMainWindowAttribute as String) + AX.elements(app, kAXFocusedWindowAttribute as String)
        }
        // Prefer an exact title match (browsers keep hidden duplicate windows), then the closest frame.
        let titled = windowTitle.flatMap { title in windows.first { AX.string($0, kAXTitleAttribute as String) == title } }
        guard let window = titled ?? windows.min(by: { distance(frame(of: $0), windowFrame) < distance(frame(of: $1), windowFrame) }),
              titled != nil || distance(frame(of: window), windowFrame) < 40 else {
            log?("accessibility: window not visible to Accessibility (\(windows.count) AX windows) — likely on another Space")
            return nil
        }

        // Depth-first: the player sits deep inside the page but early in document order.
        var stack: [AXUIElement] = [window]
        var visited = 0
        var best: Result?
        var videoish: [String] = []
        while let element = stack.popLast(), visited < budget {
            visited += 1

            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, batchAttributes, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
                  let list = values as? [Any], list.count == 8 else { continue }
            let role = list[0] as? String ?? ""
            let subrole = list[1] as? String ?? ""
            let roleDescription = (list[2] as? String ?? "").lowercased()
            let description = list[3] as? String ?? ""
            let title = list[4] as? String ?? ""

            let label = (description + " " + title).lowercased()
            let looksLikeVideo = roleDescription == "video" || roleDescription == "video playback" || role == "AXVideo" || subrole == "AXVideo"
                || label.contains("video player") || label.contains("youtube video player")
            if looksLikeVideo || roleDescription.contains("video") || label.contains("video"), videoish.count < 12 {
                videoish.append("\(role)/\(subrole)/\(roleDescription)/\"\(description.prefix(40))\"")
            }
            if looksLikeVideo, let rect = rect(position: list[6], size: list[7]),
               rect.width >= 160, rect.height >= 90 {
                let aspect = rect.width / rect.height
                if aspect > 0.5 && aspect < 3.2, rect.width * rect.height > (best?.frame.width ?? 0) * (best?.frame.height ?? 0) {
                    best = Result(frame: rect, label: description.isEmpty ? roleDescription : description, element: element)
                }
            }
            // Don't descend into leaves that can't contain a player.
            if ["AXStaticText", "AXImage", "AXButton", "AXLink", "AXTextField", "AXCheckBox"].contains(role) { continue }
            if let children = list[5] as? [AXUIElement] {
                stack.append(contentsOf: children.reversed())
            }
        }
        log?("accessibility: visited \(visited) nodes, video-like: \(videoish.joined(separator: " | "))")
        return best
    }

    private static func rect(position: Any, size: Any) -> CGRect? {
        guard CFGetTypeID(position as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(size as CFTypeRef) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &p),
              AXValueGetValue(size as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    private static func frame(of element: AXUIElement) -> CGRect {
        guard let p = AX.position(element), let s = AX.size(element) else { return .zero }
        return CGRect(origin: p, size: s)
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }
}
