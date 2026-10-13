import C64Kit

/// Display-list geometry: 3D and ground points (ops 00/01/02/40/41), the vertex cache (ops
/// 31/42/32/33/35), polygons (2F/29), the line driver $8B40, the 2D screen line (06) and the
/// dashed ground line (2B).
///
/// Points: point A (`$CC` outcode, `$CD-$D2` x/y/z, `$D3/$D4` screen) is the current point and
/// the moveto target; point B (`$D5`, `$D6-$DB`, `$DC/$DD`) is the lineto target. `$08-$10` keep
/// a copy of the last moveto (the start for op 29 outside a polygon). While a polygon is open
/// (`$23` = $FF), points are appended to the vertex arrays at $0B10 instead (`$B7` = count) and
/// `$D5` collects their z high bytes and-ed together (all negative: the polygon is behind the
/// eye).
extension Machine {
    // MARK: Point transforms ($88A1, $8860)

    /// Runs the transform selected by the self-modified call operand at `operand` (`$A1CE`
    /// 3D or `$9FD0` ground) into zero page `dest`. The caller charges the call.
    @inline(__always)
    private func dlTransform(operand: Int, dest: UInt8) {
        switch u16(operand) {
        case Scenery.transform3DEntry: transform3D(y: dest)
        case Scenery.transformGroundEntry: transformGround(y: dest)
        default:
            preconditionFailure("point transform operand $\(hex(u16(operand), width: 4)) at $\(hex(operand, width: 4))")
        }
    }

    /// Stores point `src` (6 bytes) as polygon vertex `index` (indexed stores into the six
    /// 64-byte arrays; the 8-bit index is not bounded).
    @inline(__always)
    private func dlStoreVertex(_ src: Int, _ index: UInt8) {
        let m = mem
        let i = Int(index)
        for k in 0..<6 { m[Self.polygonArrays + 0x40 * k + i] = m[src + k] }
    }

    /// $88A1: point A from the display list (transform at $88A4 into `$CD`). In a polygon it is
    /// appended (no 60-vertex check) and `$D5` = its z high byte; otherwise its outcode is
    /// computed, it is projected when visible, and A (`$CC-$D4`) is copied to `$08-$10`.
    func dlPointA() {
        let m = mem
        charge(8)                                       // the destination, the transform call
        dlTransform(operand: Scenery.pointATransformOperand, dest: 0xCD)
        if m[Scenery.polygonOpen] != 0 {
            let y = m[Scenery.polygonCount]
            m[Scenery.polygonCount] = y &+ 1
            dlStoreVertex(0xCD, y)
            m[0xD5] = m[0xD2]
            // The polygon test, the vertex appended, `$D5` set, and the return.
            charge(73)
            return
        }
        charge(12)                                   // no polygon: the outcode ($93D2)
        dlPointAVisible()
    }

    /// $88D1: outcode of A; projected when visible; A copied to `$08-$10`.
    func dlPointAVisible() {
        let m = mem
        computeOutcodeA()
        if m[0xCC] != 0 {
            charge(6)                                   // not visible
        } else {
            charge(11)
            projectPointA()
        }
        for k in 0..<9 { m[0x08 + k] = m[0xCC + k] }
        charge(124)                                 // the copy loop and the return
    }

    /// $8860: point B from the display list (transform at $8863 into `$D6`). In a polygon it is
    /// appended unless 60 vertices are already there, and `$D5` &= its z high byte; otherwise its
    /// outcode is computed and it is projected when visible.
    func dlPointB() {
        let m = mem
        charge(8)                                       // the destination, the transform call
        dlTransform(operand: Scenery.pointBTransformOperand, dest: 0xD6)
        if m[Scenery.polygonOpen] != 0 {
            let y = m[Scenery.polygonCount]
            if y >= 0x3C {
                charge(19)               // the polygon is full: return
                return
            }
            m[Scenery.polygonCount] = y &+ 1
            dlStoreVertex(0xD6, y)
            m[0xD5] &= m[0xDB]
            // The polygon and full tests, the vertex appended, `$D5` updated, and the return.
            charge(80)
            return
        }
        charge(12)                                   // no polygon: the outcode ($941B)
        dlPointBVisible()
    }

