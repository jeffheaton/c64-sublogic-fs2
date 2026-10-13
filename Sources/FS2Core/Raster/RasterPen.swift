/// The pen of the 2D raster primitives, as the original's self-modifying code defines it.
///
/// Every pixel write in the plot, line and span code reads the screen byte through the row pointer,
/// applies two patched logical ops (op1, op2) with mask tables indexed by the pixel index 0-3 in
/// the byte (pixel 0 = bits 7-6), and stores the byte back. The pen routines ($9BF5 `setPen`, $9B9B
/// `opDottedPen`, $9C9C `setSpanColor`) patch the opcodes (bit-set $1D, bit-clear $3D, exclusive-or
/// $5D, or a call, $20, for the dotted line) and the mask-table operands of those instructions. The
/// port writes exactly the same bytes and derives its explicit pen state (`SitePen`, and the fast
/// `PixelWriter`) from them, so a memory snapshot fully determines how the next line or span is
/// drawn — including the original's cold-start operands (a bit-clear through $1583 at the span
/// sites until the first span color).

/// The self-modified pixel-write sites. Each `rawValue` is the address of op1; op2 follows at
/// `rawValue + 3`.
public enum PixelSite: Int, CaseIterable, Sendable {
    /// $9A14: `plot` ($99FD), also the first pixel of every line.
    case plot = 0x9A14
    /// $9AB0: line loop $9A7C (y-major, rows decreasing).
    case lineYMajorUp = 0x9AB0
    /// $9AF1: line loop $9ABD (y-major, rows increasing).
    case lineYMajorDown = 0x9AF1
    /// $9B32: line loop $9AFE (x-major, rows decreasing).
    case lineXMajorUp = 0x9B32
    /// $9B73: line loop $9B3F (x-major, rows increasing).
    case lineXMajorDown = 0x9B73
    /// $99BC: short span pixel loop ($9996).
    case spanShort = 0x99BC
    /// $992A: long span, partial left byte ($9910).
    case spanLongLeft = 0x992A
    /// $9986: long span, partial right byte ($9910).
    case spanLongRight = 0x9986

    /// $9B8D: the single op of `dottedPlot` ($9B80), patched by `setPen` like a second op.
    public static let dottedOp = 0x9B8D
    /// $9B80: the call target the dotted-line patch plants as op2 of the four line loops.
    public static let dottedPlotEntry: UInt16 = 0x9B80
}

/// One patched logical op of a pixel write: bit-set, bit-clear or exclusive-or with a mask table
/// indexed by the pixel.
public struct PixelOp: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        case or = 0x1D
        case and = 0x3D
        case xor = 0x5D
    }

    public var kind: Kind
    /// The mask table (the absolute operand; indexed by the pixel index 0-3).
    public var table: UInt16

    public init(kind: Kind, table: UInt16) {
        self.kind = kind
        self.table = table
    }
}

/// The pen of one pixel-write site, decoded from the code bytes.
public struct SitePen: Equatable, Sendable {
    /// op1: pen bit 0 (a bit-set through $157A or a bit-clear through $1582; an exclusive-or for
    /// XOR pens).
    public var first: PixelOp
    /// op2: pen bit 1 (a bit-set through $157E or a bit-clear through $1586, or an exclusive-or).
    /// In dotted mode this is the op of `dottedPlot` at $9B8D, applied only on every fourth step.
    public var second: PixelOp
    /// True when op2 is the dotted-line patch, a call of $9B80 (display-list op $1C).
    public var dotted: Bool

    public init(first: PixelOp, second: PixelOp, dotted: Bool) {
        self.first = first
        self.second = second
        self.dotted = dotted
    }
}

extension Machine {
    /// The effective address of `(zp),Y` for the pointer `hi:lo`, wrapping at 64 KB like the 6502.
    @inline(__always)
    static func indirectY(_ lo: UInt8, _ hi: UInt8, _ y: UInt8) -> Int {
        ((Int(hi) << 8 | Int(lo)) + Int(y)) & 0xFFFF
    }

    /// Decodes one ALU op of a pixel write at `address` (opcode, then the absolute operand).
    @inline(__always)
    func pixelOp(at address: Int) -> PixelOp {
        let table = u16(address + 1)
        if let kind = PixelOp.Kind(rawValue: self[address]) { return PixelOp(kind: kind, table: table) }
        assertionFailure("unexpected pixel-write opcode $\(String(self[address], radix: 16)) at $\(String(address, radix: 16))")
        return PixelOp(kind: .and, table: 0x158D)   // fill pattern $FF: leaves the byte unchanged
    }

