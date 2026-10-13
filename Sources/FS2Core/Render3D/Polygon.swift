/// Polygons: the Sutherland-Hodgman clipper $8FE8 and the projection, edge setup and scan fill
/// $96D4-$990F.
///
/// Vertices live in twelve 64-byte arrays: the polygon arrays $0B10 (x lo), $0B50 (x hi), $0B90
/// (y lo), $0BD0 (y hi), $0C10 (z lo), $0C50 (z hi) and the clipper's ping-pong copies $0C90-
/// $0DD0 in the same order. All indexing is 8-bit and unbounded, as in the original: indices
/// past 63 run into the next array (index i + 64 of one array is index i of the next), the
/// copies reach $0E91 (past $0E0F into the aero gain tables), and every read and write goes to
/// memory in the original's order, so overflowing polygons alias exactly as there.
///
/// Overflow (large clipped polygons; real scenery polygons never get there):
/// - A pass can write more than 64 vertices, up to 1.5 times its input (193 from 129). A pass
///   of 130+ vertices (count − 1 ≥ $81) handles only that last vertex (the walk stops once its
///   8-bit index turns negative; 129 start at index $80 and walk them all), and
///   `projectAndFillPolygon` returns at once for 129+.
/// - The projected x/y ($0CD0/$0D50 = the copies' x hi/y hi) overlap from index 128, the
///   closing slot $0D4F is x[127], and edges 64+ alias the fields of edges 0+ (edge 128's slope
///   high byte is x[0]).
/// - Garbage crossings: 27+ crossings on a row reach `$1C` (the edge count the next row reads),
///   `$1D` and `$1E`; a row of 129+ skips its sort and spans (the count reads as negative).
///   x values above 159 make the spans read `$14DA` past the window's columns; a long span
///   ending at x = 160-163 plants its return opcode on the filler's own final return ($85BF),
///   which the restore then turns into $91. A long span whose left end (rounded up to its
///   byte) lies right of x = 163 enters its row filler past its end, in the split row's code
///   $85C0-$8622, which the original then runs from the middle; a row pointer scrambled by
///   the degenerate sort can make the spans write into code that runs later in the call (the
///   row filler). The port does not follow the original into such code (excluded inputs,
///   render3d.md); everything before it matches.
extension Machine {
    /// $0B10: the first polygon vertex array (x lo); the six arrays follow at $40 steps.
    public static let polygonArrays = 0x0B10
    /// $0C90: the first clipper copy array (x lo).
    public static let clipArrays = 0x0C90
    /// $98AD: the self-modified zero-page operand of the crossing store at $98AC (the next
    /// crossing slot, reset to $02 per row).
    public static let crossingSlotOperand = 0x98AD

    // MARK: clipPolygon ($8FE8)

    /// $8FE8: clips the polygon of `$B7` + 1 vertices in the $0B10 arrays against x = z, y = z,
    /// x = −z and y = −z (four passes ping-ponging to $0C90 and back), then projects and fills it
    /// (`projectAndFillPolygon`). Returns early when a pass leaves no vertices (`$B7` = 0).
    ///
    /// Each pass first copies vertex 0 to index n (closing the polygon) and walks the vertices
    /// from n − 1 down to 0 (until the 8-bit index turns negative). A vertex is inside when the
    /// sign of z − x (z − y, x + z, y + z) is clear; `$B6` holds the previous vertex's flag ($00
    /// inside, $FF outside). Where the flag changes, the edge (B = vertex i, A = vertex i + 1)
    /// is clipped by the pass's plane routine and the clipped point appended unless its z is
    /// 0 (its z high byte is written to the output either way); an inside vertex is appended
    /// after that. `$B2/$B3` save the indices around the plane call.
    public func clipPolygon() {
        let m = mem
        m[0xB7] &+= 1
        charge(5)
        var count = clipPass(from: Self.polygonArrays, to: Self.clipArrays, plane: .xPos)
        guard storePassCount(count) else { return }
        count = clipPass(from: Self.clipArrays, to: Self.polygonArrays, plane: .yPos)
        guard storePassCount(count) else { return }
        count = clipPass(from: Self.polygonArrays, to: Self.clipArrays, plane: .xNeg)
        guard storePassCount(count) else { return }
        count = clipPass(from: Self.clipArrays, to: Self.polygonArrays, plane: .yNeg)
        charge(3)                                   // on to $96D4
        projectAndFillPolygon(count)
    }

