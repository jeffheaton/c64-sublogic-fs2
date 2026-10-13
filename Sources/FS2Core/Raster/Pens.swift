/// Pen and span-color routines ($9B91-$9D04). They self-modify the pixel writes of the plot, line
/// and span code; the port writes the same bytes (see `RasterPen.swift` for how the drawing
/// routines read them back).
extension Machine {
    /// $9BD6: scenery color code 0-15 -> 2-bit pen (op $12 and the polygon fill color).
    public static let colorMap = 0x9BD6
    /// $158A: fill byte per pen (00/55/AA/FF).
    public static let fillPatterns = 0x158A
    /// $0F00/$0F01: the pen-bit masks (1 and 2) that `setPen` and `setSpanColor` test the pen
    /// against.
    public static let penBitMasks = 0x0F00

    // MARK: setPen ($9BF5 = $800F)

    /// $9BF5 (vector $800F): selects the line/plot pen. A = pen 0-3, bit 7 = XOR.
    ///
    /// op1 of every line/plot pixel write becomes a bit-set through the mask table $157A when
    /// `A & [$0F00]` is set, else a bit-clear through $1582; op2 likewise uses $157E or $1586 by
    /// `A & [$0F01]`. With bit 7 set both opcodes become exclusive-ors with the same operand
    /// choice, so the pixel is XORed with mask1 ^ mask2: pens $80 and $83 both XOR it with 11,
    /// $81/$82 flip the other three pixels. The dotted plot's op ($9B8D) is patched like an op2,
    /// and the line loops' op2 is rewritten, which cancels a dotted patch. Clobbers A, X, Y.
    public func setPen(_ pen: UInt8) {
        charge(setPenBody(pen))
    }

    @usableFromInline
    func setPenBody(_ a: UInt8) -> Int {
        let m = mem
        let bit0 = a & m[Self.penBitMasks] != 0
        let bit1 = a & m[Self.penBitMasks + 1] != 0
        let xor = a & 0x80 != 0
        // The op1 opcode (bit 7 picks the exclusive-or).
        var cycles = 2
        let op1: UInt8
        if xor {
            op1 = 0x5D
            cycles += 8                     // an XOR pen (its branch crosses a page)
        } else {
            cycles += 9                     // pen bit 0 tested
            if bit0 { op1 = 0x1D; cycles += 3 } else { op1 = 0x3D; cycles += 4 }
        }
        m[0x9A14] = op1; m[0x9AB0] = op1; m[0x9AF1] = op1; m[0x9B32] = op1; m[0x9B73] = op1
        cycles += 5 * 4
        // The op1 operand.
        cycles += 8                         // the operand by pen bit 0
        let lo1: UInt8, hi1: UInt8 = 0x15
        if bit0 { lo1 = 0x7A; cycles += 3 } else { lo1 = 0x82; cycles += 6 }
        m[0x9A15] = lo1; m[0x9A16] = hi1
        m[0x9AB1] = lo1; m[0x9AB2] = hi1
        m[0x9AF2] = lo1; m[0x9AF3] = hi1
        m[0x9B33] = lo1; m[0x9B34] = hi1
        m[0x9B74] = lo1; m[0x9B75] = hi1
        cycles += 10 * 4
        // The op2 opcode.
        cycles += 2
        let op2: UInt8
        if xor {
            op2 = 0x5D
            cycles += 7                     // an XOR pen
        } else {
            cycles += 9                     // pen bit 1 tested
            if bit1 { op2 = 0x1D; cycles += 3 } else { op2 = 0x3D; cycles += 4 }
        }
        m[0x9A17] = op2; m[0x9AB3] = op2; m[0x9AF4] = op2; m[0x9B35] = op2; m[0x9B76] = op2
        m[0x9B8D] = op2
        cycles += 6 * 4
        // The op2 operand.
        cycles += 8                         // the operand by pen bit 1
        let lo2: UInt8, hi2: UInt8 = 0x15
        if bit1 { lo2 = 0x7E; cycles += 3 } else { lo2 = 0x86; cycles += 6 }
        m[0x9A18] = lo2; m[0x9A19] = hi2
        m[0x9AB4] = lo2; m[0x9AB5] = hi2
        m[0x9AF5] = lo2; m[0x9AF6] = hi2
        m[0x9B36] = lo2; m[0x9B37] = hi2
        m[0x9B77] = lo2; m[0x9B78] = hi2
        m[0x9B8E] = lo2; m[0x9B8F] = hi2
        cycles += 12 * 4
        return cycles + 6                           // the return
    }

    // MARK: Display-list pen ops

    // The three ops below end by loading their length and jumping to $8749 (dlAdvance). The port
    // returns `len` for the interpreter to advance by, and charges the cycles up to and including
    // that jump.

    /// $9B91: display-list op $1B — pen 3. Returns the op length (1).
    public func opPen3() -> UInt8 {
        charge(8 + setPenBody(3) + 5)       // pen 3, the call, the length, the jump
        return 1
    }

