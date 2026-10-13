/// The view overlays ($ED3C-$EE13), drawn every pass after the scenery: the radar aircraft
/// symbol, the war-mode bombsight and the per-view airframe silhouettes.
extension Machine {
    /// $EC99: 9 × 8-byte airframe trapezoids (view directions 0-$0E step 2 at index view·4, and
    /// the down view at $40): width, width fraction step, width step, start row, x, x fraction
    /// step, x step, row count. Width 0 means none (the front view).
    public static let airframeSilhouettes = 0xEC99
    /// $ECE1 / $ED1F: OR pixel lists, (offset lo, offset hi relative to the window base `[$0200]`,
    /// mask) triples ending at a zero offset-hi byte: the bombsight and (index $3E) the radar
    /// aircraft symbol.
    public static let viewOverlayPixelLists = 0xECE1
    /// $ED7E-$ED87: the trapezoid walk state (see `drawAirframe`).
    public static let airframeWalkState = 0xED7E

    // MARK: drawViewOverlay ($ED3C)

    /// $ED3C (every pass): in radar (`$0836` ≠ 0) ORs the aircraft-symbol pixel list ($ED1F);
    /// in the down view (`$0ACA` bit 7) with Europe 1917 (`$0969` ≠ 0) the bombsight list
    /// ($ECE1); otherwise draws the airframe trapezoid of view `$0ACA` (index `$0ACA`·4; the down
    /// view outside war mode uses $40). Pixel lists go through `$BA/$BB`. Clobbers A, X, Y.
    public func drawViewOverlay() {
        let m = mem
        var c = 4                                   // radar?
        var list: UInt8? = nil
        var view: UInt8 = 0
        if m[0x0836] != 0 {
            list = 0x3E
            c += 7
        } else {
            c += 7                              // no: the view direction
            view = m[0x0ACA]
            if view & 0x80 == 0 {
                c += 3
            } else {
                view = 0x10
                c += 8                      // the down view: entry $10, war mode?
                if m[0x0969] == 0 { c += 3 } else { list = 0; c += 4 }
            }
        }
        if var x = list {
            // $ED53: the pixel list.
            c += 2                                  // a zero index for the pointer
            while true {
                m[0xBA] = m[Self.viewOverlayPixelLists + Int(x)]
                c += 4 + (x >= 0x1F ? 1 : 0) + 5
                x &+= 1
                let high = m[Self.viewOverlayPixelLists + Int(x)]
                c += 4 + (x >= 0x1F ? 1 : 0)
                if high == 0 { c += 3; break }
                m[0xBB] = high &+ m[Self.rowAddressHi]
                x &+= 1
                let address = Int(m[0xBA]) | Int(m[0xBB]) << 8
                m[address] |= m[Self.viewOverlayPixelLists + Int(x)]
                c += 17 + (x >= 0x1F ? 1 : 0) + 13
                x &+= 1
                if x == 0 { c += 2; break }
                c += 3
            }
            charge(c + 6)
            return
        }
        // $ED72: the airframe of this view.
        let index = view << 2
        charge(c + 13)
        drawAirframe(index)
        charge(6 + (index == 0x40 ? 3 : 2) + 6)
    }

    // MARK: drawAirframe ($ED88)

    /// $ED88: the white span-filled trapezoid of entry A (byte offset into $EC99): color `$0876`
    /// = 9 (`setSpanColorFromPalette`, through $801E), then for `count` rows from the start row:
    /// a span of width+1 pixels ending at x (through $801B), and the 8.8 sums x += x step,
    /// width += width step (fractions in `$ED7E`/`$ED82`, cleared first). A zero width returns
    /// at once. Clobbers A, X, Y.
    public func drawAirframe(_ entry: UInt8) {
        let m = mem
        m[0x0876] = 9
        charge(18)                   // save the entry, color 9, through $801E
        setSpanColorFromPalette()
        let t = Self.airframeSilhouettes + Int(entry)
        let s = Self.airframeWalkState
        @inline(__always) func cross(_ k: Int) -> Int { Int(entry) + 0x99 + k > 0xFF ? 1 : 0 }
        m[s + 4] = 0                                // $ED82: width fraction
        m[s] = 0                                    // $ED7E: x fraction
        m[s + 5] = m[t]                             // $ED83: width
        var c = 20 + cross(0) + 4   // the entry back, fractions cleared, the width read
        if m[t] == 0 { charge(c + 9); return }
        m[s + 6] = m[t + 1]                         // $ED84: width fraction step
        m[s + 7] = m[t + 2]                         // $ED85: width step
        m[s + 8] = m[t + 3]                         // $ED86: row
        m[s + 1] = m[t + 4]                         // $ED7F: x
        m[s + 2] = m[t + 5]                         // $ED80: x fraction step
        m[s + 3] = m[t + 6]                         // $ED81: x step
        m[s + 9] = m[t + 7]                         // $ED87: row count
        c += 2
        for k in 1...7 { c += 4 + cross(k) + 4 }
        charge(c)
        repeat {
            // $EDCD
            m[0x1E] = m[s + 1]
            let row = Int(m[s + 8])
            m[0x8E] = m[Self.rowAddressLo + row]
            m[0x8F] = m[Self.rowAddressHi + row]
            var c = 15 + (row >= 0x38 ? 1 : 0) + 23   // right end, row pointer, through $801B
            c += spanBody(m[s + 5])
            let xf = UInt16(m[s]) + UInt16(m[s + 2])
            m[s] = UInt8(truncatingIfNeeded: xf)
            m[s + 1] = m[s + 1] &+ m[s + 3] &+ UInt8(xf >> 8)
            let wf = UInt16(m[s + 4]) + UInt16(m[s + 6])
            m[s + 4] = UInt8(truncatingIfNeeded: wf)
            m[s + 5] = m[s + 5] &+ m[s + 7] &+ UInt8(wf >> 8)
            m[s + 8] &+= 1
            m[s + 9] &-= 1
            c += 64
            c += m[s + 9] != 0 ? 4 : 2              // the loop branch back crosses a page
            charge(c)
        } while m[s + 9] != 0
        charge(6)
    }
}