    /// Stores a pass's vertex count in `$B7`: false (after the return) when the pass left no
    /// vertices.
    private func storePassCount(_ count: UInt8) -> Bool {
        mem[0xB7] = count
        if count == 0 { charge(14); return false }
        charge(9)
        return true
    }

    private enum ClipPlane {
        case xPos, yPos, xNeg, yNeg
    }

    /// One Sutherland-Hodgman pass from the arrays at `src` to those at `dst`. Returns Y, the
    /// number of vertices written.
    private func clipPass(from src: Int, to dst: Int, plane: ClipPlane) -> UInt8 {
        let m = mem
        @inline(__always) func cross(_ array: Int, _ index: UInt8) -> Int {
            (array & 0xFF) + Int(index) > 0xFF ? 1 : 0
        }
        // The two components of the inside test: z and x (or y); x + z / y + z for the
        // negative planes (the branch tests the opposite sign, so its taken/untaken costs swap).
        let component = plane == .xPos || plane == .xNeg ? 0 : 2   // array pair: x 0, y 2
        let sum = plane == .xNeg || plane == .yNeg
        @inline(__always) func value(_ base: Int, _ i: Int) -> UInt16 {
            let a = UInt16(m[base + component * 0x40 + i]) | UInt16(m[base + (component + 1) * 0x40 + i]) << 8
            let z = UInt16(m[base + 4 * 0x40 + i]) | UInt16(m[base + 5 * 0x40 + i]) << 8
            return sum ? a &+ z : z &- a
        }
        @inline(__always) func flagCost(_ outside: Bool) -> Int {
            sum ? (outside ? 7 : 5) : (outside ? 5 : 7)
        }
        // Close the polygon: vertex 0 to index n, array by array (with n = 64, 128 or 192 a copy
        // lands on index 0 of a later array before that array is copied). The first inside
        // test then reads index 0 (absolute operands), which equals index n after the copies.
        let n = m[0xB7]
        for k in 0..<6 { m[src + k * 0x40 + Int(n)] = m[src + k * 0x40] }
        let outside0 = value(src, 0) & 0x8000 != 0
        var previous: UInt8 = outside0 ? 0xFF : 0
        m[0xB6] = previous
        var c = 75 + flagCost(outside0) + 7   // close the polygon, first test, start the walk
        var x = n &- 1
        var y: UInt8 = 0
        while true {
            // The inside test of vertex x.
            c += 2 + 4 * 4 + cross(src + 4 * 0x40, x) + cross(src + component * 0x40, x)
                + cross(src + 5 * 0x40, x) + cross(src + (component + 1) * 0x40, x)
            let outside = value(src, Int(x)) & 0x8000 != 0
            let flag: UInt8 = outside ? 0xFF : 0
            c += flagCost(outside) + 6          // against the previous flag, then stored
            let changed = flag != previous
            previous = flag
            m[0xB6] = flag
            if changed {
                // B = vertex x, A = vertex x + 1.
                c += 2 + 12 * 7
                for k in 0..<6 {
                    m[0xD6 + k] = m[src + k * 0x40 + Int(x)]
                    c += cross(src + k * 0x40, x)
                }
                for k in 0..<6 {
                    m[0xCD + k] = m[src + k * 0x40 + Int(x) + 1]
                    c += cross(src + k * 0x40 + 1, x)
                }
                m[0xB3] = y; m[0xB2] = x
                charge(c + 12)
                switch plane {
                case .xPos: clipPlaneXPos()
                case .yPos: clipPlaneYPos()
                case .xNeg: clipPlaneXNeg()
                case .yNeg: clipPlaneYNeg()
                }
                x = m[0xB2]; y = m[0xB3]
                m[dst + 5 * 0x40 + Int(y)] = m[0xDB]
                c = 17                // indices back, z high out, is z zero?
                if m[0xDB] | m[0xDA] == 0 {
                    c += 3
                } else {
                    m[dst + 4 * 0x40 + Int(y)] = m[0xDA]
                    m[dst + Int(y)] = m[0xD6]
                    m[dst + 0x40 + Int(y)] = m[0xD7]
                    m[dst + 2 * 0x40 + Int(y)] = m[0xD8]
                    m[dst + 3 * 0x40 + Int(y)] = m[0xD9]
                    y &+= 1
                    c += 2 + 5 * 8 + 2
                }
            } else {
                c += 3
            }
            // Append vertex x when inside.
            c += 3                                  // inside?
            if flag == 0 {
                for k in 0..<6 {
                    m[dst + k * 0x40 + Int(y)] = m[src + k * 0x40 + Int(x)]
                    c += 4 + cross(src + k * 0x40, x) + 5
                }
                y &+= 1
                c += 4
            } else {
                c += 3
            }
            x &-= 1
            c += 2                                  // next vertex
            if x & 0x80 != 0 { c += 3; break }
            c += 5                              // loop back
        }
        charge(c)
        return y
    }

