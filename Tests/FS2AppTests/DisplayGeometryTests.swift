import C64Kit
import CoreGraphics
import Foundation
@testable import FS2App
import Testing

@Suite struct DisplayGeometryTests {
    @Test func contentSizes() {
        #expect(DisplayGeometry.contentSize(zoom: 3, aspect: .ntsc) == CGSize(width: 1152, height: 992))
        #expect(DisplayGeometry.contentSize(zoom: 6, aspect: .ntsc) == CGSize(width: 2304, height: 1984))
        #expect(DisplayGeometry.contentSize(zoom: 2, aspect: .square) == CGSize(width: 768, height: 496))
        let a = DisplayGeometry.displayAspect(.ntsc)
        #expect(abs(a - 384 * 0.75 / 248) < 1e-12)
    }

    /// NTSC is exact (no interpolation) at 3×4 and 6×8 physical pixels per C64 pixel.
    @Test func ntscIsExactAtZoomThreeAndSix() {
        for (zoom, scale, px, py) in [(3, 1.0, 3, 4), (3, 2.0, 6, 8), (6, 1.0, 6, 8)] {
            let size = DisplayGeometry.contentSize(zoom: zoom, aspect: .ntsc)
            let g = DisplayGeometry.layout(bounds: size, scale: CGFloat(scale), mode: .fixed(zoom), aspect: .ntsc)
            #expect(g.prescaleX == px && g.prescaleY == py, "zoom \(zoom) at \(scale)x")
            // The prescaled image covers the destination exactly: no fractional remainder.
            #expect(Double(g.prescaledSize.width) == Double(g.destination.width) * scale)
            #expect(Double(g.prescaledSize.height) == Double(g.destination.height) * scale)
            #expect(g.destination.origin == .zero)
        }
    }

    @Test func squarePixelsAreExactAtEveryZoom() {
        for zoom in DisplayGeometry.zoomRange {
            let size = DisplayGeometry.contentSize(zoom: zoom, aspect: .square)
            let g = DisplayGeometry.layout(bounds: size, scale: 1, mode: .fixed(zoom), aspect: .square)
            #expect(g.prescaleX == zoom && g.prescaleY == zoom)
            #expect(g.destination.size == size)
        }
    }

    @Test func fractionalZoomPrescalesByTheIntegerPart() {
        // NTSC zoom 2 is 2 × 2.67 points: prescale 2×2, the layer interpolates the rest.
        let size = DisplayGeometry.contentSize(zoom: 2, aspect: .ntsc)
        let g = DisplayGeometry.layout(bounds: size, scale: 1, mode: .fixed(2), aspect: .ntsc)
        #expect(g.prescaleX == 2 && g.prescaleY == 2)
        #expect(Double(g.prescaledSize.height) <= Double(g.destination.height))
    }

    @Test func fixedZoomIsCenteredInALargerView() {
        let g = DisplayGeometry.layout(bounds: CGSize(width: 2000, height: 1200), scale: 1, mode: .fixed(3),
                                       aspect: .ntsc)
        #expect(g.destination == CGRect(x: 424, y: 104, width: 1152, height: 992))
    }

    @Test func fixedZoomTooLargeFallsBackToFit() {
        let bounds = CGSize(width: 800, height: 600)
        let fixed = DisplayGeometry.layout(bounds: bounds, scale: 1, mode: .fixed(6), aspect: .ntsc)
        let fit = DisplayGeometry.layout(bounds: bounds, scale: 1, mode: .fit, aspect: .ntsc)
        #expect(fixed == fit)
    }

    @Test func fitLetterboxesAndKeepsAspect() {
        for bounds in [CGSize(width: 1920, height: 1080), CGSize(width: 900, height: 1400), CGSize(width: 1000, height: 1000)] {
            for aspect in PixelAspect.allCases {
                for scale in [1.0, 2.0] {
                    let g = DisplayGeometry.layout(bounds: bounds, scale: CGFloat(scale), mode: .fit, aspect: aspect)
                    let d = g.destination
                    // Fills one dimension (within a pixel), fits the other, centered.
                    let fillsWidth = abs(d.width - bounds.width) <= 1 / scale
                    let fillsHeight = abs(d.height - bounds.height) <= 1 / scale
                    #expect(fillsWidth || fillsHeight)
                    #expect(d.maxX <= bounds.width + 1e-9 && d.maxY <= bounds.height + 1e-9)
                    #expect(abs(d.midX - bounds.width / 2) <= 1 && abs(d.midY - bounds.height / 2) <= 1)
                    let ratio = Double(d.width / d.height)
                    #expect(abs(ratio - DisplayGeometry.displayAspect(aspect)) < 0.01)
                    // Aligned to physical pixels.
                    for v in [d.minX, d.minY, d.width, d.height] {
                        #expect(abs(Double(v) * scale - (Double(v) * scale).rounded()) < 1e-6)
                    }
                    // The prescaled image never exceeds the destination (only magnification remains).
                    #expect(Double(g.prescaledSize.width) <= Double(d.width) * scale + 1e-6)
                    #expect(Double(g.prescaledSize.height) <= Double(d.height) * scale + 1e-6)
                }
            }
        }
    }

