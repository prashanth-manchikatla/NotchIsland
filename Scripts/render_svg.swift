// Renders an SVG to a square PNG with real transparency, using macOS's own SVG support.
// Usage (Scripts/make_icons.sh compiles and runs it):  render_svg <in.svg> <pixels> <out.png>
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 4, let pixels = Int(arguments[2]), pixels > 0 else {
    FileHandle.standardError.write(Data("usage: render_svg <in.svg> <pixels> <out.png>\n".utf8))
    exit(2)
}
guard let image = NSImage(contentsOfFile: arguments[1]) else {
    FileHandle.standardError.write(Data("could not read \(arguments[1])\n".utf8))
    exit(1)
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: arguments[3]))
