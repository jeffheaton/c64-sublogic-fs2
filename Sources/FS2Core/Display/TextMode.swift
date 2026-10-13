import C64Kit

/// The text screen the editor uses: the display swap $2673 (vector $203F), the VIC text setup
/// $796C (reached through the loader hook $732E), the color RAM fill $794E (hook $7331) and the
/// graphics restore $5F40.
///
/// The text screen is screen RAM $0400 in VIC bank 0 with the character generator ROM's
/// upper/lowercase set (`$D018` = $16), white background, orange border (color 8), dark gray
/// characters (color RAM $0B). While it is up the raster IRQ vector points at the tick-only
/// handler $2304 (no screen split). `displayInit` ($25EB, vector $2042) switches back to the
/// game's bitmap display; it belongs to the display unit.
///
/// Hardware stores go through `io`: `io.writeVIC`, `io.cia2PortA` ($DD00) and `io.colorRAM`
/// ($D800-$DBE7, low nibbles as the VIC keeps them).
public enum TextMode {
    /// $0E89: the shadow of $DD00 ($96 bitmap bank 1, $97 text bank 0).
    public static let dd00Shadow = 0x0E89
    /// $0E69: the game's background color ($D021): $0B color, $00 black and white.
    public static let backgroundColor = 0x0E69
    /// $FFFE/$FFFF: the IRQ vector ($2285 the game's two-phase raster IRQ, $2304 the tick-only
    /// IRQ of the text screen and disk I/O).
    public static let irqVector = 0xFFFE
    /// $2304: the tick-only IRQ handler installed by `textModeIrqSwap`.
    public static let tickOnlyIrq: UInt16 = 0x2304
    /// The text screen at $0400 (40 x 25 screen codes).
    public static let screen = 0x0400
    public static let columns = 40
    public static let rows = 25

    /// Cycles of `fillColorRam` ($794E) from its first instruction through its return: the 21-cycle
    /// header, four passes of the 14-cycle store-and-count-down loop (231 stores in the first pass,
    /// from $DBE7 down to $DB01, then 255 per page), each pass closed by a store at offset 0 and
    /// the page step (21 cycles, 20 for the last page, whose loop branch falls through), and the
    /// return.
    public static let fillColorRamCycles = 21 + (231 * 14 - 1 + 21) + 2 * (255 * 14 - 1 + 21) + (255 * 14 - 1 + 20) + 6

    /// The screen code under (column, row) of the text screen, from memory.
    public static func screenCode(_ m: Machine, column: Int, row: Int) -> UInt8 {
        m[screen + row * columns + column]
    }
}

extension Machine {
    /// $2673 (vector $203F): with interrupts masked, the text screen (through the loader hook $732E
    /// on to $796C, `setTextMode`), `$0E89` = $97, the IRQ vector = $2304 (tick only); then
    /// interrupts unmasked. In the port the vector bytes tell the scheduler that the raster split
    /// is off. Clobbers A, X, Y.
    ///
    /// The IRQ is masked for the whole swap (about 21,000 cycles): a raster event inside it only
    /// latches, and the one IRQ held is taken after the unmasking, through the tick-only vector the
    /// swap has just stored, so the game's split IRQ $2285 never rewrites `$D016` and `$D018` over
    /// the text screen `setTextMode` set up.
    public func textModeIrqSwap() {
        let m = mem
        sei()
        charge(11)                             // interrupts masked, through the hook $732E to $796C
        setTextMode()
        m[TextMode.dd00Shadow] = 0x97                       // $2677
        m[TextMode.irqVector] = 0x04
        m[TextMode.irqVector + 1] = 0x23
        charge(18)                       // the shadow and the IRQ vector
        cli()
        charge(8)                                       // interrupts unmasked, the return
    }

    /// $796C (via the loader hook $732E): border 8, `$D018` = $16 (screen $0400, the ROM's
    /// upper/lowercase set), `$DD00` = $97 (VIC bank 0), `$D011` = $1B (text, 25 rows),
    /// `$D016` = $08 (40 columns, no multicolor), `$D021` = 1 (white), sprites off, color RAM
    /// $0B (`fillColorRam`), then $0400-$07FF filled with spaces ($20). Leaves A = $20, X = 0,
    /// and `$39/$3A` as `fillColorRam` leaves them.
    public func setTextMode() {
        io.writeVIC(0x20, 0x08)
        io.writeVIC(0x18, 0x16)
        io.cia2PortA = 0x97
        io.writeVIC(0x11, 0x1B)
        io.writeVIC(0x16, 0x08)
        io.writeVIC(0x21, 0x01)
        io.writeVIC(0x15, 0x00)
        // Seven register stores, then dark gray through `fillColorRam`.
        charge(7 * 6 + 8)
        fillColorRam(0x0B)
        let m = mem
        for a in 0x0400..<0x0800 { m[a] = 0x20 }
        // 256 passes storing a space into each of the four pages (25 cycles each, the last loop
        // test falling through), then the return.
        charge(2 + 2 + 256 * (4 * 5 + 2 + 3) - 1 + 6)
    }

    // $794E `fillColorRam` is shared with the display init (Display/InitDisplay.swift).

    /// $5F40 (the disk-error prompt's exit): when `$0E89` != $97 (the bitmap display is set up),
    /// `$D021` = `$0E69`, `$DD00` = $96 (bank 1), `$D011` = $3B (bitmap) and color RAM white
    /// (`fillColorRam(1)`); otherwise nothing (9 cycles and the return).
    public func restoreGraphics() {
        let m = mem
        guard m[TextMode.dd00Shadow] != 0x97 else {
            charge(15)                           // text mode: the test, the return
            return
        }
        io.writeVIC(0x21, m[TextMode.backgroundColor])
        io.cia2PortA = 0x96
        io.writeVIC(0x11, 0x3B)
        charge(36)   // the test, the three stores, white, the call
        fillColorRam(0x01)
        charge(6)
    }

    /// Renders the screen the VIC shows from the current register state (one state for the
    /// whole frame: the text screen has no raster split) into `out`, `VICPresenter.width` x
    /// `VICPresenter.height` palette indices. `charROM` is the imported character generator
    /// (`GameData.charROM`); without one the presenter draws the fallback character set.
    public func presentTextScreen(into out: inout [UInt8], charROM: [UInt8]?) {
        let state = io.vicState()
        let colors = io.colorRAM
        VICPresenter.render(into: &out, ram: UnsafeBufferPointer(start: mem, count: Machine.memorySize),
                            colorRAM: colors, charROM: charROM) { _ in state }
    }
}