    /// $8896: outcode of B; projected when visible.
    func dlPointBVisible() {
        computeOutcodeB()
        if mem[0xD5] != 0 {
            charge(12)                               // not visible: return
        } else {
            charge(11)
            projectPointB()
            charge(6)
        }
    }

    // MARK: Point ops (00, 01, 02, 40, 41)

    /// $8A25 (op 00 x y z): a 3D dot. Point A is transformed (PC += 7); when its outcode is 0 it
    /// is projected (again) and plotted with the current pen.
    func opPoint3D() -> Scenery.Flow {
        setU16(Scenery.pointATransformOperand, Scenery.transform3DEntry)
        charge(18)                           // the 3D transform patched in, then $88A1
        dlPointA()
        return dlPlotPointA()
    }

    /// $8A32: when `$CC` = 0, projects A and plots it (through $99FD, with the screen x, y).
    private func dlPlotPointA() -> Scenery.Flow {
        let m = mem
        if m[0xCC] != 0 {
            charge(8)                               // outside: the next opcode
            return .loop
        }
        charge(12)                                   // visible: project ($9D05)
        projectPointA()
        charge(8)                                       // plot ($99FD)
        plot(x: m[0xD3], row: m[0xD4])
        charge(3)                                           // back to $8752
        return .loop
    }

    /// $88E5 (op 01 x y z): 3D moveto (point A, PC += 7).
    func opMove3D() -> Scenery.Flow {
        charge(7)                                   // the 3D entry, on to $88F0
        return dlMove(Scenery.transform3DEntry)
    }

    /// $88EC (op 40 x z): ground moveto (point A, y = 0, PC += 5).
    func opMoveGround() -> Scenery.Flow {
        charge(4)
        return dlMove(Scenery.transformGroundEntry)
    }

    /// $88F0: patch the point-A transform and run `$88A1`.
    private func dlMove(_ transform: UInt16) -> Scenery.Flow {
        setU16(Scenery.pointATransformOperand, transform)
        charge(14)
        dlPointA()
        charge(3)                                           // back to $8752
        return .loop
    }

    /// $88FC (op 02 x y z): 3D lineto (point B, PC += 7), drawn by the line driver unless a
    /// polygon is open.
    func opLine3D() -> Scenery.Flow {
        charge(7)                                   // the 3D entry, on to $8907
        return dlLine(Scenery.transform3DEntry)
    }

    /// $8903 (op 41 x z): ground lineto (point B, PC += 5).
    func opLineGround() -> Scenery.Flow {
        charge(4)
        return dlLine(Scenery.transformGroundEntry)
    }

    /// $8907: patch the point-B transform, run `$8860`, then the line driver (or, in a polygon,
    /// the next opcode).
    private func dlLine(_ transform: UInt16) -> Scenery.Flow {
        setU16(Scenery.pointBTransformOperand, transform)
        charge(14)
        dlPointB()
        if mem[Scenery.polygonOpen] != 0 {
            charge(10)                               // polygon: next opcode (branch crosses a page)
            return .loop
        }
        charge(8)                                   // on to the line driver
        return lineClipDriver() ? .loop : .ret
    }

    // MARK: Vertex cache (ops 31, 42, 32, 33, 35; $89E4)

    /// $89E4: `$2D/$2E` = $0400 + 8 · (the index byte at PC + Y + 1), then PC += 1. The caller
    /// charges the call.
    func vertexCacheEntry(y: Int) {
        let pc = zpPointer(0x8B)
        let index = dlByte(pc, y + 1)
        charge(7 + Self.dlCross(pc, y + 1))             // the index byte
        vertexCacheSetEntry(index)
    }