    // MARK: projectAndFillPolygon ($96D4)

    /// $96D4: projects vertices 0..Y−1 of the $0B10 arrays (`project`; sx to $0CD0, sy to $0D50,
    /// the row range into `$F1`/`$F2`), closes the screen polygon ($0CCF/$0D4F = the last vertex,
    /// [n] and [n+1] = vertices 0 and 1), builds the edge table and scan-fills it. Y = 0 returns
    /// at once.
    ///
    /// Edge table (index X), from vertex Y to Y + 1:
    /// - Sloped edges: `$0B10` = top row, `$0B50` = rows (minus one when the polygon goes on
    ///   downwards or level past the edge's lower vertex, flagged in `$0B90`), `$0BD0` = x at
    ///   the top, `$0C50:$0C10` = the signed 8.8 slope |dx|·256 / rows (a 16-step division by
    ///   `$F8:$F9`, `$F9` being whatever is there). `$0B90` is also the x fraction: it starts at
    ///   the flag (0, or 1 for a decremented edge, which is never cleared).
    /// - Horizontal runs (consecutive edges on one row): `$0B50` = $FF, `$0B10` = the row,
    ///   `$0BD0` = max x, `$0C50` = max − min. A run at a top of the polygon (both neighboring
    ///   vertices below it on screen) is dropped and its slot reused: the two sloped edges that
    ///   start there cover its row.
    ///
    /// The fill (color `$158A[$9BD6[$0876 & 15]]` via $9C93) runs rows `$F1` to `$F2` (`$B3`):
    /// active sloped edges deposit their x through a self-modified zero-page store (slot
    /// operand $98AD, from $02 up) and step; horizontal runs are spanned directly. The
    /// crossings are bubble-sorted (descending) and spanned in pairs (`span`); `$C8:$C9`
    /// accumulates count − 1 per row.
    public func projectAndFillPolygon(_ count: UInt8) {
        let m = mem
        let last = count &- 1
        if last & 0x80 != 0 { charge(11); return }
        m[0xB7] = last
        m[0xF1] = 0x6F
        m[0xF2] = 0
        var c = 21
        var x = last
        let poly = Self.polygonArrays
        @inline(__always) func cross(_ array: Int, _ index: UInt8) -> Int {
            (array & 0xFF) + Int(index) > 0xFF ? 1 : 0
        }
        // $96E3: project every vertex.
        while true {
            let xi = Int(x)
            m[0xC4] = m[poly + xi]; m[0xC5] = m[poly + 0x40 + xi]
            m[0xC6] = m[poly + 0x100 + xi]; m[0xC7] = m[poly + 0x140 + xi]
            m[0xB4] = x
            c += 45
            c += cross(poly, x) + cross(poly + 0x40, x) + cross(poly + 0x100, x) + cross(poly + 0x140, x)
            c += cross(poly + 0x80, x) + cross(poly + 0xC0, x)
            charge(c)
            let p = project(a: m[poly + 0xC0 + xi], y: m[poly + 0x80 + xi])
            x = m[0xB4]
            m[0x0CD0 + Int(x)] = p.a
            m[0x0D50 + Int(x)] = p.y
            c = 18                   // store sx and sy, widen the row range
            if p.y < m[0xF1] { m[0xF1] = p.y; c += 5 } else { c += 3 }
            c += 3
            if p.y >= m[0xF2] { m[0xF2] = p.y; c += 5 } else { c += 3 }
            x &-= 1
            c += 2
            if x & 0x80 != 0 { c += 2; break }
            c += 4                                  // loop back (the branch crosses a page)
        }
        // $971A: close the screen polygon.
        var xi = Int(m[0xB7])
        m[0x0CCF] = m[0x0CD0 + xi]
        m[0x0D4F] = m[0x0D50 + xi]
        c += 7 + cross(0x0CD0, UInt8(xi)) + 8 + cross(0x0D50, UInt8(xi)) + 4
        xi = (xi + 1) & 0xFF
        m[0x0CD0 + xi] = m[0x0CD0]
        m[0x0D50 + xi] = m[0x0D50]
        xi = (xi + 1) & 0xFF
        m[0x0CD0 + xi] = m[0x0CD1]
        m[0x0D50 + xi] = m[0x0D51]
        m[0xB7] &+= 1
        c += 49
        charge(c)
        let edges = polygonEdgeSetup()
        polygonScanFill(lastEdge: edges)
    }