    @Test func tinyViewsStillGetPrescaleOne() {
        let g = DisplayGeometry.layout(bounds: CGSize(width: 100, height: 50), scale: 1, mode: .fit, aspect: .ntsc)
        #expect(g.prescaleX == 1 && g.prescaleY == 1)
        #expect(g.destination.width > 0 && g.destination.height > 0)
    }

    @Test func prescaleIsCapped() {
        let g = DisplayGeometry.layout(bounds: CGSize(width: 20000, height: 20000), scale: 2, mode: .fit, aspect: .square)
        #expect(g.prescaleX == DisplayGeometry.maxPrescale && g.prescaleY == DisplayGeometry.maxPrescale)
    }

    @Test func largestZoomFitting() {
        #expect(DisplayGeometry.largestZoom(fitting: CGSize(width: 1400, height: 1000), aspect: .ntsc) == 3)
        #expect(DisplayGeometry.largestZoom(fitting: CGSize(width: 1300, height: 800), aspect: .ntsc) == 2)
        #expect(DisplayGeometry.largestZoom(fitting: CGSize(width: 500, height: 300), aspect: .ntsc) == 2)
        #expect(DisplayGeometry.largestZoom(fitting: CGSize(width: 5000, height: 5000), aspect: .square) == 6)
    }

    @Test func converterScalesWithNearestNeighbor() {
        let w = 4, h = 3
        let src: [UInt8] = (0..<(w * h)).map { UInt8($0 & 0x0F) }
        let out = FrameConverter.convert(indices: src, width: w, height: h, palette: C64Palette.color,
                                         scaleX: 3, scaleY: 2)
        #expect(out.count == w * 3 * h * 2)
        for y in 0..<(h * 2) {
            for x in 0..<(w * 3) {
                #expect(out[y * w * 3 + x] == C64Palette.color[Int(src[(y / 2) * w + x / 3])])
            }
        }
        // Monochrome palette entries are gray and opaque.
        for c in C64Palette.monochrome {
            #expect(c >> 24 == 0xFF && (c >> 16) & 0xFF == c & 0xFF && (c >> 8) & 0xFF == c & 0xFF)
        }
    }

    @Test func settingsRoundTrip() throws {
        let suite = "FS2AppTests.settings.\(UInt32.random(in: 0...UInt32.max))"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        #expect(AppSettings.load(from: d) == AppSettings())
        #expect(!AppSettings.hasStoredZoom(in: d))
        var s = AppSettings()
        s.zoom = 5; s.fitWindow = true; s.aspect = .square; s.pacing = .smooth; s.monitor = .blackAndWhite
        s.keypadJoystick = false; s.strictJoystick = true; s.gamepadEnabled = false; s.soundEnabled = false
        s.volume = 0.25
        s.save(to: d)
        #expect(AppSettings.load(from: d) == s)
        #expect(s.zoomMode == .fit)
        d.set(42, forKey: AppSettings.Key.zoom)   // out of range: ignored
        #expect(AppSettings.load(from: d).zoom == AppSettings().zoom)
    }

