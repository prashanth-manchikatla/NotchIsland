//
//  BirdWings.swift
//  Hoverbird
//
//  The island opens like a bird spreading its wings, and then the bird becomes the island:
//   1. Beside the notch the folded wings open — coverts, secondaries, then the primaries fanning
//      out — with the lower body and tail below. No rectangle yet.
//   2. The island's black glass grows out of the bird itself: the gaps between feathers close
//      first, then it spreads until it fills the island's edges and corners.
//   3. The feather detail fades into the glass and the content arrives.
//  Closing runs the same path backwards and a little quicker.
//
//  One progress value p drives it all (0 = the closed pill, 1 = the open island).
//  Geometry is in points; origin = the open island's top-left (680 × 190, window 680 × 210).
//

import AppKit
import Defaults
import SwiftUI

private func clamp(_ x: CGFloat, _ a: CGFloat = 0, _ b: CGFloat = 1) -> CGFloat { min(b, max(a, x)) }
private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
private func smooth(_ e0: CGFloat, _ e1: CGFloat, _ x: CGFloat) -> CGFloat {
    let t = clamp((x - e0) / (e1 - e0))
    return t * t * (3 - 2 * t)
}
/// Ease-out with a small overshoot: the feathers settle like a real wingbeat.
private func backOut(_ t: CGFloat, _ s: CGFloat) -> CGFloat {
    let u = t - 1
    return 1 + (s + 1) * u * u * u + s * u * u
}

// MARK: - Feathers

/// Feathers drawn once, the way real ones are built: a shaft, vanes of fine barbs angled toward the
/// tip, a few splits where the barbs part, light through the edges. They point down from a base at
/// the top centre. `mask` sprites are the same shapes in solid white (for the glass).
enum FeatherSprites {
    enum Kind { case primary, secondary, covert, tail }

    struct Sprite {
        let image: CGImage
        let canvasSize: CGSize
        let pad: CGFloat
        let length: CGFloat
        let width: CGFloat
    }

    static let dark = make(dark: true)
    static let mask = make(dark: false)

    /// Same pseudo-random sequence as the design prototype, so both sets split in the same places.
    private struct Seeded {
        var seed: Int64 = 11
        mutating func next() -> CGFloat {
            seed = (seed * 16807) % 2_147_483_647
            return CGFloat(seed - 1) / 2_147_483_646
        }
    }

    private static func make(dark: Bool) -> [Kind: Sprite] {
        var random = Seeded()
        let primary = render(length: 120, width: 22, asym: 0.36, round: 0.3, splits: 4, dark: dark, random: &random)
        let secondary = render(length: 104, width: 26, asym: 0.5, round: 0.62, splits: 3, dark: dark, random: &random)
        let covert = render(length: 50, width: 22, asym: 0.5, round: 0.7, splits: 1, dark: dark, random: &random)
        let tail = render(length: 100, width: 24, asym: 0.5, round: 0.66, splits: 3, dark: dark, random: &random)
        return [.primary: primary, .secondary: secondary, .covert: covert, .tail: tail]
    }