    /// $9748-$985F: the edge table; returns the last edge index (`$1C`).
    private func polygonEdgeSetup() -> UInt8 {
        let m = mem
        let xs = 0x0CD0, ys = 0x0D50
        var x: UInt8 = 0, y: UInt8 = 0
        @inline(__always) func cross(_ array: Int, _ index: UInt8) -> Int {
            (array & 0xFF) + Int(index) > 0xFF ? 1 : 0
        }
        @inline(__always) func at(_ array: Int, _ index: UInt8) -> UInt8 { m[array + Int(index)] }
        var c = 0
        while true {
            // $9748
            let xi = Int(x)
            m[0x0B90 + xi] = 0
            let dy = at(ys + 1, y) &- at(ys, y)
            c += 11 + cross(ys + 1, y) + 6 + cross(ys, y)
            var advance = true
            if dy != 0 {
                c += 3                              // a sloped edge
                let down = at(ys + 1, y) >= at(ys, y)
                var dx: UInt8
                if !down {
                    // Upward edge: start at vertex y + 1.
                    m[0x0B50 + xi] = 0 &- dy
                    m[0x0B10 + xi] = at(ys + 1, y)
                    c += 15 + cross(ys + 1, y) + 5
                    c += 4 + cross(ys - 1, y) + 4 + cross(ys, y)
                    if at(ys - 1, y) >= at(ys, y) { m[0x0B90 + xi] &+= 1; c += 9 } else { c += 3 }
                    m[0x0BD0 + xi] = at(xs + 1, y)
                    dx = at(xs, y) &- at(xs + 1, y)
                    let positive = at(xs, y) >= at(xs + 1, y)
                    c += 4 + cross(xs + 1, y) + 9 + cross(xs, y) + 6 + cross(xs + 1, y) + 3
                    c += edgeSlope(x: x, y: y, dx: dx, positive: positive)
                } else {
                    // Downward edge: start at vertex y.
                    m[0x0B50 + xi] = dy
                    m[0x0B10 + xi] = at(ys, y)
                    c += 12 + cross(ys, y) + 5
                    c += 4 + cross(ys + 2, y) + 4 + cross(ys + 1, y)
                    if at(ys + 2, y) >= at(ys + 1, y) { m[0x0B90 + xi] &+= 1; c += 9 } else { c += 3 }
                    m[0x0BD0 + xi] = at(xs, y)
                    dx = at(xs + 1, y) &- at(xs, y)
                    let positive = at(xs + 1, y) >= at(xs, y)
                    c += 4 + cross(xs, y) + 9 + cross(xs + 1, y) + 6 + cross(xs, y)
                    c += edgeSlope(x: x, y: y, dx: dx, positive: positive)
                }
            } else {
                // $980E: a horizontal run, extended over the following edges on the same row.
                c += 5
                m[0x0B50 + xi] = 0xFF
                let row = at(ys, y)
                m[0x0B10 + xi] = row
                let continues = row >= at(ys - 1, y)  // the carry saved on the stack
                m[0x0C50 + xi] = at(xs, y)
                m[0x0BD0 + xi] = at(xs, y)
                c += 11 + cross(ys, y) + 9 + cross(ys - 1, y) + 7 + cross(xs, y) + 10
                var finalize: Bool
                while true {
                    // $9826
                    y &+= 1
                    let v = at(xs, y)
                    c += 6 + cross(xs, y) + 4 + cross(0x0C50, x)
                    if v < m[0x0C50 + xi] { m[0x0C50 + xi] = v; c += 7 } else { c += 3 }
                    c += 4 + cross(0x0BD0, x)
                    if v >= m[0x0BD0 + xi] { m[0x0BD0 + xi] = v; c += 7 } else { c += 3 }
                    let r = m[0x0B10 + xi], next = at(ys + 1, y)
                    c += 4 + cross(0x0B10, x) + 4 + cross(ys + 1, y)
                    if r == next { c += 3; continue }
                    c += 2
                    if r > next {
                        c += 7                  // the run's end turns upward: finish it
                        finalize = true
                    } else {
                        c += 6                  // the saved carry decides
                        if continues { c += 5; finalize = true } else { c += 3; finalize = false }
                    }
                    break
                }
                if finalize {
                    // $984A: the run's width.
                    m[0x0C50 + xi] = m[0x0BD0 + xi] &- m[0x0C50 + xi]
                    y &-= 1
                    c += 4 + cross(0x0BD0, x) + 6 + cross(0x0C50, x) + 7
                } else {
                    advance = false                 // straight to $9857: the indices stay
                }
            }
            if advance {
                x &+= 1
                y &+= 1
                c += 4
            }
            // $9857: done once y − `$B7` (8 bits) is not negative
            c += 3
            if (y &- m[0xB7]) & 0x80 == 0 { c += 3; break }
            c += 5
        }
        // $985E
        x &-= 1
        m[0x1C] = x
        charge(c + 5)
        return x
    }