    /// $89E7: `$2D/$2E` = $0400 + 8 · A, PC += 1 (39 cycles + `dlStep` + the return).
    func vertexCacheSetEntry(_ index: UInt8) {
        let m = mem
        m[0x2D] = index << 3
        m[0x2E] = (index >> 5) &+ 4
        charge(47)                                  // the entry address, then the PC step
        dlStep(1)
        charge(6)
    }

    /// $89A4 (op 31 i x y z): transforms a 3D point into cache entry i.
    func opCachePoint3D() -> Scenery.Flow {
        charge(7)                                   // the 3D entry, on to $89AF
        return dlCachePoint(Scenery.transform3DEntry)
    }

    /// $89AB (op 42 i x z): transforms a ground point into cache entry i.
    func opCachePointGround() -> Scenery.Flow {
        charge(4)
        return dlCachePoint(Scenery.transformGroundEntry)
    }

    /// $89AF: point B is saved in `$DE-$E6`, `$DD` = $FF, the point is transformed as point B
    /// (`$8860`); a non-zero outcode goes to `$DC`; the eight bytes `$D6-$DD` (x, y, z, then the
    /// screen x, y or the outcode and $FF) are stored in the entry; point B is restored. In a
    /// polygon the point is also appended (and its outcode is not computed).
    private func dlCachePoint(_ transform: UInt16) -> Scenery.Flow {
        let m = mem
        setU16(Scenery.pointBTransformOperand, transform)
        charge(14)                                   // the transform patched in, the entry ($89E4)
        vertexCacheEntry(y: 0)
        for k in 0..<9 { m[0xDE + k] = m[0xD5 + k] }
        m[0xDD] = 0xFF
        charge(129)                         // B saved, `$DD` set, the point transformed ($8860)
        dlPointB()
        var c = 3                                           // the outcode test
        if m[0xD5] != 0 {
            m[0xDC] = m[0xD5]
            c += 5
        } else {
            c += 3
        }
        let entry = zpPointer(0x2D)
        for k in 0..<8 { m[(entry + k) & 0xFFFF] = m[0xD6 + k] }
        for k in 0..<9 { m[0xD5 + k] = m[0xDE + k] }
        charge(c + 242)                   // the entry stored, B restored
        return .loop
    }

    /// $8976: appends cache entry `$2D` to the polygon (no 60-vertex check); `$D5` &= its z high
    /// byte. 92 cycles with the return.
    private func dlCacheToPolygon() {
        let m = mem
        let entry = zpPointer(0x2D)
        let x = m[Scenery.polygonCount]
        m[Scenery.polygonCount] = x &+ 1
        for k in 0..<6 { m[Self.polygonArrays + 0x40 * k + Int(x)] = m[(entry + k) & 0xFFFF] }
        m[0xD5] &= m[(entry + 5) & 0xFFFF]
        charge(92)
    }

    /// $8917 (op 32 i): moveto cache entry i: A = the entry (outcode = byte 6 when byte 7 is
    /// negative, else 0), also copied to `$08-$10`. In a polygon the entry is appended instead.
    func opCacheMove() -> Scenery.Flow {
        let m = mem
        charge(6)                                           // the entry ($89E4)
        vertexCacheEntry(y: 0)
        if m[Scenery.polygonOpen] != 0 {
            charge(11)                               // in a polygon: append ($8976)
            dlCacheToPolygon()
            charge(8)                               // past the op
            return .advance(1)
        }
        let entry = zpPointer(0x2D)
        m[0xCC] = 0
        m[0x08] = 0
        for k in 0..<8 {
            let v = m[(entry + k) & 0xFFFF]
            m[0xCD + k] = v
            m[0x09 + k] = v
        }
        var c = 178             // the entry into A and the saved start, the validity test
        if m[0xD4] & 0x80 != 0 {
            m[0xCC] = m[0xD3]
            m[0x08] = m[0xD3]
            c += 11
        } else {
            c += 3
        }
        charge(c + 5)                                   // past the op
        return .advance(1)
    }