    private static func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
        CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }

    private static func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map(\.1) as CFArray,
                   locations: stops.map(\.0))!
    }

    private static func render(length L: CGFloat, width w: CGFloat, asym: CGFloat, round tipK: CGFloat,
                               splits: Int, dark: Bool, random: inout Seeded) -> Sprite {
        let pad: CGFloat = 3, scale: CGFloat = 2
        let cw = ceil(w + pad * 2), ch = ceil(L + pad * 2)
        let ctx = CGContext(data: nil, width: Int(cw * scale), height: Int(ch * scale), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // y down, in points, origin at the base of the feather.
        ctx.translateBy(x: 0, y: ch * scale)
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: cw / 2, y: pad)
        let outer = w * asym, inner = w - outer
        let vane = CGMutablePath()
        vane.move(to: CGPoint(x: -0.8, y: 0))
        vane.addCurve(to: CGPoint(x: -outer, y: 0.4 * L), control1: CGPoint(x: -outer * 0.7, y: 0.05 * L), control2: CGPoint(x: -outer, y: 0.18 * L))
        vane.addCurve(to: CGPoint(x: 0, y: L), control1: CGPoint(x: -outer, y: 0.7 * L), control2: CGPoint(x: -outer * tipK, y: 0.97 * L))
        vane.addCurve(to: CGPoint(x: inner, y: 0.4 * L), control1: CGPoint(x: inner * tipK, y: 0.97 * L), control2: CGPoint(x: inner, y: 0.7 * L))
        vane.addCurve(to: CGPoint(x: 0.8, y: 0), control1: CGPoint(x: inner, y: 0.18 * L), control2: CGPoint(x: inner * 0.7, y: 0.05 * L))
        vane.closeSubpath()

        if dark {
            ctx.saveGState()
            ctx.addPath(vane)
            ctx.clip()
            ctx.drawLinearGradient(gradient([(0, rgba(5, 7, 13, 0.97)), (0.6, rgba(14, 17, 28, 0.95)), (1, rgba(30, 36, 56, 0.93))]),
                                   start: .zero, end: CGPoint(x: 0, y: L), options: [])
            ctx.setStrokeColor(rgba(255, 255, 255, 0.05))
            ctx.setLineWidth(0.55)
            var s = 0.03 * L
            while s < 0.99 * L {
                ctx.move(to: CGPoint(x: 0, y: s))
                ctx.addLine(to: CGPoint(x: -outer * 1.15, y: s + outer * 0.95))
                ctx.move(to: CGPoint(x: 0, y: s))
                ctx.addLine(to: CGPoint(x: inner * 1.15, y: s + inner * 0.95))
                s += 1.6
            }
            ctx.strokePath()
            ctx.restoreGState()
        } else {
            ctx.addPath(vane)
            ctx.setFillColor(.white)
            ctx.fillPath()
        }

        // Splits: barbs parting at the edge.
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.setLineCap(.round)
        ctx.setLineWidth(1.1)
        for _ in 0..<splits {
            let s0 = (0.28 + 0.6 * random.next()) * L
            let left = random.next() < 0.55
            let wv = left ? outer : inner, dir: CGFloat = left ? -1 : 1
            let depth = (0.3 + 0.45 * random.next()) * wv
            let len = hypot(1.15, 0.95), ux = dir * 1.15 / len, uy = 0.95 / len
            let ex = dir * wv * 1.02, ey = s0 + wv * 0.95 / 1.15
            ctx.move(to: CGPoint(x: ex + ux * 2, y: ey + uy * 2))
            ctx.addLine(to: CGPoint(x: ex - ux * depth, y: ey - uy * depth))
            ctx.strokePath()
        }
        ctx.restoreGState()

        if dark {
            func strokeGradient(_ path: CGPath, width: CGFloat, _ from: CGColor, _ to: CGColor) {
                ctx.saveGState()
                ctx.addPath(path)
                ctx.setLineWidth(width)
                ctx.setLineCap(.round)
                ctx.replacePathWithStrokedPath()
                ctx.clip()
                ctx.drawLinearGradient(gradient([(0, from), (1, to)]), start: .zero, end: CGPoint(x: 0, y: L), options: [])
                ctx.restoreGState()
            }
            let shaftTop = CGMutablePath(), shaftTip = CGMutablePath()
            shaftTop.move(to: .zero)
            shaftTop.addLine(to: CGPoint(x: 0, y: 0.5 * L))
            shaftTip.move(to: CGPoint(x: 0, y: 0.5 * L))
            shaftTip.addLine(to: CGPoint(x: 0, y: 0.94 * L))
            strokeGradient(shaftTop, width: 1.4, rgba(200, 222, 255, 0.30), rgba(200, 222, 255, 0.08))
            strokeGradient(shaftTip, width: 0.7, rgba(200, 222, 255, 0.30), rgba(200, 222, 255, 0.08))
            strokeGradient(vane, width: 0.8, rgba(155, 233, 255, 0.06), rgba(155, 233, 255, 0.42))
        }
        return Sprite(image: ctx.makeImage()!, canvasSize: CGSize(width: cw, height: ch), pad: pad, length: L, width: w)
    }
}