    /// $97A4-$9808: the slope of a sloped edge (`$F7` = |dx|, `$F8` = rows, a 16-step division
    /// into `$F6:$F7`), the rows decrement for flagged edges (the flag in `$0B90` stays, as the
    /// starting x fraction), and the signed slope into `$0C10/$0C50`. Returns the cycles from
    /// saving the sign of dx through the jump back to $9855.
    private func edgeSlope(x: UInt8, y: UInt8, dx: UInt8, positive: Bool) -> Int {
        let m = mem
        let xi = Int(x)
        var c = 3                                   // save the sign of dx
        var magnitude = dx
        if positive {
            c += 3
        } else {
            m[0xAF] = dx                            // negated by way of $AF
            magnitude = 0 &- dx
            c += 12
        }
        m[0xF7] = magnitude
        m[0xF8] = m[0x0B50 + xi]
        m[0xB2] = x; m[0xB3] = y
        m[0xF6] = 0; m[0xFA] = 0; m[0xFB] = 0
        c += 7 + (0x50 + xi > 0xFF ? 1 : 0) + 22
        var f6: UInt8 = 0, f7 = magnitude, fa: UInt8 = 0, fb: UInt8 = 0
        let f8 = m[0xF8], f9 = m[0xF9]
        for step in 0..<16 {
            let c1 = f6 >> 7; f6 <<= 1
            let c2 = f7 >> 7; f7 = f7 << 1 | c1
            let c3 = fa >> 7; fa = fa << 1 | c2
            fb = fb << 1 | c3
            let (low, borrow) = fa.subtractingReportingOverflow(f8)
            let high = Int(fb) - Int(f9) - (borrow ? 1 : 0)
            c += 36
            if high >= 0 {
                f6 |= 1
                fb = UInt8(high)
                fa = low
                c += 13
            } else {
                c += 3
            }
            c += 2 + (step < 15 ? 3 : 2)            // count the step
        }
        m[0xF6] = f6; m[0xF7] = f7; m[0xFA] = fa; m[0xFB] = fb
        c += 10 + (0x90 + xi > 0xFF ? 1 : 0)   // indices back, check the edge's flag
        if m[0x0B90 + xi] != 0 { m[0x0B50 + xi] &-= 1; c += 9 } else { c += 3 }
        c += 4                                      // the saved sign of dx
        if positive {
            m[0x0C10 + xi] = f6
            m[0x0C50 + xi] = f7
            c += 23
        } else {
            let v = 0 &- (UInt16(f7) << 8 | UInt16(f6))
            m[0x0C10 + xi] = UInt8(truncatingIfNeeded: v)
            m[0x0C50 + xi] = UInt8(truncatingIfNeeded: v >> 8)
            c += 27
        }
        return c
    }

