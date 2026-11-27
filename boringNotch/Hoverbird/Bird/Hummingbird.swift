//
//  Hummingbird.swift
//  Hoverbird
//
//  The app icon's hummingbird as vector art, plus the two places it lives in the island:
//  empty states (it hovers for a moment, then rests) and "working…" indicators (it keeps flapping).
//  The wingbeat only redraws while the bird moves; at rest it costs nothing.
//

import AppKit
import SwiftUI

/// The icon's hummingbird in its own SVG units (the glyph box is x 250…850, y 150…830).
enum HummingbirdArt {
    static let box = CGRect(x: 250, y: 150, width: 600, height: 680)
    static let aspect: CGFloat = 600.0 / 680.0
    /// Where both wings meet the body; the wingbeat rotates around it.
    static let shoulder = CGPoint(x: 548, y: 468)

    static let body: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 560, y: 330))
        p.addCurve(to: CGPoint(x: 676, y: 350), control1: CGPoint(x: 596, y: 300), control2: CGPoint(x: 656, y: 304))
        p.addCurve(to: CGPoint(x: 664, y: 428), control1: CGPoint(x: 688, y: 378), control2: CGPoint(x: 682, y: 408))
        p.addCurve(to: CGPoint(x: 634, y: 504), control1: CGPoint(x: 646, y: 448), control2: CGPoint(x: 640, y: 474))
        p.addCurve(to: CGPoint(x: 546, y: 650), control1: CGPoint(x: 622, y: 560), control2: CGPoint(x: 590, y: 612))
        p.addCurve(to: CGPoint(x: 452, y: 710), control1: CGPoint(x: 516, y: 676), control2: CGPoint(x: 482, y: 696))
        p.addCurve(to: CGPoint(x: 441, y: 699), control1: CGPoint(x: 444, y: 714), control2: CGPoint(x: 437, y: 707))
        p.addCurve(to: CGPoint(x: 478, y: 588), control1: CGPoint(x: 458, y: 664), control2: CGPoint(x: 470, y: 626))
        p.addCurve(to: CGPoint(x: 520, y: 418), control1: CGPoint(x: 490, y: 528), control2: CGPoint(x: 500, y: 470))
        p.addCurve(to: CGPoint(x: 560, y: 330), control1: CGPoint(x: 530, y: 388), control2: CGPoint(x: 542, y: 352))
        p.closeSubpath()
        return p
    }()

    static let beak: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 676, y: 360))
        p.addQuadCurve(to: CGPoint(x: 812, y: 320), control: CGPoint(x: 744, y: 338))
        return p
    }()

    static func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, degrees: CGFloat) -> Path {
        let rotation = CGAffineTransform(translationX: cx, y: cy).rotated(by: degrees * .pi / 180).translatedBy(x: -cx, y: -cy)
        return Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)).applying(rotation)
    }

    static let frontWing = ellipse(453, 335, 168, 56, degrees: 55)
    static let frontGlint = ellipse(420, 292, 96, 14, degrees: 55)
    static let backWing = ellipse(407, 419, 152, 48, degrees: 20)
    static let tailA = ellipse(398, 752, 68, 22, degrees: 135)
    static let tailB = ellipse(421, 767, 68, 22, degrees: 112)
    static let eye = Path(ellipseIn: CGRect(x: 614.5, y: 350.5, width: 19, height: 19))

    /// Draws the bird fitted into `size`. `front`/`back`: wing angles in degrees around the shoulder;
    /// `lift`: vertical offset in icon units; `ghost`: angle of a faint second wing (wingbeat blur);
    /// `tint`: a single colour for tiny indicators (nil = the icon's plumage).
    static func draw(_ context: GraphicsContext, size: CGSize, front: Double, back: Double,
                     lift: CGFloat = 0, ghost: Double = 0, tint: Color? = nil) {
        var ctx = context
        let s = min(size.width / box.width, size.height / box.height)
        ctx.translateBy(x: (size.width - box.width * s) / 2, y: (size.height - box.height * s) / 2)
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -box.minX, y: -box.minY + lift)

        func wing(_ path: Path, angle: Double, shading: GraphicsContext.Shading, opacity: Double) {
            let passes: [(Double, Double)] = ghost != 0 ? [(-ghost, 0.32), (0, 1)] : [(0, 1)]
            for (offset, alpha) in passes {
                var w = ctx
                w.opacity = opacity * alpha
                w.translateBy(x: shoulder.x, y: shoulder.y)
                w.rotate(by: .degrees(angle + offset))
                w.translateBy(x: -shoulder.x, y: -shoulder.y)
                w.fill(path, with: shading)
            }
        }
        func diagonal(_ a: Color, _ b: Color, over rect: CGRect) -> GraphicsContext.Shading {
            .linearGradient(Gradient(colors: [a, b]), startPoint: rect.origin, endPoint: CGPoint(x: rect.maxX, y: rect.maxY))
        }

        if let tint {
            wing(backWing, angle: back, shading: .color(tint), opacity: 0.5)
            var tail = ctx
            tail.opacity = 0.7
            tail.fill(tailA, with: .color(tint))
            tail.fill(tailB, with: .color(tint))
            ctx.fill(body, with: .color(tint))
            ctx.stroke(beak, with: .color(tint), style: StrokeStyle(lineWidth: 24, lineCap: .round))
            wing(frontWing, angle: front, shading: .color(tint), opacity: 0.85)
            ctx.fill(eye, with: .color(.black.opacity(0.7)))
            return
        }
        wing(backWing, angle: back, shading: diagonal(Plumage.plumeLight, Plumage.plumeDeep, over: backWing.boundingRect), opacity: 0.7)
        var tail = ctx
        tail.opacity = 0.65
        tail.fill(tailA, with: .color(Plumage.tail))
        tail.opacity = 0.85
        tail.fill(tailB, with: .color(Plumage.tail))
        ctx.fill(body, with: .linearGradient(Gradient(colors: [Plumage.bodyLight, Plumage.plumeDeep]),
                                             startPoint: CGPoint(x: 650, y: 320), endPoint: CGPoint(x: 450, y: 712)))
        ctx.fill(body, with: .linearGradient(Gradient(colors: [.white.opacity(0.45), .white.opacity(0)]),
                                             startPoint: CGPoint(x: 560, y: 320), endPoint: CGPoint(x: 600, y: 520)))
        ctx.stroke(beak, with: .color(Plumage.wingLight), style: StrokeStyle(lineWidth: 14, lineCap: .round))
        wing(frontWing, angle: front, shading: diagonal(Plumage.wingLight, Plumage.wingDeep, over: frontWing.boundingRect), opacity: 0.82)
        wing(frontGlint, angle: front, shading: .color(.white), opacity: 0.35)
        ctx.fill(eye, with: .color(Plumage.eye))
    }
}