// MARK: - The bird

enum BirdWings {
    static let width = openNotchSize.width
    static let height = openNotchSize.height
    static let canvasHeight = windowSize.height
    static let cx = width / 2

    static let islandPath = NotchShape(topCornerRadius: cornerRadiusInsets.opened.top,
                                       bottomCornerRadius: cornerRadiusInsets.opened.bottom)
        .path(in: CGRect(x: 0, y: 0, width: width, height: height))

    static func pillPath(_ size: CGSize) -> Path {
        NotchShape(topCornerRadius: cornerRadiusInsets.closed.top, bottomCornerRadius: cornerRadiusInsets.closed.bottom)
            .path(in: CGRect(x: cx - size.width / 2, y: 0, width: size.width, height: size.height))
    }

    // Phases of the flight at progress p.
    static func unfold(_ p: CGFloat) -> CGFloat { smooth(0, 0.62, clamp(p)) }
    static func fill(_ p: CGFloat) -> CGFloat { smooth(0.55, 0.97, clamp(p)) }
    static func detail(_ p: CGFloat) -> CGFloat { 1 - smooth(0.62, 0.97, clamp(p)) }

    struct Spec {
        let base: CGPoint
        let angle: CGFloat   // degrees; 0 = straight down, + = outward
        let length: CGFloat
        let width: CGFloat
    }

    /// The spread wing, laid out like a real one: coverts along the arm, secondaries hanging from it,
    /// primaries fanning to a rounded wingtip, an alula at the wrist. Left wing; the right mirrors it.
    static let secondaries: [Spec] = (0..<12).map { i in
        let t = CGFloat(i) / 11
        return Spec(base: CGPoint(x: lerp(cx - 98, 160, t), y: lerp(20, 22, t)), angle: lerp(3, 20, t), length: lerp(96, 106, t), width: 26)
    }
    static let primaries: [Spec] = {
        let lengths: [CGFloat] = [104, 110, 114, 116, 116, 114, 110, 104, 96]
        return (0..<9).map { j in
            let t = CGFloat(j) / 8
            return Spec(base: CGPoint(x: lerp(156, 112, t), y: lerp(24, 14, t)), angle: lerp(26, 88, t), length: lengths[j], width: lerp(22, 15, t))
        }
    }()
    static let greaterCoverts: [Spec] = (0..<11).map { i in
        let t = CGFloat(i) / 10
        return Spec(base: CGPoint(x: lerp(cx - 100, 150, t), y: 14), angle: lerp(8, 16, t), length: lerp(46, 52, t), width: 22)
    }
    static let lesserCoverts: [Spec] = (0..<10).map { i in
        let t = CGFloat(i) / 9
        return Spec(base: CGPoint(x: lerp(cx - 96, 154, t), y: 5), angle: lerp(14, 22, t), length: lerp(30, 34, t), width: 19)
    }
    static let alula: [Spec] = (0..<4).map { i in
        let t = CGFloat(i) / 3
        return Spec(base: CGPoint(x: lerp(146, 122, t), y: lerp(12, 8, t)), angle: lerp(48, 78, t), length: lerp(46, 40, t), width: 15)
    }
    /// The tail: a wide fan under the body.
    static let tail: [Spec] = (0..<11).map { k in
        let t = CGFloat(k) / 10
        return Spec(base: .zero, angle: lerp(-34, 34, t), length: 82 - 6 * abs(t - 0.5) * 2, width: 22)
    }
    static let shoulder = CGPoint(x: cx - 95, y: 8)
    static let foldAngle: CGFloat = -30

