import C64Kit

/// How the native engine turns the machine into a picture (`VICPresenter` geometry, palette
/// indices).
///
/// - **The split** (the game's display): the raster IRQ $2285 latches the VIC state of its two
///   phases (`IO.viewRegion` at line $20, `IO.panelRegion` at line $A3). The window state
///   (multicolor, the bitmap `$22B0` named, the time-of-day border `$22B5`) covers raster lines
///   $20-$A3, the panel state (hi-res bitmap $4000, border $0C) all the others, so the borders
///   differ per region as on the C64. Line $A3 is a badline (`$D011` YSCROLL 3): the VIC takes 40
///   of its 65 cycles, so the panel phase's first store (the border, 28 cycles into the handler)
///   lands on line $A4 and line $A3 still shows the window's registers, as on the C64 and in the
///   lab. The window phase's stores are done within line $20 (no badline there). The four
///   attitude-indicator sprites come with the panel state.
/// - **A frame without raster IRQs** (a disk load, the editor cache transfer: the IRQ is held,
///   so the jiffy `$34` did not move since the last frame presented): the registers stay as the
///   last handler left them for the whole frame, so the frame shows that one state on every line,
///   the C64's look during loads.
/// - **One state for the whole frame** otherwise too: the editor's text screen ($0400, vector
///   $2304, `presentTextScreen` with the imported character ROM or the fallback font) and the
///   boot, before `displayInit` turns the split on.
/// - **The frame in which a pass flips** after line $20 (`HeldWindow`): the window phase latched
///   the bitmap the previous `$22B0` named, and the new pass already draws into that bitmap (the
///   horizon pass repaints it first) while the VIC shows it until the next line $20. The fill
///   paints whole rows at about 370 cycles a row, starting next to the horizon, while the beam
///   moves down a line every 65 cycles, so the C64 shows the old picture in most of the window.
///   A picture of memory at the frame end would show the window repainted and half redrawn
///   (scenery missing for one frame every pass), so the window rows are those kept at the last
///   frame end.
enum NativeEnginePresenter {
    /// The last raster line of the window region (the badline $A3 included).
    static let lastWindowLine = 0xA3

    /// The latched split when the game's raster IRQ is in charge (vector $2285, raster IRQs on,
    /// bitmap mode) and both phases have latched a bitmap state; nil otherwise.
    static func split(_ m: Machine) -> (view: VICState, panel: VICState)? {
        let io = m.io
        guard m.u16(TextMode.irqVector) == 0x2285, io.vic[0x1A] & 0x01 != 0, io.vic[0x11] & 0x20 != 0,
              io.viewRegion.cr1 & 0x20 != 0, io.panelRegion.cr1 & 0x20 != 0 else { return nil }
        return (io.viewRegion, io.panelRegion)
    }

    /// Renders the split from `ram`.
    static func render(into out: inout [UInt8], ram: UnsafeBufferPointer<UInt8>, colorRAM: [UInt8],
                       split: (view: VICState, panel: VICState)) {
        let (view, panel) = split
        VICPresenter.render(into: &out, ram: ram, colorRAM: colorRAM, charROM: nil) { raster in
            raster >= 0x20 && raster <= lastWindowLine ? view : panel
        }
    }

    /// The window rows of the bitmap on display at the last frame end, for the flip frame.
    final class HeldWindow {
        private var rows = [UInt8](repeating: 0, count: SmoothRenderer.windowBytes)
        /// The bitmap `rows` come from ($4000 or $6000); nil before the first frame end kept.
        private var base: Int?
        private var composite = [UInt8](repeating: 0, count: Machine.memorySize)

        /// The bitmap the window shows this frame (the latched `$D018`) is the one the program
        /// draws into (the row table `$0200`), while `$22B0` already names the other one: a pass
        /// flipped since this frame's line $20. (Before `$22B0` changes, the alternate-pass tasks
        /// draw into the bitmap on display on purpose: the ATIS teletype, the crash message.)
        func isFlipFrame(_ m: Machine, split: (view: VICState, panel: VICState)) -> Bool {
            let shown = SmoothRenderer.bitmapBase(memPtr: split.view.memPtr)
            let drawn = SmoothRenderer.drawBitmap(m.mem)
            return base == shown && shown == drawn && SmoothRenderer.flipBitmap(m.mem) != drawn
        }

        /// Memory with the kept window rows over the bitmap on display.
        func compose(_ m: Machine) -> [UInt8] {
            guard let base else { return m.memoryImage }
            composite.withUnsafeMutableBufferPointer { c in
                c.baseAddress!.update(from: m.mem, count: Machine.memorySize)
                rows.withUnsafeBufferPointer { (c.baseAddress! + base).update(from: $0.baseAddress!, count: $0.count) }
            }
            return composite
        }

        /// Forgets the kept rows (a frame without the split, or without raster IRQs).
        func forget() { base = nil }

        /// Keeps the window rows of the bitmap on display at this frame end.
        func keep(_ m: Machine, split: (view: VICState, panel: VICState)) {
            let shown = SmoothRenderer.bitmapBase(memPtr: split.view.memPtr)
            rows.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: m.mem + shown, count: $0.count) }
            base = shown
        }
    }
}