/// The hummingbird. `.flutter(n)` hovers for n seconds when it appears (and briefly again on hover),
/// `.working` keeps flapping at a low frame rate while visible, `.rest` stays still.
struct HummingbirdView: View {
    enum Motion: Equatable {
        case rest
        case flutter(TimeInterval)
        case working
    }

    var motion: Motion = .flutter(2.2)
    var tint: Color? = nil
    var flutterOnHover = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var fluttering = false
    @State private var stopTask: Task<Void, Never>?

    private var animating: Bool { !reduceMotion && (motion == .working || fluttering) }

    var body: some View {
        Group {
            if motion == .working && !reduceMotion {
                // A timer, not the display link: it wakes 10 times a second and nothing more.
                TimelineView(.periodic(from: start, by: 0.1)) { timeline in bird(at: timeline.date) }
            } else {
                TimelineView(.animation(minimumInterval: nil, paused: !animating)) { timeline in bird(at: timeline.date) }
            }
        }
        .aspectRatio(HummingbirdArt.aspect, contentMode: .fit)
        .onAppear {
            if case .flutter(let seconds) = motion { flutter(for: seconds) }
        }
        .onDisappear {
            stopTask?.cancel()
            fluttering = false
        }
        .onHover { inside in
            if inside, flutterOnHover, motion != .working { flutter(for: 1.2) }
        }
        .accessibilityHidden(true)
    }

    private func bird(at date: Date) -> some View {
        let pose = pose(at: date)
        return Canvas { context, size in
            HummingbirdArt.draw(context, size: size, front: pose.front, back: pose.back,
                                lift: pose.lift, ghost: pose.ghost, tint: tint)
        }
    }

    private func flutter(for seconds: TimeInterval) {
        guard !reduceMotion else { return }
        start = Date()
        fluttering = true
        stopTask?.cancel()
        stopTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { fluttering = false }
        }
    }

    private func pose(at date: Date) -> (front: Double, back: Double, lift: CGFloat, ghost: Double) {
        guard animating else { return (0, 0, 0, 0) }
        let t = date.timeIntervalSince(start)
        if motion == .working {
            // Four poses at 10 fps: a steady, cheap wingbeat.
            let step = Int((t * 10).rounded()) % 4
            let front: [Double] = [-16, 2, 18, 2], back: [Double] = [-12, 1, 14, 1]
            return (front[step], back[step], 0, 0)
        }
        let beat = sin(2 * .pi * 7 * t)
        return (1 + 17 * beat, 1 + 13 * sin(2 * .pi * 7 * t + 0.6), CGFloat(-10 * sin(2 * .pi * 0.7 * t)), 7)
    }
}

/// An empty section: the hummingbird keeps the seat warm.
struct BirdEmptyState: View {
    let title: String
    var detail: String? = nil
    var birdHeight: CGFloat = 58

