import C64Kit
import CoreGraphics

/// How C64 pixels are shaped on screen.
enum PixelAspect: String, CaseIterable, Sendable {
    /// An NTSC TV: C64 pixels are 0.75 as wide as they are tall (exact at 3×4 and 6×8 pixels).
    case ntsc
    /// Square pixels.
    case square

    /// Pixel width divided by pixel height.
    var ratio: Double {
        switch self {
        case .ntsc: return 0.75
        case .square: return 1
        }
    }
}

/// How the frame is sized in the window.
enum ZoomMode: Equatable, Sendable {
    /// A fixed integer zoom: each C64 pixel is `n` points wide (and `n / aspect` points tall).
    case fixed(Int)
    /// As large as fits the window, keeping the aspect (letterboxed in black).
    case fit
}

/// Pure presentation math: window sizes for each zoom, the letterboxed destination rectangle and
/// the integer prescale factors for "sharp bilinear" scaling.
///
/// The frame is first scaled by integers (nearest neighbor, on the CPU) as close to the
/// destination size as possible without exceeding it; the layer then magnifies that image linearly
/// by the remaining fraction, which only softens the edges between C64 pixels. When the destination
/// is an exact integer multiple the result is exact. Zoom is measured in points, so the NTSC aspect is
/// exact at zoom 3 and 6 (3×4 / 6×8 physical pixels on a 1× display, 6×8 / 12×16 on Retina).
enum DisplayGeometry {
    static let sourceWidth = VICPresenter.width     // 384
    static let sourceHeight = VICPresenter.height   // 248
    static let zoomRange = 2...6
    /// Largest integer prescale (bounds memory: a 384×248 frame at 16×16 is 6144×3968).
    static let maxPrescale = 16

    struct Layout: Equatable, Sendable {
        /// Where the frame goes, in view points (aligned to physical pixels).
        var destination: CGRect
        /// Integer nearest-neighbor factors applied before the layer's linear magnification.
        var prescaleX: Int
        var prescaleY: Int

        /// Size in physical pixels of the prescaled image.
        var prescaledSize: (width: Int, height: Int) {
            (DisplayGeometry.sourceWidth * prescaleX, DisplayGeometry.sourceHeight * prescaleY)
        }
    }

    /// Size in points of the frame at an integer zoom.
    static func contentSize(zoom: Int, aspect: PixelAspect) -> CGSize {
        CGSize(width: Double(sourceWidth * zoom), height: Double(sourceHeight * zoom) / aspect.ratio)
    }

    /// The frame's width / height on screen.
    static func displayAspect(_ aspect: PixelAspect) -> Double {
        Double(sourceWidth) * aspect.ratio / Double(sourceHeight)
    }

    /// The largest zoom whose window fits in `available` (at least the smallest zoom).
    static func largestZoom(fitting available: CGSize, aspect: PixelAspect) -> Int {
        var best = zoomRange.lowerBound
        for z in zoomRange {
            let s = contentSize(zoom: z, aspect: aspect)
            if s.width <= available.width && s.height <= available.height { best = z }
        }
        return best
    }

    /// Lays out the frame in a view of `bounds` points on a display with `scale` pixels per point.
    static func layout(bounds: CGSize, scale: CGFloat, mode: ZoomMode, aspect: PixelAspect) -> Layout {
        let scale = max(scale, 1)
        let pw = Double(bounds.width * scale), ph = Double(bounds.height * scale)   // physical pixels
        var w: Double, h: Double
        let fitted: (Double, Double) = {
            let a = displayAspect(aspect)
            return pw / ph > a ? (ph * a, ph) : (pw, pw / a)
        }()
        switch mode {
        case .fixed(let zoom):
            let s = contentSize(zoom: zoom, aspect: aspect)
            w = Double(s.width * scale); h = Double(s.height * scale)
            if w > pw + 0.5 || h > ph + 0.5 { (w, h) = fitted }
        case .fit:
            (w, h) = fitted
        }
        // Align to physical pixels; center.
        w = max(1, w.rounded()); h = max(1, h.rounded())
        let x = ((pw - w) / 2).rounded(.down), y = ((ph - h) / 2).rounded(.down)
        let s = Double(scale)
        let rect = CGRect(x: x / s, y: y / s, width: w / s, height: h / s)
        let px = min(maxPrescale, max(1, Int((w + 1e-6) / Double(sourceWidth))))
        let py = min(maxPrescale, max(1, Int((h + 1e-6) / Double(sourceHeight))))
        return Layout(destination: rect, prescaleX: px, prescaleY: py)
    }
}
