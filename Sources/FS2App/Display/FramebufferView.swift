import AppKit
import C64Kit
import QuartzCore

/// Receives the keyboard events the framebuffer view gets as first responder.
@MainActor
protocol FramebufferKeyHandler: AnyObject {
    /// Returns true when the event was used (the view then does not pass it on).
    func framebufferKeyDown(_ event: NSEvent) -> Bool
    func framebufferKeyUp(_ event: NSEvent) -> Bool
    func framebufferFlagsChanged(_ event: NSEvent) -> Bool
}

/// Shows the engine's frames: at every display refresh it takes the newest frame, converts the
/// palette indices to BGRA prescaled by integers (nearest neighbor) and hands the image to a
/// `CALayer` that magnifies the remaining fraction linearly ("sharp bilinear"). The area outside
/// the frame is black. CoreAnimation only composites; no GPU API draws game content.
@MainActor
final class FramebufferView: NSView {
    var frames: FrameExchange?
    weak var keyHandler: FramebufferKeyHandler?
    /// Called at each display refresh before the frame is updated (gamepad polling).
    var onRefresh: (() -> Void)?

    var aspect: PixelAspect = .ntsc {
        didSet { if aspect != oldValue { updateGeometry() } }
    }
    var zoomMode: ZoomMode = .fixed(2) {
        didSet { if zoomMode != oldValue { updateGeometry() } }
    }
    /// Show every frame on a black-and-white monitor (otherwise only frames flagged monochrome).
    var forceMonochrome = false {
        didSet { if forceMonochrome != oldValue { needsConversion = true } }
    }

    private let imageLayer = CALayer()
    private var link: CADisplayLink?
    private let pool = ImageBufferPool()
    /// The frame on screen (the exchange's front slot; ours until the next take).
    private var current: FrameExchange.Slot?
    private var lastPixels: [UInt8] = []
    private var lastPalette: [UInt32] = []
    private var imageSize: (Int, Int) = (0, 0)
    private var geometry: DisplayGeometry.Layout?
    private var needsConversion = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        // A layer-hosting view: AppKit never draws into it, the image layer is all there is.
        let root = CALayer()
        root.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer = root
        wantsLayer = true
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .linear
        imageLayer.contentsGravity = .resize
        imageLayer.isOpaque = true
        imageLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        root.addSublayer(imageLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    // MARK: Display refresh

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateGeometry()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let l = displayLink(target: self, selector: #selector(refresh(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func refresh(_ sender: CADisplayLink) {
        onRefresh?()
        if let slot = frames?.takeLatest() {
            current = slot
            needsConversion = true
        }
        if needsConversion { present() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGeometry()
    }

    override func layout() {
        super.layout()
        updateGeometry()
    }

    /// Places the image layer for the current size, zoom, aspect and backing scale.
    private func updateGeometry() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let g = DisplayGeometry.layout(bounds: bounds.size, scale: scale, mode: zoomMode, aspect: aspect)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = g.destination
        imageLayer.contentsScale = scale
        CATransaction.commit()
        if g.prescaleX != geometry?.prescaleX || g.prescaleY != geometry?.prescaleY { needsConversion = true }
        geometry = g
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateGeometry()
    }

    /// Converts the current frame (if it or the presentation changed) and sets it as layer contents.
    private func present() {
        needsConversion = false
        guard let slot = current, let g = geometry,
              slot.pixels.count == DisplayGeometry.sourceWidth * DisplayGeometry.sourceHeight else { return }
        let palette = slot.monochrome || forceMonochrome ? C64Palette.monochrome : C64Palette.color
        let (w, h) = g.prescaledSize
        // Skip identical frames (the original redraws far less often than the VIC refreshes).
        if slot.pixels == lastPixels, palette == lastPalette, imageSize == (w, h) { return }
        let buffer = pool.take(count: w * h)
        slot.pixels.withUnsafeBufferPointer { src in
            FrameConverter.convert(indices: src, width: DisplayGeometry.sourceWidth,
                                   height: DisplayGeometry.sourceHeight, palette: palette,
                                   scaleX: g.prescaleX, scaleY: g.prescaleY, into: buffer.pixels)
        }
        guard let image = pool.makeImage(buffer, width: w, height: h) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
        lastPixels = slot.pixels
        lastPalette = palette
        imageSize = (w, h)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if keyHandler?.framebufferKeyDown(event) != true { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if keyHandler?.framebufferKeyUp(event) != true { super.keyUp(with: event) }
    }

    override func flagsChanged(with event: NSEvent) {
        if keyHandler?.framebufferFlagsChanged(event) != true { super.flagsChanged(with: event) }
    }
}
