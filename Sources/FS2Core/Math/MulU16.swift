/// The unsigned 16×16 → 32 multiply $188A.
extension Machine {
    /// $188A (`mulU16`): unsigned `$C4:$C5` × A:X (X high) → `$C8-$CB` (32-bit, little-endian).
    /// Returns A = `$C9` and X = `$CA`, bits 8-23 of the product. Y is unchanged. The N and Z
    /// flags reflect X (the caller at $3303 branches on N after a store).
    ///
    /// The original is a 16-step right-shift multiply. It is exact: the uninitialized `$C8:$C9`
    /// is shifted out completely, so the 32-bit product is m·n with no truncation. Side effects:
    /// `$C4:$C5` ends 0 (the multiplicand is shifted out), `$C6:$C7` = A:X. The final carry is
    /// bit 7 of the old `$C9` (not modeled; no caller uses it).
    ///
    /// Cycles: 635 + 16 per set bit of the multiplicand `$C4:$C5`.
    @inline(__always) @discardableResult
    public func mulU16(a lo: UInt8, x hi: UInt8) -> (a: UInt8, x: UInt8) {
        let m = UInt32(mem[0xC4]) | UInt32(mem[0xC5]) << 8
        let product = m * (UInt32(lo) | UInt32(hi) << 8)
        mem[0xC4] = 0; mem[0xC5] = 0
        mem[0xC6] = lo; mem[0xC7] = hi
        mem[0xC8] = UInt8(truncatingIfNeeded: product)
        mem[0xC9] = UInt8(truncatingIfNeeded: product >> 8)
        mem[0xCA] = UInt8(truncatingIfNeeded: product >> 16)
        mem[0xCB] = UInt8(truncatingIfNeeded: product >> 24)
        charge(635 + 16 * m.nonzeroBitCount)
        return (mem[0xC9], mem[0xCA])
    }
}