    struct Placement {
        let kind: FeatherSprites.Kind
        let base: CGPoint
        let angle: CGFloat   // radians
        let length: CGFloat
        let width: CGFloat
        let side: CGFloat    // -1 left, +1 right
    }

    /// Every feather at unfold u (0 = folded beside the body, 1 = spread), back to front.
    static func pose(_ u: CGFloat) -> [Placement] {
        let a = smooth(0, 0.7, u), lengthScale = lerp(0.3, 1, smooth(0, 0.8, u)), widthScale = lerp(0.7, 1, a)
        let kx = lerp(0.08, 1, a), ky = lerp(0.4, 1, a)
        var out: [Placement] = []
        let tt = smooth(0.25, 1, u)
        if tt > 0 {
            for f in tail {
                out.append(Placement(kind: .tail, base: CGPoint(x: cx, y: lerp(20, 58, tt)), angle: f.angle * backOut(tt, 1.2) * .pi / 180,
                                     length: f.length * lerp(0.2, 1, tt), width: f.width * lerp(0.6, 1, tt), side: -1))
            }
        }
        for side: CGFloat in [-1, 1] {
            func place(_ q: CGPoint) -> CGPoint {
                let p = CGPoint(x: shoulder.x + (q.x - shoulder.x) * kx, y: shoulder.y + (q.y - shoulder.y) * ky)
                return side < 0 ? p : CGPoint(x: 2 * cx - p.x, y: p.y)
            }
            func put(_ kind: FeatherSprites.Kind, _ f: Spec, _ r: CGFloat) {
                out.append(Placement(kind: kind, base: place(f.base), angle: lerp(foldAngle, f.angle, r) * .pi / 180,
                                     length: f.length * lengthScale, width: f.width * widthScale, side: side))
            }
            for i in stride(from: secondaries.count - 1, through: 0, by: -1) {
                put(.secondary, secondaries[i], smooth(0.04 + 0.1 * CGFloat(i) / 11, 0.75, u))
            }
            for (j, f) in primaries.enumerated() {
                let t = CGFloat(j) / 8
                put(.primary, f, backOut(smooth(0.16 + 0.22 * t, 0.85 + 0.15 * t, u), 1.3))
            }
            for f in alula { put(.covert, f, smooth(0.2, 0.9, u)) }
            for f in greaterCoverts { put(.covert, f, smooth(0, 0.65, u)) }
            for f in lesserCoverts { put(.covert, f, smooth(0, 0.6, u)) }
        }
        return out
    }

    /// The lower body under the notch: a rounded breast narrowing into the tail.
    static func body(_ p: CGFloat, pillHeight: CGFloat) -> Path {
        let depth = lerp(pillHeight - 4, 74, smooth(0, 0.6, clamp(p))), k = depth / 74
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y * k) }
        var path = Path()
        path.move(to: P(cx - 70, 0))
        path.addCurve(to: P(cx - 30, 66), control1: P(cx - 66, 26), control2: P(cx - 44, 52))
        path.addCurve(to: P(cx + 30, 66), control1: P(cx - 18, 76), control2: P(cx + 18, 76))
        path.addCurve(to: P(cx + 70, 0), control1: P(cx + 44, 52), control2: P(cx + 66, 26))
        path.closeSubpath()
        return path
    }

    /// The rectangle a sprite occupies in the feather's own (rotated) space.
    static func spriteRect(_ placement: Placement, _ sprite: FeatherSprites.Sprite) -> CGRect {
        let sx = placement.width / sprite.width, sy = placement.length / sprite.length
        return CGRect(x: -sprite.canvasSize.width / 2 * sx, y: -sprite.pad * sy,
                      width: sprite.canvasSize.width * sx, height: sprite.canvasSize.height * sy)
    }

    /// The four feather images, resolved once per frame for a canvas.
    struct ResolvedSprites {
        let sprites: [FeatherSprites.Kind: FeatherSprites.Sprite]
        let images: [FeatherSprites.Kind: GraphicsContext.ResolvedImage]

        init(_ sprites: [FeatherSprites.Kind: FeatherSprites.Sprite], in context: GraphicsContext) {
            self.sprites = sprites
            var images: [FeatherSprites.Kind: GraphicsContext.ResolvedImage] = [:]
            for (kind, sprite) in sprites { images[kind] = context.resolve(Image(decorative: sprite.image, scale: 2)) }
            self.images = images
        }
    }

    static func draw(_ placement: Placement, _ resolved: ResolvedSprites, in context: GraphicsContext) {
        guard let sprite = resolved.sprites[placement.kind], let image = resolved.images[placement.kind] else { return }
        var c = context
        c.translateBy(x: placement.base.x, y: placement.base.y)
        c.rotate(by: .radians(Double(-placement.side * placement.angle)))
        if placement.side > 0 { c.scaleBy(x: -1, y: 1) }
        c.draw(image, in: spriteRect(placement, sprite))
    }
}

