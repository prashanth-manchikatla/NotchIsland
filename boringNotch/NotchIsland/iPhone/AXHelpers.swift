//
//  AXHelpers.swift
//  NotchIsland
//
//  Small, timeout-guarded wrappers around the Accessibility C API.
//

import AppKit
import ApplicationServices

enum AX {
    /// Short IPC timeout so a busy system process can never stall the island.
    static let timeout: Float = 0.35

    static func app(pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return result == .success ? value : nil
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        guard let value = attribute(element, name) else { return nil }
        if let s = value as? String { return s.isEmpty ? nil : s }
        if let a = value as? NSAttributedString { return a.string.isEmpty ? nil : a.string }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        guard let value = attribute(element, kAXChildrenAttribute as String),
              CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        return (value as! [AXUIElement])
    }

    static func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        guard let value = attribute(element, name) else { return [] }
        if CFGetTypeID(value) == CFArrayGetTypeID() { return value as! [AXUIElement] }
        if CFGetTypeID(value) == AXUIElementGetTypeID() { return [value as! AXUIElement] }
        return []
    }

    static func role(_ element: AXUIElement) -> String? { string(element, kAXRoleAttribute as String) }
    static func subrole(_ element: AXUIElement) -> String? { string(element, kAXSubroleAttribute as String) }
    static func identifier(_ element: AXUIElement) -> String? { string(element, kAXIdentifierAttribute as String) }
    static func label(_ element: AXUIElement) -> String? {
        string(element, kAXDescriptionAttribute as String) ?? string(element, kAXTitleAttribute as String)
    }

    /// Depth-first collection of readable text below `element` (static texts, values, labels).
    static func texts(in element: AXUIElement, maxDepth: Int = 8, limit: Int = 12) -> [String] {
        var out: [String] = []
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard depth <= maxDepth, out.count < limit else { return }
            let role = AX.role(e)
            if role == (kAXStaticTextRole as String) || role == (kAXTextFieldRole as String) {
                if let v = string(e, kAXValueAttribute as String) ?? label(e) {
                    let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty, !out.contains(t) { out.append(t) }
                }
            }
            for child in children(e) { walk(child, depth + 1) }
        }
        walk(element, 0)
        return out
    }

    static func position(_ element: AXUIElement) -> CGPoint? {
        guard let value = attribute(element, kAXPositionAttribute as String),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    static func size(_ element: AXUIElement) -> CGSize? {
        guard let value = attribute(element, kAXSizeAttribute as String),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    static func press(_ element: AXUIElement) {
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }

    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let getWindow: GetWindow? = {
        guard let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW),
              let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindow.self)
    }()

    /// The window-server ID of an Accessibility window (private but long-stable API).
    static func windowID(of window: AXUIElement) -> CGWindowID? {
        var number: CGWindowID = 0
        guard let getWindow, getWindow(window, &number) == .success, number != 0 else { return nil }
        return number
    }

    /// Human-readable dump of an element tree (used by the diagnostics export).
    static func dump(_ element: AXUIElement, depth: Int = 0, maxDepth: Int = 6, into out: inout String) {
        guard depth <= maxDepth else { return }
        let indent = String(repeating: "  ", count: depth)
        var parts: [String] = [role(element) ?? "?"]
        if let s = subrole(element) { parts.append("subrole=\(s)") }
        if let i = identifier(element) { parts.append("id=\(i)") }
        if let t = string(element, kAXTitleAttribute as String) { parts.append("title=\"\(t)\"") }
        if let d = string(element, kAXDescriptionAttribute as String) { parts.append("desc=\"\(d)\"") }
        if let v = string(element, kAXValueAttribute as String) { parts.append("value=\"\(v.prefix(120))\"") }
        if let h = string(element, kAXHelpAttribute as String) { parts.append("help=\"\(h)\"") }
        if let pos = position(element), let size = size(element) {
            parts.append("frame=(\(Int(pos.x)),\(Int(pos.y)) \(Int(size.width))x\(Int(size.height)))")
        }
        if parts.count <= 3 {
            // Unlabelled element: list what it does expose.
            var names: CFArray?
            if AXUIElementCopyAttributeNames(element, &names) == .success, let list = names as? [String] {
                parts.append("attrs=[\(list.joined(separator: ","))]")
            }
        }
        out += indent + parts.joined(separator: " ") + "\n"
        for child in children(element) { dump(child, depth: depth + 1, maxDepth: maxDepth, into: &out) }
    }
}