    /// $8946 (op 33 i): lineto cache entry i: B = the entry, then the line driver. In a polygon
    /// the entry is appended instead.
    func opCacheLine() -> Scenery.Flow {
        let m = mem
        charge(6)                                           // the entry ($89E4)
        vertexCacheEntry(y: 0)
        if m[Scenery.polygonOpen] != 0 {
            charge(11)                               // in a polygon: append ($8976)
            dlCacheToPolygon()
            charge(8)                                   // the PC step
            dlStep(1)
            charge(3)                                       // back to $8752
            return .loop
        }
        let entry = zpPointer(0x2D)
        m[0xD5] = 0
        for k in 0..<8 { m[0xD6 + k] = m[(entry + k) & 0xFFFF] }
        var c = 135                 // the entry into B, then the validity test
        if m[0xDD] & 0x80 != 0 {
            m[0xD5] = m[0xDC]
            c += 8
        } else {
            c += 3
        }
        charge(c + 8)                                   // the PC step
        dlStep(1)
        charge(3)                                           // on to the line driver
        return lineClipDriver() ? .loop : .ret
    }

    /// $8A04 (op 35 i): a dot at cache entry i (A = the entry; plotted when its outcode is 0).
    func opCacheDot() -> Scenery.Flow {
        let m = mem
        charge(6)                                           // the entry ($89E4)
        vertexCacheEntry(y: 0)
        charge(8)                                       // the PC step
        dlStep(1)
        let entry = zpPointer(0x2D)
        m[0xCC] = 0
        for k in 0..<8 { m[0xCD + k] = m[(entry + k) & 0xFFFF] }
        var c = 129                         // the entry into A, then the validity test
        if m[0xD4] & 0x80 != 0 {
            m[0xCC] = m[0xD3]
            c += 11                              // invalid: its outcode, on to $8A32
        } else {
            c += 3
        }
        charge(c)
        return dlPlotPointA()
    }

    // MARK: Polygons (2F, 29)

    /// $881B (op 2F): opens a polygon (`$23` = $FF, `$B7` = 0); falls into op 11's advance.
    func opBeginPolygon() -> Scenery.Flow {
        mem[Scenery.polygonOpen] = 0xFF
        mem[Scenery.polygonCount] = 0
        charge(15)
        return .advance(1)
    }

    /// $8828 (op 29): in a polygon, clips, projects and fills it (`clipPolygon` with `$B7` =
    /// count − 1) unless `$D5` is negative (every z behind the eye) or it has no vertex, and
    /// closes it (`$23` = 0). Outside a polygon it draws the closing line: B = the saved start
    /// point (`$08-$10`), PC += 1, then the line driver.
    func opEndPolygon() -> Scenery.Flow {
        let m = mem
        if m[Scenery.polygonOpen] == 0 {
            for k in 0..<9 { m[0xD5 + k] = m[0x08 + k] }
            charge(131)                 // B = the saved start, then the PC step
            dlStep(1)
            charge(3)                                       // on to the line driver
            return lineClipDriver() ? .loop : .ret
        }
        var c = 9                                   // the polygon and behind-the-eye tests
        if m[0xD5] & 0x80 != 0 {
            c += 3
        } else {
            let count = m[Scenery.polygonCount] &- 1
            m[Scenery.polygonCount] = count
            c += 7
            if count & 0x80 != 0 {
                c += 3
            } else {
                charge(c + 8)
                c = 0
                clipPolygon()
            }
        }
        m[Scenery.polygonOpen] = 0
        charge(c + 10)                           // closed, then past the op
        return .advance(1)
    }

    // MARK: The line driver ($8B40)