// MARK: - The glass filling out from the bird

/// Distance from the bird's silhouette at half resolution (chamfer 3-4). The fill is every point
/// within r of the bird, so gaps between feathers close first and the island's corners fill last.
/// Recomputed only while the wings still move; once they're spread it's reused.
final class WingFillField {
    static let scale: CGFloat = 0.5
    let columns = Int(BirdWings.width * WingFillField.scale)
    let rows = Int(ceil(BirdWings.canvasHeight * WingFillField.scale))
    private var distance: [Float] = []
    private var key: String?
    private var alpha: [UInt8] = []

    func update(pose: [BirdWings.Placement], body: Path, key newKey: String) {
        guard newKey != key else { return }
        key = newKey
        let w = columns, h = rows
        alpha = [UInt8](repeating: 0, count: w * h)
        alpha.withUnsafeMutableBytes { buffer in
            // Grey coverage: white where the bird is (sprites composite their alpha over black).
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            // y down, island points.
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: Self.scale, y: -Self.scale)
            ctx.setFillColor(.white)
            for placement in pose {
                guard let sprite = FeatherSprites.mask[placement.kind] else { continue }
                ctx.saveGState()
                ctx.translateBy(x: placement.base.x, y: placement.base.y)
                ctx.rotate(by: -placement.side * placement.angle)
                if placement.side > 0 { ctx.scaleBy(x: -1, y: 1) }
                let rect = BirdWings.spriteRect(placement, sprite)
                // Images draw upright in a y-down context only after flipping them locally.
                ctx.translateBy(x: rect.minX, y: rect.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(sprite.image, in: CGRect(origin: .zero, size: rect.size))
                ctx.restoreGState()
            }
            ctx.addPath(body.cgPath)
            ctx.fillPath()
        }
        let infinity: Float = 1e9
        distance = alpha.map { $0 > 127 ? 0 : infinity }
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                var d = distance[i]
                if x > 0 { d = min(d, distance[i - 1] + 3) }
                if y > 0 {
                    d = min(d, distance[i - w] + 3)
                    if x > 0 { d = min(d, distance[i - w - 1] + 4) }
                    if x < w - 1 { d = min(d, distance[i - w + 1] + 4) }
                }
                distance[i] = d
            }
        }
        for y in stride(from: h - 1, through: 0, by: -1) {
            for x in stride(from: w - 1, through: 0, by: -1) {
                let i = y * w + x
                var d = distance[i]
                if x < w - 1 { d = min(d, distance[i + 1] + 3) }
                if y < h - 1 {
                    d = min(d, distance[i + w] + 3)
                    if x < w - 1 { d = min(d, distance[i + w + 1] + 4) }
                    if x > 0 { d = min(d, distance[i + w - 1] + 4) }
                }
                distance[i] = d
            }
        }
        for i in distance.indices { distance[i] /= 3 }
    }

    /// Everything within `radius` points of the bird, as a soft-edged white mask image.
    func image(radius: CGFloat) -> CGImage? {
        let w = columns, h = rows, r = Float(radius * Self.scale)
        guard distance.count == w * h else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let v = UInt8(min(1, max(0, (r - distance[i]) / 1.2 + 0.5)) * 255)
            pixels[i * 4] = v; pixels[i * 4 + 1] = v; pixels[i * 4 + 2] = v; pixels[i * 4 + 3] = v   // premultiplied white
        }
        return pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            return ctx.makeImage()
        }
    }
}