    /// $9861-$990F: the scan fill over the edge table (edges `lastEdge` down to 0).
    private func polygonScanFill(lastEdge: UInt8) {
        let m = mem
        charge(6)
        setSpanColorFromPalette()
        m[0xB3] = m[0xF1]
        m[0xC8] = 0; m[0xC9] = 0
        var c = 14
        @inline(__always) func cross(_ array: Int, _ index: UInt8) -> Int {
            (array & 0xFF) + Int(index) > 0xFF ? 1 : 0
        }
        while true {
            // $986E
            var x = m[0x1C]
            m[Self.crossingSlotOperand] = 2
            let row = Int(m[0xB3])
            m[0x8E] = m[Self.rowAddressLo + row]
            m[0x8F] = m[Self.rowAddressHi + row]
            c += 16 + (row >= 0x38 ? 1 : 0) + 10
            while true {
                // $9881
                let xi = Int(x)
                c += 7 + cross(0x0B10, x)
                if m[0xB3] != m[0x0B10 + xi] {
                    c += 3
                } else {
                    c += 6 + cross(0x0B50, x)
                    if m[0x0B50 + xi] & 0x80 != 0 {
                        // A horizontal run: span it.
                        m[0x1E] = m[0x0BD0 + xi]
                        m[0xB2] = x
                        c += 6 + cross(0x0BD0, x) + 7 + cross(0x0C50, x) + 9
                        c += spanBody(m[0x0C50 + xi])
                        x = m[0xB2]
                        c += 6
                    } else {
                        // $989F: deposit the crossing, step the edge.
                        let fraction = UInt16(m[0x0B90 + Int(x)]) + UInt16(m[0x0C10 + Int(x)])
                        m[0x0B90 + Int(x)] = UInt8(truncatingIfNeeded: fraction)
                        let current = m[0x0BD0 + Int(x)]
                        m[Int(m[Self.crossingSlotOperand])] = current
                        m[Self.crossingSlotOperand] &+= 1
                        m[0x0BD0 + Int(x)] = current &+ m[0x0C50 + Int(x)] &+ UInt8(fraction >> 8)
                        m[0x0B50 + Int(x)] &-= 1
                        c += 7 + cross(0x0B90, x) + 6 + cross(0x0C10, x) + 5
                        c += 4 + cross(0x0BD0, x) + 13 + cross(0x0C50, x) + 12
                        if m[0x0B50 + Int(x)] & 0x80 != 0 {
                            c += 3
                        } else {
                            m[0x0B10 + Int(x)] &+= 1
                            c += 9
                        }
                    }
                }
                x &-= 1
                c += 2
                if x & 0x80 != 0 { c += 2; break }
                c += 3
            }
            // $98C2: crossings - 1.
            let n = m[Self.crossingSlotOperand] &- 3
            c += 8
            if n & 0x80 == 0 {
                m[0x1D] = n
                let total = UInt16(m[0xC8]) + UInt16(n)
                m[0xC8] = UInt8(truncatingIfNeeded: total)
                c += 15
                if total > 0xFF { m[0xC9] &+= 1; c += 7 } else { c += 3 }
                // $98D6: bubble sort, descending.
                var yy = n
                repeat {
                    var xx = yy &- 1
                    c += 6
                    while true {
                        let ax = (2 + Int(xx)) & 0xFF, ay = 2 + Int(yy)
                        c += 8 + (ay > 0xFF ? 1 : 0)
                        if m[ax] < m[ay] {
                            let t = m[ax]
                            m[ax] = m[ay]
                            m[ay] = t
                            c += 9 + (ay > 0xFF ? 1 : 0) + 13
                        } else {
                            c += 3
                        }
                        xx &-= 1
                        c += 2
                        if xx & 0x80 != 0 { c += 2; break }
                        c += 3
                    }
                    yy &-= 1
                    c += 2 + (yy != 0 ? 3 : 2)
                } while yy != 0
                // $98F0: span the pairs.
                var xx = m[0x1D]
                c += 3
                charge(c)
                c = 0
                while true {
                    // The right end goes to `$1E` before the left end is read: with 29+
                    // crossings the left end's slot $02+X can be `$1E` itself.
                    let right = m[(1 + Int(xx)) & 0xFF]
                    m[0x1E] = right
                    let length = right &- m[(2 + Int(xx)) & 0xFF]
                    m[0xB4] = xx
                    c += 22
                    c += spanBody(length)
                    xx = m[0xB4] &- 2
                    c += 7
                    if xx & 0x80 != 0 { c += 2; break }
                    c += 4                          // loop back (the branch crosses a page)
                }
            } else {
                c += 4                              // nothing to span (the branch crosses a page)
            }
            // $9904: next row.
            m[0xB3] &+= 1
            c += 11
            if (m[0xF2] &- m[0xB3]) & 0x80 != 0 { charge(c + 9); return }
            c += 5
            charge(c)
            c = 0
        }
    }
}
