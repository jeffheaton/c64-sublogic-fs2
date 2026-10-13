/// Literal ports of the original's integer math library ($16AA-$1A0A). These reproduce the
/// 6502 routines bit for bit — truncation, saturation and bias quirks included — because their
/// errors accumulate through the flight model and the 3D pipeline. `re/docs/math.md` documents
/// every routine (inputs, outputs, zero-page side effects, quirks and cycle formulas).
///
/// Conventions shared by every file in `Math/`:
/// - Each routine writes the same memory bytes as the original (zero-page temporaries included)
///   and returns the registers it leaves behind, as far as callers can observe them.
/// - Each routine charges the cycles of its own instructions, from its first instruction through
///   its return; the call into it (6 cycles) belongs to the caller. Internal calls are charged by
///   the routine that makes them. A tail jump is charged by the routine that jumps.
/// - The stack page is not modeled (pushes and pulls inside a routine leave no visible state).
/// - Flags are not returned unless a caller tests them; the doc comments name the exceptions.
extension Machine {
    /// $1881 (`asr16`): arithmetic shift right of the 16-bit value X:A (X = high byte).
    /// Returns the shifted value; Y receives the original low byte, carry the bit shifted out.
    /// 20 cycles (`asr16(a:x:)` on an instance charges them).
    @inline(__always)
    public static func asr16(a: UInt8, x: UInt8) -> (a: UInt8, x: UInt8, y: UInt8, carry: Bool) {
        let hi = x >> 1 | (x & 0x80)          // the sign bit is copied back into bit 7
        let lo = a >> 1 | (x & 1) << 7
        return (lo, hi, a, a & 1 != 0)
    }

    /// $19D5 (`negate16`): 16-bit two's-complement negate of X:A (X = high byte). Y receives the
    /// negated low byte. 23 cycles, 24 when the low byte is zero (`negate16(a:x:)` on an instance
    /// charges them).
    @inline(__always)
    public static func negate16(a: UInt8, x: UInt8) -> (a: UInt8, x: UInt8, y: UInt8) {
        let lo = (a ^ 0xFF) &+ 1
        let hi = (x ^ 0xFF) &+ (lo == 0 ? 1 : 0)
        return (lo, hi, lo)
    }

    /// $1881 with cycle accounting; see the static `asr16(a:x:)`.
    @inline(__always) @discardableResult
    public func asr16(a: UInt8, x: UInt8) -> (a: UInt8, x: UInt8, y: UInt8, carry: Bool) {
        charge(20)
        return Machine.asr16(a: a, x: x)
    }

    /// $19D5 with cycle accounting; see the static `negate16(a:x:)`.
    @inline(__always) @discardableResult
    public func negate16(a: UInt8, x: UInt8) -> (a: UInt8, x: UInt8, y: UInt8) {
        charge(a == 0 ? 24 : 23)
        return Machine.negate16(a: a, x: x)
    }

    // MARK: Helpers for the math ports

    /// The extra cycle an `abs,Y` / `(zp),Y` read costs when `base + index` crosses a page.
    @inline(__always)
    static func pageCrossing(_ base: Int, _ index: UInt8) -> Int {
        (base & 0xFF) + Int(index) > 0xFF ? 1 : 0
    }

    /// A little-endian word from a low and a high byte.
    @inline(__always)
    public static func word(_ lo: UInt8, _ hi: UInt8) -> UInt16 { UInt16(hi) << 8 | UInt16(lo) }
}