// MARK: - The layer

/// The island's glass while it opens, stays open and closes. Animatable: SwiftUI redraws it frame by
/// frame only while the progress changes; open and idle it's the plain island shape.
struct IslandWingsLayer: View, Animatable {
    var progress: CGFloat
    /// The closed pill the bird opens from and folds back into.
    var pill: CGSize
    /// Bumped once per opening: a few loose feathers drift down.
    var driftTrigger: Int

    @State private var field = WingFillField()
    @Default(.islandGlassRim) private var rimEnabled
    @Default(.islandGlassStyle) private var glassStyle
    @Default(.enableShadow) private var shadowEnabled

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let p = progress
        let settled = p >= 0.999
        let u = BirdWings.unfold(p), f = BirdWings.fill(p), detail = BirdWings.detail(p)
        let pose = (!settled && u > 0.002) ? BirdWings.pose(u) : []
        let body = BirdWings.body(p, pillHeight: pill.height)
        let fillImage: CGImage? = {
            guard !settled, f > 0 else { return nil }
            field.update(pose: pose, body: body, key: u >= 0.999 ? "spread" : String(format: "%.4f", Double(u)))
            return field.image(radius: f * 400)
        }()
        let pillPath = BirdWings.pillPath(pill)
        ZStack(alignment: .top) {
            ZStack {
                IslandBackground(isOpen: true)
                // Solid black at the very start and end, like the closed pill it grows from.
                Color.black.opacity(Double(1 - smooth(0, 0.3, clamp(p))))
            }
            .frame(width: BirdWings.width, height: BirdWings.canvasHeight)
            .mask(alignment: .topLeading) {
                if settled {
                    BirdWings.islandPath.fill(Color.white)
                        .frame(width: BirdWings.width, height: BirdWings.canvasHeight, alignment: .topLeading)
                } else {
                    Canvas { context, _ in
                        let sprites = BirdWings.ResolvedSprites(FeatherSprites.mask, in: context)
                        func bird(_ c: GraphicsContext) {
                            for placement in pose { BirdWings.draw(placement, sprites, in: c) }
                            c.fill(body, with: .color(.white))
                        }
                        context.fill(pillPath, with: .color(.white))
                        if f <= 0 {
                            bird(context)
                        } else {
                            var inside = context
                            inside.clip(to: BirdWings.islandPath)
                            bird(inside)
                            if let fillImage {
                                inside.draw(Image(decorative: fillImage, scale: 1),
                                            in: CGRect(x: 0, y: 0, width: BirdWings.width, height: CGFloat(field.rows) / WingFillField.scale))
                            }
                            if f < 1 {
                                // Wingtips reaching past the island fade as it fills.
                                var outside = context
                                outside.opacity = Double(1 - f)
                                outside.drawLayer { layer in bird(layer) }
                            }
                        }
                    }
                    .frame(width: BirdWings.width, height: BirdWings.canvasHeight)
                }
            }
            .shadow(color: shadowEnabled ? .black.opacity(0.7 * Double(smooth(0.05, 0.4, clamp(p)))) : .clear,
                    radius: Defaults[.cornerRadiusScaling] ? 6 : 4)

            if !pose.isEmpty, detail > 0.002 {
                Canvas { context, _ in
                    var c = context
                    c.opacity = Double(0.85 * detail)
                    let sprites = BirdWings.ResolvedSprites(FeatherSprites.dark, in: c)
                    for placement in pose { BirdWings.draw(placement, sprites, in: c) }
                    c.fill(body, with: .linearGradient(Gradient(colors: [.black.opacity(0.55), Color(red: 30 / 255, green: 36 / 255, blue: 56 / 255).opacity(0.55)]),
                                                       startPoint: .zero, endPoint: CGPoint(x: 0, y: 74)))
                    c.stroke(body, with: .color(Plumage.wingLight.opacity(0.16)), lineWidth: 0.8)
                }
                .frame(width: BirdWings.width, height: BirdWings.canvasHeight)
            }

            if rimEnabled, glassStyle != .solid, p > 0.93 {
                NotchShape(topCornerRadius: cornerRadiusInsets.opened.top, bottomCornerRadius: cornerRadiusInsets.opened.bottom)
                    .stroke(LinearGradient(stops: [
                        .init(color: .white.opacity(0.0), location: 0.0),
                        .init(color: .white.opacity(0.10), location: 0.55),
                        .init(color: .white.opacity(0.22), location: 1.0),
                    ], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    .frame(width: BirdWings.width, height: BirdWings.height)
                    .opacity(Double(smooth(0.93, 1, clamp(p))))
            }

            FeatherDrift(trigger: driftTrigger)
                .frame(width: BirdWings.width, height: BirdWings.canvasHeight)
        }
        .frame(width: BirdWings.width, height: BirdWings.canvasHeight, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Island content inside the wings: it arrives once the glass has filled in (soft focus to sharp)
/// and leaves at once when the bird folds.
struct WingRevealModifier: ViewModifier {
    let amount: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(Double(amount))
            .blur(radius: (1 - amount) * 6)
            .scaleEffect(0.96 + 0.04 * amount, anchor: .top)
    }
}

extension AnyTransition {
    static var wingReveal: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: WingRevealModifier(amount: 0), identity: WingRevealModifier(amount: 1))
                .animation(.smooth(duration: 0.3).delay(0.42)),
            removal: .opacity.animation(.easeOut(duration: 0.12))
        )
    }
}

