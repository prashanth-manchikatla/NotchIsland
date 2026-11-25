//
//  RegionSelector.swift
//  NotchIsland
//
//  Full-screen overlay for picking the area to record: drag a rectangle,
//  then press Return (or click Record). Esc cancels.
//  Returns the rect in display-local points with a top-left origin, which is
//  what ScreenCaptureKit's `sourceRect` expects.
//

import AppKit

@MainActor
enum RegionSelector {
    private static var window: RegionSelectionWindow?

    static func select(on screen: NSScreen) async -> CGRect? {
        // Remember who had focus so we can hand it back after selecting.
        let previousApp = NSWorkspace.shared.frontmostApplication
        return await withCheckedContinuation { continuation in
            let window = RegionSelectionWindow(screen: screen) { rect in
                Self.window?.orderOut(nil)
                Self.window = nil
                if let previousApp, previousApp.bundleIdentifier != Bundle.main.bundleIdentifier {
                    previousApp.activate()
                }
                continuation.resume(returning: rect)
            }
            Self.window = window
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(window.contentView)
        }
    }
}

final class RegionSelectionWindow: NSWindow {
    private let completion: (CGRect?) -> Void
    private var finished = false

    init(screen: NSScreen, completion: @escaping (CGRect?) -> Void) {
        self.completion = completion
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        sharingType = .none
        let view = RegionSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onFinish = { [weak self] rect in self?.finish(rect, screenHeight: screen.frame.height) }
        contentView = view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private func finish(_ rect: CGRect?, screenHeight: CGFloat) {
        guard !finished else { return }
        finished = true
        guard let rect, rect.width >= 16, rect.height >= 16 else {
            completion(nil)
            return
        }
        // View coordinates are bottom-left; ScreenCaptureKit wants top-left.
        let flipped = CGRect(x: rect.minX.rounded(), y: (screenHeight - rect.maxY).rounded(),
                             width: rect.width.rounded(), height: rect.height.rounded())
        completion(flipped)
    }
}

final class RegionSelectionView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    private var anchor: CGPoint?
    private var selection: CGRect?
    private lazy var recordButton: NSButton = {
        let b = NSButton(title: "Record", target: self, action: #selector(confirm))
        b.bezelStyle = .rounded
        b.controlSize = .large
        b.keyEquivalent = "\r"
        b.contentTintColor = .systemRed
        b.isHidden = true
        addSubview(b)
        return b
    }()
    private lazy var cancelButton: NSButton = {
        let b = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        b.bezelStyle = .rounded
        b.controlSize = .large
        b.isHidden = true
        addSubview(b)
        return b
    }()

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        selection = nil
        recordButton.isHidden = true
        cancelButton.isHidden = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let p = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(anchor.x, p.x), y: min(anchor.y, p.y),
                           width: abs(p.x - anchor.x), height: abs(p.y - anchor.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        anchor = nil
        guard let selection, selection.width >= 16, selection.height >= 16 else {
            self.selection = nil
            needsDisplay = true
            return
        }
        layoutButtons(for: selection)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: cancel()                       // Esc
        case 36, 76: if selection != nil { confirm() } // Return / Enter
        default: super.keyDown(with: event)
        }
    }

    @objc private func confirm() { onFinish?(selection) }
    @objc private func cancel() { onFinish?(nil) }

    private func layoutButtons(for rect: CGRect) {
        recordButton.sizeToFit()
        cancelButton.sizeToFit()
        let gap: CGFloat = 8
        let total = recordButton.frame.width + cancelButton.frame.width + gap
        var y = rect.minY - recordButton.frame.height - 12
        if y < 20 { y = rect.minY + 12 }
        let x = min(max(rect.midX - total / 2, 12), bounds.width - total - 12)
        cancelButton.setFrameOrigin(CGPoint(x: x, y: y))
        recordButton.setFrameOrigin(CGPoint(x: x + cancelButton.frame.width + gap, y: y))
        recordButton.isHidden = false
        cancelButton.isHidden = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.38).setFill()
        bounds.fill()
        guard let selection else {
            drawHint("Drag to choose the area to record · Esc to cancel", at: CGPoint(x: bounds.midX, y: bounds.midY))
            return
        }
        NSGraphicsContext.current?.compositingOperation = .copy
        NSColor.clear.setFill()
        selection.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        let border = NSBezierPath(rect: selection.insetBy(dx: -1, dy: -1))
        border.lineWidth = 2
        NSColor.white.withAlphaComponent(0.9).setStroke()
        border.stroke()
        drawHint("\(Int(selection.width)) × \(Int(selection.height))",
                 at: CGPoint(x: selection.midX, y: selection.maxY + 16))
    }

    private func drawHint(_ text: String, at point: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let bg = CGRect(x: point.x - size.width / 2 - 10, y: point.y - size.height / 2 - 5,
                        width: size.width + 20, height: size.height + 10)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: bg, xRadius: bg.height / 2, yRadius: bg.height / 2).fill()
        (text as NSString).draw(at: CGPoint(x: bg.minX + 10, y: bg.minY + 5), withAttributes: attrs)
    }
}
