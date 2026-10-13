// Draws the app icon (an attitude indicator: banked horizon, sky over ground, a small aircraft
// symbol) as an .iconset folder for `iconutil`. Original artwork in C64 palette colors; no
// SubLogic graphics. Usage: swift Packaging/make-icon.swift <out.iconset>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func drawIcon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // macOS icon grid: the body is about 80% of the canvas, corner radius about 22.5% of the body.
    let inset = s * 0.1
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = body.width * 0.225
    let shape = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    // Bezel.
    ctx.setFillColor(rgb(0x4A4A4A))
    ctx.fill(body)
    // Instrument face: a circle split by a banked horizon.
    let center = CGPoint(x: body.midX, y: body.midY)
    let r = body.width * 0.38
    let face = CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
    ctx.saveGState()
    ctx.addEllipse(in: face)
    ctx.clip()
    ctx.setFillColor(rgb(0x706DEB))   // sky (light blue)
    ctx.fill(face)
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: -0.26)              // banked about 15 degrees
    ctx.setFillColor(rgb(0x553800))   // ground (brown)
    ctx.fill(CGRect(x: -2 * r, y: -2 * r, width: 4 * r, height: 2 * r - r * 0.12))
    ctx.setStrokeColor(rgb(0xFFFFFF))
    ctx.setLineWidth(max(1, s * 0.012))
    ctx.move(to: CGPoint(x: -2 * r, y: -r * 0.12))
    ctx.addLine(to: CGPoint(x: 2 * r, y: -r * 0.12))
    ctx.strokePath()
    ctx.restoreGState()
    // Ring around the face.
    ctx.setStrokeColor(rgb(0xFFFFFF))
    ctx.setLineWidth(max(1, s * 0.03))
    ctx.strokeEllipse(in: face)
    // Fixed aircraft symbol.
    ctx.setStrokeColor(rgb(0xEDF171))   // yellow
    ctx.setLineWidth(max(1, s * 0.035))
    ctx.setLineCap(.round)
    let w = r * 0.62
    ctx.move(to: CGPoint(x: center.x - w, y: center.y))
    ctx.addLine(to: CGPoint(x: center.x - w * 0.3, y: center.y))
    ctx.addLine(to: CGPoint(x: center.x, y: center.y - w * 0.22))
    ctx.addLine(to: CGPoint(x: center.x + w * 0.3, y: center.y))
    ctx.addLine(to: CGPoint(x: center.x + w, y: center.y))
    ctx.strokePath()
    ctx.restoreGState()
    return ctx.makeImage()!
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "FS2.iconset",
              isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let url = out.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, drawIcon(size: base * scale), nil)
        guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(url.path)") }
    }
}