/// Two or three loose feathers drift down as the island settles (≈1.4 s, then nothing to draw).
struct FeatherDrift: View {
    let trigger: Int
    @State private var start: Date?
    @State private var endTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let duration: Double = 1.4
    private struct Loose { let x, y, vx, vy, rotation, spin, phase: CGFloat }
    private static let feathers = [
        Loose(x: 168, y: 104, vx: -14, vy: 32, rotation: -0.5, spin: 1.1, phase: 0),
        Loose(x: 512, y: 100, vx: 12, vy: 36, rotation: 0.6, spin: -1.0, phase: 2),
        Loose(x: 352, y: 146, vx: 4, vy: 24, rotation: 0.2, spin: 0.8, phase: 4),
    ]

    var body: some View {
        Group {
            if let start {
                TimelineView(.animation) { timeline in
                    let k = CGFloat(min(1, timeline.date.timeIntervalSince(start) / Self.duration))
                    Canvas { context, _ in
                        var c = context
                        c.opacity = Double(0.85 * (k < 0.15 ? k / 0.15 : 1 - (k - 0.15) / 0.85))
                        let sprites = BirdWings.ResolvedSprites(FeatherSprites.dark, in: c)
                        for f in Self.feathers {
                            let base = CGPoint(x: f.x + f.vx * k + 6 * sin(k * .pi * 2 + f.phase), y: f.y + f.vy * k)
                            BirdWings.draw(BirdWings.Placement(kind: .covert, base: base, angle: f.rotation + f.spin * k,
                                                               length: 18, width: 8, side: -1),
                                           sprites, in: c)
                        }
                    }
                }
            }
        }
        .onChange(of: trigger) {
            guard !reduceMotion else { return }
            start = Date()
            endTask?.cancel()
            endTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.duration + 0.05))
                if !Task.isCancelled { start = nil }
            }
        }
        .allowsHitTesting(false)
    }
}