    /// $8B40: draws the line A → B. Rejected when the outcodes share a bit; otherwise A is clipped
    /// when needed (`clipLine`, `$0916` set), then B (its unclipped copy saved in `$DE-$E4`,
    /// `clipLineEnd`, `$8A` set); the clipped endpoints are re-projected and the line drawn
    /// (`$EB-$EE`, the call to $9A1D at $8B89, disabled during the horizon pass, which only
    /// captures the endpoints). Afterwards B becomes the current point A (unclipped: from
    /// `$DE-$E4` when B was clipped, else `$D5-$DD`), and `$8A` = `$0916` = 0.
    ///
    /// Returns true when the exit at $8BAC is the jump back to $8752 (the next opcode follows),
    /// false when it is patched to a return (the dashed line's loop calls the driver as a
    /// subroutine).
    func lineClipDriver() -> Bool {
        let m = mem
        var c = 6                                       // the shared-outcode test
        draw: if m[0xCC] & m[0xD5] != 0 {
            c += 3
        } else {
            c += 5                                      // A's outcode
            if m[0xCC] != 0 {
                charge(c + 8)
                clipLine()
                m[Scenery.pointAClipped] &+= 1
                c = 9                                   // A flagged clipped, its outcode again
                if m[0xCC] != 0 { c += 3; break draw }
                c += 2
            } else {
                c += 3
            }
            c += 3                                          // B's outcode
            if m[0xD5] != 0 {
                for k in 1...7 { m[0xDD + k] = m[0xD4 + k] }
                charge(c + 100)                  // B saved unclipped, then clipped ($9478)
                clipLineEnd()
                m[Scenery.pointBClipped] &+= 1
                c = 8                                   // B flagged clipped, its outcode again
                if m[0xD5] != 0 { c += 3; break draw }
                c += 2
            } else {
                c += 3
            }
            c += 4                                          // re-project A?
            if m[Scenery.pointAClipped] != 0 {
                charge(c + 8)
                projectPointA()
                c = 0
            } else {
                c += 3
            }
            c += 3                                          // re-project B?
            if m[Scenery.pointBClipped] != 0 {
                charge(c + 8)
                projectPointB()
                c = 0
            } else {
                c += 3
            }
            m[0xEB] = m[0xD3]; m[0xEC] = m[0xD4]
            m[0xED] = m[0xDC]; m[0xEE] = m[0xDD]
            c += 24
            switch m[Scenery.lineDrawOpcode] {
            case 0x20:
                charge(c + 6)
                drawLine()
                c = 0
            case 0x0D:
                c += 4                                      // the disabled call
            default:
                preconditionFailure("line driver opcode $\(hex(m[Scenery.lineDrawOpcode])) at $8B89")
            }
        }
        // $8B8C: B becomes the current point.
        c += 3                                              // which copy of B
        if m[Scenery.pointBClipped] != 0 {
            for k in 1...7 { m[0xCB + k] = m[0xDD + k] }
            c += 97                             // from the unclipped copy
        } else {
            for k in 1...9 { m[0xCB + k] = m[0xD4 + k] }
            c += 121
        }
        m[Scenery.pointBClipped] = 0
        m[Scenery.pointAClipped] = 0
        c += 9
        switch m[Scenery.lineDriverExitOpcode] {
        case 0x4C:
            charge(c + 3)
            return true
        case 0x60:
            charge(c + 6)
            return false
        default:
            preconditionFailure("line driver exit opcode $\(hex(m[Scenery.lineDriverExitOpcode])) at $8BAC")
        }
    }

    // MARK: 2D and dashed lines (06, 2B)

    /// $8BAF (op 06 x1 y1 x2 y2): a screen line (not clipped) with the current pen; the four
    /// bytes go to `$EB-$EE` (an indexed store from $00EA).
    func opScreenLine() -> Scenery.Flow {
        let m = mem
        let pc = zpPointer(0x8B)
        var c = 0
        for y in 1...4 {
            m[0xEA + y] = dlByte(pc, y)
            c += 7 + Self.dlCross(pc, y) + 7 + (y == 4 ? 2 : 3)   // one byte copied
        }
        charge(c + 6)                                       // draw ($9A1D)
        drawLine()
        charge(5)
        return .advance(5)
    }

