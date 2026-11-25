//
//  IslandMenuBarIcon.swift
//  Hoverbird
//
//  Vector menu-bar glyph: a MacBook screen with the island at its notch, a tiny
//  live waveform, and a sparkle. Drawn as a template image so macOS tints it
//  for light and dark menu bars automatically.
//

import AppKit

enum IslandMenuBarIcon {
    static let image: NSImage = {
        let size = NSSize(width: 20, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()

            // Screen outline
            let screen = NSBezierPath(roundedRect: NSRect(x: 1.2, y: 2.2, width: 14.6, height: 11.2), xRadius: 3.1, yRadius: 3.1)
            screen.lineWidth = 1.45
            screen.stroke()

            // The island, hugging the top edge like the notch
            let island = NSBezierPath(roundedRect: NSRect(x: 4.6, y: 9.9, width: 7.8, height: 3.4), xRadius: 1.7, yRadius: 1.7)
            island.fill()

            // Live waveform under the island
            let bars: [(x: CGFloat, h: CGFloat)] = [(6.3, 2.2), (8.0, 3.8), (9.7, 2.8)]
            for bar in bars {
                let rect = NSRect(x: bar.x, y: 4.7, width: 1.15, height: bar.h)
                NSBezierPath(roundedRect: rect, xRadius: 0.55, yRadius: 0.55).fill()
            }
            let bar4 = NSRect(x: 11.4, y: 4.7, width: 1.15, height: 1.6)
            NSBezierPath(roundedRect: bar4, xRadius: 0.55, yRadius: 0.55).fill()

            // Sparkle (four-point star) at the top-right
            sparkle(center: NSPoint(x: 17.3, y: 14.6), radius: 2.6).fill()
            sparkle(center: NSPoint(x: 18.2, y: 9.6), radius: 1.25).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Hoverbird"
        return image
    }()

    private static func sparkle(center c: NSPoint, radius r: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let inner = r * 0.22
        path.move(to: NSPoint(x: c.x, y: c.y + r))
        path.curve(to: NSPoint(x: c.x + r, y: c.y), controlPoint1: NSPoint(x: c.x + inner, y: c.y + inner),
                   controlPoint2: NSPoint(x: c.x + inner, y: c.y + inner))
        path.curve(to: NSPoint(x: c.x, y: c.y - r), controlPoint1: NSPoint(x: c.x + inner, y: c.y - inner),
                   controlPoint2: NSPoint(x: c.x + inner, y: c.y - inner))
        path.curve(to: NSPoint(x: c.x - r, y: c.y), controlPoint1: NSPoint(x: c.x - inner, y: c.y - inner),
                   controlPoint2: NSPoint(x: c.x - inner, y: c.y - inner))
        path.curve(to: NSPoint(x: c.x, y: c.y + r), controlPoint1: NSPoint(x: c.x - inner, y: c.y + inner),
                   controlPoint2: NSPoint(x: c.x - inner, y: c.y + inner))
        path.close()
        return path
    }
}