    /// The pen a pixel-write site currently draws with, as the patched code bytes define it.
    public func sitePen(_ site: PixelSite) -> SitePen {
        let a = site.rawValue
        let first = pixelOp(at: a)
        if self[a + 3] == 0x20 {   // a call of dottedPlot
            assert(u16(a + 4) == PixelSite.dottedPlotEntry, "dotted patch with an unexpected JSR target")
            return SitePen(first: first, second: pixelOp(at: PixelSite.dottedOp), dotted: true)
        }
        return SitePen(first: first, second: pixelOp(at: a + 3), dotted: false)
    }

    /// The fast form of `sitePen(site)`, with the mask tables read from memory.
    @inline(__always)
    func pixelWriter(_ site: PixelSite) -> PixelWriter {
        PixelWriter(sitePen(site), mem)
    }
}

/// A site's pen compiled into per-pixel affine byte maps: drawing pixel `px` of byte `b` stores
/// `(b & keep[px]) ^ flip[px]`. Any chain of bit-set, bit-clear and exclusive-or ops with constants
/// has this form. Lanes are packed little-endian into `UInt32` (byte `px` = pixel `px`), so a write
/// costs two shifts.
@usableFromInline
struct PixelWriter {
    /// op1 followed by op2 (or by the $9B8D op in dotted mode).
    var keep: UInt32 = 0
    var flip: UInt32 = 0
    /// op1 only: the value `dottedPlot` saves in $AF.
    var keep1: UInt32 = 0
    var flip1: UInt32 = 0
    /// Cycles of the two ops per lane (4 each, +1 when `table + px` crosses a page).
    var cost: UInt32 = 0
    /// Cycles of op1 per lane.
    var cost1: UInt32 = 0
    var dotted = false

    init(_ pen: SitePen, _ mem: UnsafeMutablePointer<UInt8>) {
        dotted = pen.dotted
        for px in 0..<4 {
            let shift = UInt32(px * 8)
            var k: UInt8 = 0xFF, f: UInt8 = 0
            let c1 = Self.apply(pen.first, px, mem, &k, &f)
            keep1 |= UInt32(k) << shift
            flip1 |= UInt32(f) << shift
            cost1 |= UInt32(c1) << shift
            let c2 = Self.apply(pen.second, px, mem, &k, &f)
            keep |= UInt32(k) << shift
            flip |= UInt32(f) << shift
            cost |= UInt32(c1 + c2) << shift
        }
    }

    /// Composes `op` (with mask `table[px]`) onto the affine map (keep, flip); returns its cycles.
    @inline(__always)
    static func apply(_ op: PixelOp, _ px: Int, _ mem: UnsafeMutablePointer<UInt8>,
                      _ keep: inout UInt8, _ flip: inout UInt8) -> Int {
        let addr = (Int(op.table) + px) & 0xFFFF
        let m = mem[addr]
        switch op.kind {
        case .or:  keep &= ~m; flip = (flip & ~m) ^ m
        case .and: keep &= m; flip &= m
        case .xor: flip ^= m
        }
        return (Int(op.table) & 0xFF) + px > 0xFF ? 5 : 4
    }

    @inline(__always)
    static func lane(_ v: UInt32, _ px: UInt8) -> UInt8 {
        UInt8(truncatingIfNeeded: v >> (UInt32(px & 3) << 3))
    }

    /// One pixel write (the byte read, op1, op2, the byte stored back) at `addr` for pixel `px`.
    /// `crossed` is the page-cross penalty of the indexed read. In dotted mode (op2 is a call of
    /// $9B80) the pixel is drawn only when `count & 3 == 0` (`count` = $F3), the op1 result goes to
    /// `af` ($AF), and an undrawn pixel's byte is stored back unchanged. Returns the cycles.
    @inline(__always)
    func write(_ mem: UnsafeMutablePointer<UInt8>, _ addr: Int, _ px: UInt8, crossed: Bool,
               count: UInt8, af: inout UInt8) -> Int {
        let c = crossed ? 1 : 0
        let b = mem[addr]
        if !dotted {
            mem[addr] = (b & Self.lane(keep, px)) ^ Self.lane(flip, px)
            return 11 + c + Int(Self.lane(cost, px))
        }
        // $9B80 keeps the op1 result in `$AF`; on every fourth step (`$F3 & 3 == 0`) it applies its
        // op to that result, otherwise it rereads the unchanged screen byte, so the store writes it
        // back as it was.
        af = (b & Self.lane(keep1, px)) ^ Self.lane(flip1, px)
        if count & 3 == 0 {
            mem[addr] = (b & Self.lane(keep, px)) ^ Self.lane(flip, px)
            return 37 + c + Int(Self.lane(cost, px))
        }
        return 38 + 2 * c + Int(Self.lane(cost1, px))
    }
}