    /// Random view sizes, scales, modes and aspects: the frame stays inside the view, centered,
    /// pixel aligned, at the right aspect, and the prescale is the largest integer that still fits
    /// (or the cap), so the layer only ever magnifies.
    @Test func layoutPropertiesHoldForRandomViews() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let bounds = CGSize(width: Double.random(in: 1...4000, using: &rng).rounded(),
                                height: Double.random(in: 1...3000, using: &rng).rounded())
            let scale = CGFloat([1.0, 2.0, 3.0].randomElement(using: &rng)!)
            let aspect = PixelAspect.allCases.randomElement(using: &rng)!
            let mode: ZoomMode = Bool.random(using: &rng) ? .fit : .fixed(Int.random(in: DisplayGeometry.zoomRange, using: &rng))
            let g = DisplayGeometry.layout(bounds: bounds, scale: scale, mode: mode, aspect: aspect)
            let d = g.destination
            let s = Double(scale)
            let pw = Double(bounds.width) * s, ph = Double(bounds.height) * s
            let w = Double(d.width) * s, h = Double(d.height) * s
            #expect(d.minX >= 0 && d.minY >= 0 && Double(d.maxX) * s <= pw + 1e-6 && Double(d.maxY) * s <= ph + 1e-6 || w <= 1 || h <= 1)
            for v in [Double(d.minX) * s, Double(d.minY) * s, w, h] { #expect(abs(v - v.rounded()) < 1e-6) }
            if w >= 50 && h >= 50 {
                #expect(abs(w / h - DisplayGeometry.displayAspect(aspect)) < 2 / min(w, h) + 1e-9, "\(bounds) \(scale) \(mode)")
            }
            #expect(g.prescaleX >= 1 && g.prescaleY >= 1)
            #expect(g.prescaleX <= DisplayGeometry.maxPrescale && g.prescaleY <= DisplayGeometry.maxPrescale)
            if w >= Double(DisplayGeometry.sourceWidth) {
                #expect(Double(g.prescaleX * DisplayGeometry.sourceWidth) <= w + 1e-6)
                #expect(g.prescaleX == DisplayGeometry.maxPrescale
                        || Double((g.prescaleX + 1) * DisplayGeometry.sourceWidth) > w)
            }
            if h >= Double(DisplayGeometry.sourceHeight) {
                #expect(Double(g.prescaleY * DisplayGeometry.sourceHeight) <= h + 1e-6)
                #expect(g.prescaleY == DisplayGeometry.maxPrescale
                        || Double((g.prescaleY + 1) * DisplayGeometry.sourceHeight) > h)
            }
            if case .fixed(let z) = mode {
                let size = DisplayGeometry.contentSize(zoom: z, aspect: aspect)
                if Double(size.width) * s <= pw && Double(size.height) * s <= ph {
                    // A fixed zoom that fits is shown at exactly that size.
                    #expect(abs(w - Double(size.width) * s) <= 1 && abs(h - Double(size.height) * s) <= 1)
                }
            }
        }
    }

    @Test func zoomSizesGrowAndTheLargestFittingIsChosen() {
        for aspect in PixelAspect.allCases {
            var previous = CGSize.zero
            for z in DisplayGeometry.zoomRange {
                let size = DisplayGeometry.contentSize(zoom: z, aspect: aspect)
                #expect(size.width > previous.width && size.height > previous.height)
                previous = size
                // Exactly the zoom's own size fits that zoom and not the next one.
                #expect(DisplayGeometry.largestZoom(fitting: size, aspect: aspect) == z)
            }
        }
    }

    /// Indices above 15 use their low nibble (the presenter's frames are palette indices).
    @Test func converterMasksIndicesToTheLowNibble() {
        let src = (0..<256).map { UInt8($0) }
        let out = FrameConverter.convert(indices: src, width: 16, height: 16, palette: C64Palette.monochrome,
                                         scaleX: 1, scaleY: 1)
        for (i, v) in out.enumerated() { #expect(v == C64Palette.monochrome[i & 0x0F]) }
    }

    /// An image's pixel buffer goes back to the pool when CoreGraphics lets go of the image, and is
    /// handed out again; a buffer of another size is never reused for the wrong size.
    @Test func imageBuffersAreRecycled() throws {
        let pool = ImageBufferPool()
        var first: UnsafeMutablePointer<UInt32>?
        do {
            let b = pool.take(count: 64 * 32)
            first = b.pixels
            b.pixels.update(repeating: 0xFF12_3456, count: 64 * 32)
            let image = try #require(pool.makeImage(b, width: 64, height: 32))
            #expect(image.width == 64 && image.height == 32 && image.bitsPerPixel == 32)
        }
        let again = pool.take(count: 64 * 32)
        #expect(again.pixels == first, "the released buffer is reused")
        let other = pool.take(count: 16)
        #expect(other.count == 16 && other.pixels != again.pixels)
    }
}
