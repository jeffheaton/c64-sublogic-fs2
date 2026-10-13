#if canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes indexed C64 frames as PNG files (used by the lab, tests and the app's headless mode).
public enum ImageWriter {
    public enum Error: Swift.Error { case cannotCreate(URL) }

    /// Expands palette indices to an RGBA image and writes it as PNG, optionally scaled by integer factors.
    public static func writePNG(indices: [UInt8], width: Int, height: Int, palette: [UInt32] = C64Palette.color,
                                scaleX: Int = 1, scaleY: Int = 1, to url: URL) throws {
        let w = width * scaleX, h = height * scaleY
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let sy = y / scaleY
            for x in 0..<w {
                let c = palette[Int(indices[sy * width + x / scaleX] & 0x0F)]
                let o = (y * w + x) * 4
                rgba[o] = UInt8((c >> 16) & 0xFF)
                rgba[o + 1] = UInt8((c >> 8) & 0xFF)
                rgba[o + 2] = UInt8(c & 0xFF)
                rgba[o + 3] = 0xFF
            }
        }
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Error.cannotCreate(url)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw Error.cannotCreate(url) }
    }
}
#endif