    /// $9B9B: display-list op $1C — dotted lines. Only when `$083C` bit 0 is clear (dusk or night):
    /// pen 1, then op2 of the four line loops becomes a call of $9B80 (`dottedPlot`), which draws a
    /// pixel only when the steps remaining ($F3) are a multiple of 4. The plot site ($9A14) and so
    /// the first pixel of a line are not patched. Any later `setPen` cancels it. Returns the op
    /// length (1).
    public func opDottedPen() -> UInt8 {
        let m = mem
        var cycles = 6                          // the day bit of `$083C`
        if m[0x083C] & 1 != 0 {
            cycles += 3                             // by day: no change
        } else {
            cycles += 10 + setPenBody(1)     // dusk or night: pen 1 through `setPen`
            m[0x9AB3] = 0x20; m[0x9AF4] = 0x20; m[0x9B35] = 0x20; m[0x9B76] = 0x20
            m[0x9AB4] = 0x80; m[0x9AF5] = 0x80; m[0x9B36] = 0x80; m[0x9B77] = 0x80
            m[0x9AB5] = 0x9B; m[0x9AF6] = 0x9B; m[0x9B37] = 0x9B; m[0x9B78] = 0x9B
            cycles += 3 * (2 + 4 * 4)
        }
        charge(cycles + 5)                      // the length, the jump
        return 1
    }

    /// $9BE6: display-list op $12 n — pen = $9BD6[n], n being the byte after the opcode at the
    /// display-list PC ($8B). Entered with Y = 0 like every handler. Returns the op length (2).
    public func opPen() -> UInt8 {
        let pc = zpPointer(0x8B)
        let crossed = pc & 0xFF == 0xFF ? 1 : 0     // the operand byte's read across a page
        let n = self[pc + 1]
        let pen = self[Self.colorMap + Int(n)]
        let indexCross = n >= 0x2A ? 1 : 0          // the color map read across a page
        charge(7 + crossed + 6 + indexCross + 6 + setPenBody(pen) + 5)
        return 2
    }

    // MARK: Span colors ($9C93 = $801E, $9C9C = $8024)

    /// $9C93 (vector $801E): span color from the scenery color `$0876 & 15` through $9BD6.
    /// Clobbers A, X, Y.
    public func setSpanColorFromPalette() {
        let pen = self[Self.colorMap + Int(self[0x0876] & 0x0F)]
        charge(12 + setSpanColorBody(pen))
    }

    /// $9C9C (vector $8024): span color X. `$1A = $158A[X]` (the whole-byte pattern); the
    /// partial-byte writes of both span routines get the bit-set table $157A or the bit-clear table
    /// $1582 by `X & [$0F00]`, and $157E or $1586 by `X & [$0F01]` (never an exclusive-or).
    /// Clobbers A, X, Y.
    public func setSpanColor(_ pen: UInt8) {
        charge(setSpanColorBody(pen))
    }

    @usableFromInline
    func setSpanColorBody(_ x: UInt8) -> Int {
        let m = mem
        m[0x1A] = m[Self.fillPatterns + Int(x)]
        var cycles = 4 + (x >= 0x76 ? 1 : 0) + 5     // the whole-byte pattern
        let bit0 = x & m[Self.penBitMasks] != 0
        let bit1 = x & m[Self.penBitMasks + 1] != 0
        // op1 opcode.
        cycles += 6                                  // pen bit 0 tested
        let op1: UInt8
        if bit0 { op1 = 0x1D; cycles += 3 } else { op1 = 0x3D; cycles += 4 }
        m[0x99BC] = op1; m[0x992A] = op1; m[0x9986] = op1
        cycles += 3 * 4
        // op1 operand.
        cycles += 8
        let lo1: UInt8, hi1: UInt8 = 0x15
        if bit0 { lo1 = 0x7A; cycles += 3 } else { lo1 = 0x82; cycles += 6 }
        m[0x99BD] = lo1; m[0x99BE] = hi1
        m[0x992B] = lo1; m[0x992C] = hi1
        m[0x9987] = lo1; m[0x9988] = hi1
        cycles += 6 * 4
        // op2 opcode.
        cycles += 6
        let op2: UInt8
        if bit1 { op2 = 0x1D; cycles += 3 } else { op2 = 0x3D; cycles += 4 }
        m[0x99BF] = op2; m[0x992D] = op2; m[0x9989] = op2
        cycles += 3 * 4
        // op2 operand.
        cycles += 8
        let lo2: UInt8, hi2: UInt8 = 0x15
        if bit1 { lo2 = 0x7E; cycles += 3 } else { lo2 = 0x86; cycles += 6 }
        m[0x99C0] = lo2; m[0x99C1] = hi2
        m[0x992E] = lo2; m[0x992F] = hi2
        m[0x998A] = lo2; m[0x998B] = hi2
        cycles += 6 * 4
        return cycles + 6                                // the return
    }
}