    /// $8B2A: halves the three words at zero page X (arithmetic shift right; the zero-page
    /// index wraps). 60 cycles with the return.
    public func halvePoint(x: UInt8) {
        let m = mem
        for k in 0..<3 {
            let lo = Self.zp(Int(x), UInt8(2 * k)), hi = Self.zp(Int(x), UInt8(2 * k + 1))
            let v = Int16(bitPattern: UInt16(m[hi]) << 8 | UInt16(m[lo])) >> 1
            m[lo] = UInt8(truncatingIfNeeded: v)
            m[hi] = UInt8(truncatingIfNeeded: v >> 8)
        }
        charge(60)
    }

    /// $8A43 (op 2B x1 z1 x2 z2): a dashed ground line (runway centerlines). Both points are
    /// transformed ($9FD0; A then, with the PC stepped back by one, B), and nothing is drawn when
    /// their outcodes share a bit. The exponents are reconciled (the point with the larger one
    /// halved until they match), δ = (B − A) >> 4 goes to `$9E-$A3`, and with the driver's exit
    /// patched to a return, 8 times: B = A + δ, the line A → B (the driver then makes B the current
    /// point A), A += δ. Eight dashes of 1/16 with equal gaps; `$0AA2` counts them.
    func opDashedLine() -> Scenery.Flow {
        let m = mem
        setU16(Scenery.pointBTransformOperand, Scenery.transformGroundEntry)
        setU16(Scenery.pointATransformOperand, Scenery.transformGroundEntry)
        charge(26)                   // both transforms set to ground, then A ($88A1)
        dlPointA()
        // The PC steps back by one (with a borrow into its high byte) for B's operands.
        m[0x8B] &-= 1
        var c = 10
        if m[0x8B] == 0xFF {
            m[0x8C] &-= 1
            c += 7
        } else {
            c += 3
        }
        charge(c + 6)                                       // B ($8860)
        dlPointB()
        if m[0xCC] & m[0xD5] != 0 {
            charge(12)                           // a shared outcode bit: nothing drawn
            return .loop
        }
        charge(8)
        // $8A69: reconcile the exponents.
        while true {
            let b = m[0x2F], a = m[0x0905]
            if b == a { charge(10); break }
            if b > a {
                charge(20)               // B's exponent is larger: halve B
                halvePoint(x: 0xD6)
                m[0x2F] = b &- 1
                charge(8)
            } else {
                charge(19)               // A's is larger: halve A
                halvePoint(x: 0xCD)
                m[0x0905] = a &- 1
                charge(9)
            }
        }
        // $8A87: δ = (B − A) >> 4.
        for k in 0..<3 {
            let d = u16(0xD6 + 2 * k) &- u16(0xCD + 2 * k)
            setU16(0x9E + 2 * k, d)
        }
        charge(62)                                      // the subtractions
        for _ in 0..<4 {
            charge(6)
            halvePoint(x: 0x9E)
        }
        m[Scenery.lineDriverExitOpcode] = 0x60
        m[0x0AA2] = 8
        charge(12)
        repeat {
            charge(6)                                       // A's outcode and projection ($88D1)
            charge(6)                                       // its outcode call ($93D2)
            dlPointAVisible()
            for k in 0..<3 { setU16(0xD6 + 2 * k, u16(0xCD + 2 * k) &+ u16(0x9E + 2 * k)) }
            charge(72)                              // B = A + δ, then $8896 and its call of $941B
            dlPointBVisible()
            charge(6)                                       // the line driver ($8B40)
            let next = lineClipDriver()
            precondition(!next, "the dashed line's driver exit must be patched to RTS")
            for k in 0..<3 { setU16(0xCD + 2 * k, u16(0xCD + 2 * k) &+ u16(0x9E + 2 * k)) }
            m[0x0AA2] &-= 1
            charge(66 + (m[0x0AA2] != 0 ? 4 : 2))       // A += δ, count (loop crosses a page)
        } while m[0x0AA2] != 0
        m[Scenery.lineDriverExitOpcode] = 0x4C
        charge(9)                                   // the driver's exit jump restored
        return .loop
    }
}
