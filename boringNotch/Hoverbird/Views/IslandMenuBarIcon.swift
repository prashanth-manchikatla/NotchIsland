//
//  IslandMenuBarIcon.swift
//  Hoverbird
//
//  Menu-bar glyph: Hoverbird's glass hummingbird (Resources/Icon/MenuBarGlyph.svg), drawn as a
//  template image so macOS tints it for light and dark menu bars. The back wing and tail are
//  drawn lighter for depth, and the eye is cut out.
//

import AppKit

enum IslandMenuBarIcon {
    /// The glyph's frame in the SVG's coordinates (viewBox 250 150 600 680).
    private static let frame = NSRect(x: 250, y: 150, width: 600, height: 680)

    static let image: NSImage = {
        let height: CGFloat = 18
        let scale = height / frame.height
        let size = NSSize(width: (frame.width * scale).rounded(.up), height: height)
        let image = NSImage(size: size, flipped: true) { _ in
            // SVG units → points (y already points down: the image is flipped).
            let toImage = AffineTransform(m11: scale, m12: 0, m21: 0, m22: scale,
                                          tX: -frame.minX * scale, tY: -frame.minY * scale)
            func fill(_ path: NSBezierPath, alpha: CGFloat) {
                path.transform(using: toImage)
                NSColor.black.withAlphaComponent(alpha).setFill()
                path.fill()
            }
            fill(ellipse(cx: 407, cy: 419, rx: 152, ry: 48, degrees: 20), alpha: 0.5)    // back wing
            fill(ellipse(cx: 398, cy: 752, rx: 68, ry: 22, degrees: 135), alpha: 0.6)    // tail
            fill(ellipse(cx: 421, cy: 767, rx: 68, ry: 22, degrees: 112), alpha: 0.85)
            fill(body(), alpha: 1)
            // Beak: a fine rounded line (kept at least ~1.1 pt so it survives the small size).
            let beak = NSBezierPath()
            beak.move(to: NSPoint(x: 676, y: 360))
            beak.curve(to: NSPoint(x: 812, y: 320), controlPoint1: NSPoint(x: 721.3, y: 345.3),
                       controlPoint2: NSPoint(x: 766.7, y: 332))
            beak.transform(using: toImage)
            beak.lineWidth = 1.15
            beak.lineCapStyle = .round
            NSColor.black.setStroke()
            beak.stroke()
            fill(ellipse(cx: 453, cy: 335, rx: 168, ry: 56, degrees: 55), alpha: 1)    // front wing
            // Eye: cut out of the head.
            let eye = NSBezierPath(ovalIn: NSRect(x: 624 - 22, y: 360 - 22, width: 44, height: 44))
            eye.transform(using: toImage)
            NSGraphicsContext.current?.compositingOperation = .clear
            eye.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Hoverbird"
        return image
    }()

    /// An ellipse rotated about its centre (SVG `rotate(degrees cx cy)`, clockwise with y down).
    private static func ellipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, degrees: CGFloat) -> NSBezierPath {
        let path = NSBezierPath(ovalIn: NSRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
        let a = degrees * .pi / 180
        let c = cos(a), s = sin(a)
        path.transform(using: AffineTransform(m11: c, m12: s, m21: -s, m22: c,
                                              tX: cx - c * cx + s * cy, tY: cy - s * cx - c * cy))
        return path
    }

    /// Head flowing into the body and tail (the icon's bird).
    private static func body() -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 560, y: 330))
        p.curve(to: NSPoint(x: 676, y: 350), controlPoint1: NSPoint(x: 596, y: 300), controlPoint2: NSPoint(x: 656, y: 304))
        p.curve(to: NSPoint(x: 664, y: 428), controlPoint1: NSPoint(x: 688, y: 378), controlPoint2: NSPoint(x: 682, y: 408))
        p.curve(to: NSPoint(x: 634, y: 504), controlPoint1: NSPoint(x: 646, y: 448), controlPoint2: NSPoint(x: 640, y: 474))
        p.curve(to: NSPoint(x: 546, y: 650), controlPoint1: NSPoint(x: 622, y: 560), controlPoint2: NSPoint(x: 590, y: 612))
        p.curve(to: NSPoint(x: 452, y: 710), controlPoint1: NSPoint(x: 516, y: 676), controlPoint2: NSPoint(x: 482, y: 696))
        p.curve(to: NSPoint(x: 441, y: 699), controlPoint1: NSPoint(x: 444, y: 714), controlPoint2: NSPoint(x: 437, y: 707))
        p.curve(to: NSPoint(x: 478, y: 588), controlPoint1: NSPoint(x: 458, y: 664), controlPoint2: NSPoint(x: 470, y: 626))
        p.curve(to: NSPoint(x: 520, y: 418), controlPoint1: NSPoint(x: 490, y: 528), controlPoint2: NSPoint(x: 500, y: 470))
        p.curve(to: NSPoint(x: 560, y: 330), controlPoint1: NSPoint(x: 530, y: 388), controlPoint2: NSPoint(x: 542, y: 352))
        p.close()
        return p
    }
}
