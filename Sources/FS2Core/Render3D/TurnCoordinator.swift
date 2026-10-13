/// The turn coordinator ($A532-$A5A6): two XOR wing lines around (12, 176) on the panel, in
/// 2-pixel units, erased by redrawing the previous state.
extension Machine {
    /// $A4F2: 16 × (dx1, dy1, dx2, dy2) wing offsets.
    public static let tcWingTable = 0xA4F2
    /// $0A91: the wing state on the panel (rate index 0-15).
    public static let tcDrawnState = 0x0A91

    // MARK: drawTurnCoordinator ($A532 = $8012)

    /// $A532 (vector $8012): the rate index = (`$09FF:$09FE` << 1) high byte + 8, clamped to
    /// 0...15 (negative → 0, signed compare with $10 → 15), into `$AF`. When it differs from the
    /// drawn state `$0A91`, the old wings are XORed away and the new ones drawn
    /// (`turnCoordinatorHelper`). Clobbers A, X, Y.
    public func drawTurnCoordinator() {
        let m = mem
        var index = (m[0x09FF] << 1 | m[0x09FE] >> 7) &+ 8
        var c = 16               // the rate's high byte after one doubling, + 8
        if index & 0x80 != 0 {
            index = 0
            c += 5
        } else if index < 0x10 {
            c += 7
        } else {
            index = 0x0F
            c += 11
        }
        m[0xAF] = index
        let drawn = m[Self.tcDrawnState]
        c += 10                              // keep it, compare with the drawn state
        if drawn == index { charge(c + 8); return }
        charge(c + 9)
        drawTurnCoordinatorWings(drawn)
        charge(3)                                   // the new state
        turnCoordinatorHelper(m[0xAF])
    }

    // MARK: turnCoordinatorHelper ($A558 = $8015/$8027)

    /// $A558 (vectors $8015/$8027): records A as the drawn state `$0A91` and XORs its wings onto
    /// the panel. The cold start calls it to draw the initial wings. Clobbers A, X, Y.
    public func turnCoordinatorHelper(_ state: UInt8) {
        mem[Self.tcDrawnState] = state
        charge(10)
        drawTurnCoordinatorWings(state)
        charge(6)
    }

    /// $A55F: pen $83 (XOR), then the lines (12 + dx1, $B0 + dy1)-(12 − dx1, $B0 − dy1) and
    /// (12, $B0)-(12 + dx2, $B0 + dy2) of table entry A (index A·4, 8-bit).
    private func drawTurnCoordinatorWings(_ state: UInt8) {
        let m = mem
        charge(11)                           // save the state, the XOR pen
        setPen(0x83)
        let x = state << 2
        let t = Self.tcWingTable + Int(x)
        let cross0 = x >= 0x0E ? 1 : 0, cross1 = x >= 0x0D ? 1 : 0
        let cross2 = x >= 0x0C ? 1 : 0, cross3 = x >= 0x0B ? 1 : 0
        m[0xEB] = m[t] &+ 0x0C
        m[0xEC] = m[t + 1] &+ 0xB0
        m[0xED] = 0x0C &- m[t]
        m[0xEE] = 0xB0 &- m[t + 1]
        charge(13 + (4 + cross0) + 7 + (4 + cross1) + 7
               + 4 + (4 + cross0) + 7 + (4 + cross1) + 9)
        drawLine()
        m[0xEB] = 0x0C
        m[0xED] = 0x0C &+ m[t + 2]
        m[0xEC] = 0xB0
        m[0xEE] = 0xB0 &+ m[t + 3]
        charge(13 + (4 + cross2) + 10 + (4 + cross3) + 9)
        drawLine()
        charge(6)
    }
}