    var body: some View {
        HStack(spacing: 12) {
            HummingbirdView(motion: .flutter(2.2))
                .frame(width: birdHeight * HummingbirdArt.aspect, height: birdHeight)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.gray)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 100)
    }
}

/// A small flapping hummingbird for "working…" moments (instead of a spinner). A tinted bird (an AI
/// agent's colour, which can show for hours) flaps in Core Animation, so Hoverbird itself does no work
/// per frame; the full-colour bird is for brief moments.
struct BirdActivityIndicator: View {
    var size: CGFloat = 16
    var tint: Color? = nil

    var body: some View {
        Group {
            if let tint {
                HummingbirdLayerView(tint: NSColor(tint))
            } else {
                HummingbirdView(motion: .working, flutterOnHover: false)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("Working")
    }
}

/// The tinted hummingbird as layers whose wingbeat is a repeating Core Animation: the render server
/// animates it, the app doesn't wake up for it.
struct HummingbirdLayerView: NSViewRepresentable {
    let tint: NSColor

    func makeNSView(context: Context) -> HummingbirdLayerNSView { HummingbirdLayerNSView(tint: tint) }
    func updateNSView(_ view: HummingbirdLayerNSView, context: Context) { view.tint = tint }
}

final class HummingbirdLayerNSView: NSView {
    private let container = CALayer()
    private let backWing = CAShapeLayer(), tail = CAShapeLayer(), body = CAShapeLayer()
    private let beak = CAShapeLayer(), frontWing = CAShapeLayer(), eye = CAShapeLayer()

    var tint: NSColor {
        didSet { if tint != oldValue { applyColours() } }
    }

    init(tint: NSColor) {
        self.tint = tint
        super.init(frame: .zero)
        wantsLayer = true
        // The sublayer transform applies around the anchor point; keep it at the origin.
        container.anchorPoint = .zero
        layer?.addSublayer(container)
        let box = HummingbirdArt.box
        let tailPath = CGMutablePath()
        tailPath.addPath(HummingbirdArt.tailA.cgPath)
        tailPath.addPath(HummingbirdArt.tailB.cgPath)
        let parts: [(CAShapeLayer, CGPath)] = [(backWing, HummingbirdArt.backWing.cgPath), (tail, tailPath), (body, HummingbirdArt.body.cgPath),
                                               (beak, HummingbirdArt.beak.cgPath), (frontWing, HummingbirdArt.frontWing.cgPath),
                                               (eye, HummingbirdArt.eye.cgPath)]
        for (shape, path) in parts {
            // Every layer spans the icon's box in its own units; the container maps them into the view.
            shape.bounds = box
            shape.position = CGPoint(x: box.midX, y: box.midY)
            shape.path = path
            container.addSublayer(shape)
        }
        for wing in [backWing, frontWing] {
            wing.anchorPoint = CGPoint(x: (HummingbirdArt.shoulder.x - box.minX) / box.width,
                                       y: (HummingbirdArt.shoulder.y - box.minY) / box.height)
            wing.position = HummingbirdArt.shoulder
        }
        beak.fillColor = nil
        beak.lineWidth = 24
        beak.lineCap = .round
        backWing.opacity = 0.5
        tail.opacity = 0.7
        frontWing.opacity = 0.85
        applyColours()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyColours() {
        let colour = tint.cgColor
        for shape in [backWing, tail, body, frontWing] { shape.fillColor = colour }
        beak.strokeColor = colour
        eye.fillColor = NSColor.black.withAlphaComponent(0.7).cgColor
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bounds
        // Icon units (y down) → the view (y up), fitted and centred.
        let box = HummingbirdArt.box
        let s = min(bounds.width / box.width, bounds.height / box.height)
        let tx = (bounds.width - box.width * s) / 2 - box.minX * s
        let ty = bounds.height - (bounds.height - box.height * s) / 2 + box.minY * s
        container.sublayerTransform = CATransform3DConcat(CATransform3DMakeScale(s, -s, 1), CATransform3DMakeTranslation(tx, ty, 0))
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            frontWing.removeAllAnimations()
            backWing.removeAllAnimations()
        } else if frontWing.animation(forKey: "beat") == nil {
            beat(frontWing, from: -16, to: 18, offset: 0)
            beat(backWing, from: -12, to: 14, offset: 0.03)
        }
    }

    private func beat(_ wing: CALayer, from: CGFloat, to: CGFloat, offset: CFTimeInterval) {
        let beat = CABasicAnimation(keyPath: "transform.rotation.z")
        beat.fromValue = from * .pi / 180
        beat.toValue = to * .pi / 180
        beat.duration = 0.13
        beat.autoreverses = true
        beat.repeatCount = .greatestFiniteMagnitude
        beat.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        beat.timeOffset = offset
        wing.add(beat, forKey: "beat")
    }
}
