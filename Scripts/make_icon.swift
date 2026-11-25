// Renders Hoverbird's app icon to a 1024x1024 PNG.
// Usage: swiftc -O Scripts/make_icon.swift -o /tmp/make_icon && /tmp/make_icon out.png
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError() }

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
// Work in top-left coordinates.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

func linear(_ colors: [CGColor], _ locs: [CGFloat], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

// 1. Squircle body with drop shadow
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 40, color: color(0x000000, 0.45))
ctx.addPath(bodyPath); ctx.setFillColor(color(0x111317)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
linear([color(0x3B414F), color(0x16181E), color(0x0A0B0E)], [0, 0.55, 1],
       from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924))
// soft colored glow at the bottom
let glow = CGGradient(colorsSpace: cs, colors: [color(0x5E5CE6, 0.38), color(0x5E5CE6, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 900), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 900), endRadius: 520, options: [])
ctx.restoreGState()
// hairline rim
ctx.addPath(bodyPath); ctx.setStrokeColor(color(0xFFFFFF, 0.08)); ctx.setLineWidth(4); ctx.strokePath()

// 2. The island pill (black glass)
let pill = CGRect(x: 182, y: 330, width: 660, height: 196)
let pillPath = CGPath(roundedRect: pill, cornerWidth: 98, cornerHeight: 98, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 26), blur: 60, color: color(0x000000, 0.75))
ctx.addPath(pillPath); ctx.setFillColor(color(0x030304)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(pillPath); ctx.clip()
linear([color(0x1C1D22), color(0x050506)], [0, 1], from: CGPoint(x: 512, y: pill.minY), to: CGPoint(x: 512, y: pill.maxY))
// glass sheen on the upper half
linear([color(0xFFFFFF, 0.16), color(0xFFFFFF, 0.0)], [0, 1],
       from: CGPoint(x: 512, y: pill.minY), to: CGPoint(x: 512, y: pill.midY + 6))
ctx.restoreGState()
ctx.addPath(pillPath); ctx.setStrokeColor(color(0xFFFFFF, 0.16)); ctx.setLineWidth(3); ctx.strokePath()

// 3. Album art (leading)
let art = CGRect(x: pill.minX + 44, y: pill.midY - 56, width: 112, height: 112)
let artPath = CGPath(roundedRect: art, cornerWidth: 30, cornerHeight: 30, transform: nil)
ctx.saveGState()
ctx.addPath(artPath); ctx.clip()
linear([color(0xFFB340), color(0xFF375F), color(0xBF5AF2)], [0, 0.55, 1],
       from: CGPoint(x: art.minX, y: art.minY), to: CGPoint(x: art.maxX, y: art.maxY))
linear([color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)], [0, 1],
       from: CGPoint(x: art.midX, y: art.minY), to: CGPoint(x: art.midX, y: art.midY))
ctx.restoreGState()

// 4. Waveform (trailing)
let heights: [CGFloat] = [46, 92, 128, 74, 104, 56]
let barW: CGFloat = 18, gap: CGFloat = 14
var x = pill.maxX - 50 - CGFloat(heights.count) * barW - CGFloat(heights.count - 1) * gap
for h in heights {
    let r = CGRect(x: x, y: pill.midY - h / 2, width: barW, height: h)
    let p = CGPath(roundedRect: r, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil)
    ctx.saveGState(); ctx.addPath(p); ctx.clip()
    linear([color(0x64D2FF), color(0x30D158)], [0, 1], from: CGPoint(x: r.midX, y: r.minY), to: CGPoint(x: r.midX, y: r.maxY))
    ctx.restoreGState()
    x += barW + gap
}

// 5. Camera lens dot in the middle of the pill (the "island")
let lens = CGRect(x: 512 - 22, y: pill.midY - 22, width: 44, height: 44)
ctx.setFillColor(color(0x0B0D16)); ctx.fillEllipse(in: lens)
ctx.setStrokeColor(color(0x2C3A66, 0.9)); ctx.setLineWidth(4); ctx.strokeEllipse(in: lens.insetBy(dx: 6, dy: 6))
ctx.setFillColor(color(0x6E8BFF, 0.55)); ctx.fillEllipse(in: CGRect(x: lens.midX + 2, y: lens.minY + 10, width: 8, height: 8))

// 6. Three stacked "cards" below the island (clipboard stack / widgets)
for i in 0..<3 {
    let w: CGFloat = 520 - CGFloat(i) * 70
    let r = CGRect(x: 512 - w / 2, y: 610 + CGFloat(i) * 64, width: w, height: 44)
    let p = CGPath(roundedRect: r, cornerWidth: 22, cornerHeight: 22, transform: nil)
    ctx.addPath(p); ctx.setFillColor(color(0xFFFFFF, 0.10 - CGFloat(i) * 0.025)); ctx.fillPath()
}

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
