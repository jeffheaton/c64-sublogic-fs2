/// The display setup $25EB-$2672 (vector $2042; the cold init calls it from $AB0B, the editor on
/// exit) and the color RAM fill $794E it reaches through the loader hook $7331.
extension Machine {
    /// $25EB `displayInit`: with interrupts masked: bitmap mode (`$D011` = $3B); CIA2 port A bank 1
    /// ($4000, `$DD02` = $3F, `$DD00` = $96 and its shadow `$0E89`); sprites 0-3 on and multicolor
    /// (multicolors $0B/$01, colors $0B) at ($58,$AA) ($68,$AA) ($58,$B5) ($68,$B5) with pointers
    /// $E8-$EB at $7FF8 (the attitude-indicator bezel); `$D021` = `$0E69`; the IRQ vector
    /// `$FFFE/$FFFF` = $2285 (a memory write); the first raster IRQ at line $97; raster IRQs on
    /// (`$D01A` = 1), latch acknowledged; interrupts unmasked; then the color RAM all white
    /// (through the loader hook $7331, which goes on to $794E). Each charge lands the register
    /// write after it on its cycle. Charges from $25EB through its return.
    public func displayInit() {
        let m = mem
        sei()
        charge(4)                                       // interrupts masked
        io.writeVIC(0x11, 0x3B)
        charge(6)
        io.writeCIA2(0x02, 0x3F)
        charge(6)
        io.writeCIA2(0x00, 0x96)
        m[0x0E89] = 0x96
        charge(10)                                   // the bank and its shadow
        io.writeVIC(0x15, 0x0F)
        io.writeVIC(0x1C, 0x0F)
        charge(10)                                   // sprites on, multicolor
        io.writeVIC(0x26, 0x01)
        charge(6)                                       // the second sprite multicolor
        for reg in [0x25, 0x27, 0x28, 0x29, 0x2A] { io.writeVIC(reg, 0x0B) }
        charge(5 * 4 + 2)                                   // the five sprite colors
        io.writeVIC(0x00, 0x58); io.writeVIC(0x04, 0x58)
        charge(10)                                   // the sprite positions
        io.writeVIC(0x01, 0xAA); io.writeVIC(0x03, 0xAA)
        charge(10)
        io.writeVIC(0x02, 0x68); io.writeVIC(0x06, 0x68)
        charge(10)
        io.writeVIC(0x05, 0xB5); io.writeVIC(0x07, 0xB5)
        charge(8)
        // The four sprite pointers $E8-$EB (the attitude-indicator bezel).
        for k in 0..<4 { m[0x7FF8 + k] = 0xE8 + UInt8(k) }
        charge(2 + 4 + 3 * 6)
        // The background color from `$0E69`.
        io.writeVIC(0x21, m[0x0E69])
        charge(8)
        // The IRQ vector: the raster IRQ $2285.
        m[0xFFFE] = 0x85
        m[0xFFFF] = 0x22
        charge(12)
        // The first raster IRQ at line $97, raster IRQs on, the latch acknowledged, interrupts
        // unmasked.
        io.writeVIC(0x12, 0x97)
        io.writeVIC(0x1A, 0x01)
        io.acknowledgeVIC(0x0F)
        charge(20)
        cli()
        // White, through the loader's hook $7331 on to $794E.
        charge(11)
        fillColorRam(0x01)
        charge(6)                                           // the return
    }

    /// $794E `fillColorRam`: color RAM $D800-$DBE7 = A, stored downward one byte at a time through
    /// the pointer `$39/$3A` from $DBE7 (the index stays 0 while the pointer counts down, four
    /// pages). Leaves `$39/$3A` = $D7FF. Charges from $794E through its return (14,050 cycles).
    public func fillColorRam(_ color: UInt8) {
        let m = mem
        // The setup: the pointer at $DBE7, the index 0, four pages to go.
        var c = 21
        var pointer = 0xDBE7
        for page in 0..<4 {
            // Down to the byte at offset 0 of the page, 14 cycles per byte.
            let first = pointer & 0xFF
            for a in stride(from: pointer, to: pointer - first, by: -1) { io.writeColorRAM(a - 0xD800, color) }
            c += first * 14 - 1
            // The store at offset 0, then the pointer steps to the page below.
            io.writeColorRAM((pointer & 0xFF00) - 0xD800, color)
            pointer = (pointer & 0xFF00) - 1
            c += 18 + (page < 3 ? 3 : 2)
        }
        m[0x39] = UInt8(pointer & 0xFF)
        m[0x3A] = UInt8(pointer >> 8)
        charge(c + 6)                                       // the return
    }
}
