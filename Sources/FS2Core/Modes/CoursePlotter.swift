/// The course plotter ($F522-$F7DA): the Q menu, the track recorder and the plot display.
///
/// The recorded track is a scenery display list in RAM under I/O at $D000 (memory-faithful: in
/// the port $D000-$DFFF is plain RAM, and the `$01` / `$4B` stores of the bank switches are kept):
///
/// | Offset | Bytes | Meaning |
/// |---|---|---|
/// | $D000 | `07 s` + 12 bytes | op 07 origin with scale `s` (`plotScale`: 6 normal, 4 precision) and the position `$5A-$65` (east, altitude, north, 32-bit each) at the start |
/// | $D00E | `1C` | op 1C |
/// | $D00F | `01 00 00 00 00 00 00` | op 01 moveto (0, 0, 0) |
/// | $D016 | `02 dx dy dz` … | op 02 lineto per recorded point (16-bit deltas from the origin, bytes 1-3 of each 32-bit coordinate; >> 4 at scale 6) |
/// | end | `79` | the end marker, overwritten by the next point |
///
/// `plotRecordPtr` points at the end marker. Recording stops when the pointer passes $DFE0.
/// The recorder and the display share `plotterDisplay` ($F6E2, every main-loop pass).
///
/// Literal translation with exact cycles. The wait for a key ($2250) is `waitForKey` and the
/// scenery interpreter ($8006 → $8730) is `runScenery`.
public enum CoursePlotter {
    /// $F522: the menu records (the heading, options A-D, the E instructions).
    public static let menuText: UInt16 = 0xF522
    /// $0E70: Q sets it; the main loop shifts it out and calls `coursePlotterMenu`.
    public static let request = 0x0E70
    /// $0E80: the recording interval in passes (10 normal, 2 precision); $0E81 counts it down.
    public static let interval = 0x0E80
    public static let countdown = 0x0E81
    /// $0E82: 0 off, 1 recording, 2 displaying.
    public static let displayMode = 0x0E82
    /// $0E83/$0E84: the end marker of the recorded list.
    public static let recordPointer = 0x0E83
    /// $0E85: the origin scale (6 normal, 4 precision); 4 stores the deltas unshifted.
    public static let scale = 0x0E85
    /// $0E86: 1 once a recording was started (B only displays then).
    public static let recorded = 0x0E86
    /// $08BC: the editor cache state; the plotter sets 2 (invalid), D sets 0 (never loaded).
    public static let editorCacheState = 0x08BC
    /// $D000: the recorded display list; the recorder stops once the end passes $DFE0.
    public static let list = 0xD000
    public static let listOrigin = 0xD002
    /// $01 / $4B: the CPU port and the copy the raster IRQ restores it from.
    public static let cpuPort = 0x01
    public static let savedCpuPort = 0x4B
    /// $8B/$8C: the display-list PC of the scenery interpreter.
    public static let displayListPc = 0x8B
    /// $5A-$65: the position (east $5A-$5D, altitude $5E-$61, north $62-$65).
    public static let position = 0x5A
    /// $B9 / $BE / $BF: the 24-bit delta of one axis.
    public static let deltaLow = 0xB9
    public static let deltaMid = 0xBE
    public static let deltaHigh = 0xBF
    /// $BA/$BB: the record pointer while writing.
    public static let writePointer = 0xBA
}

extension Machine {
    // MARK: coursePlotterMenu ($F627)

    /// $F627 (flip passes, when `$0E70` shifts out a 1): the course plotter's menu. Each round
    /// clears the window, draws the records at $F522 and waits for a key ($2250):
    /// - A: begin normal recording (interval 10, scale 6); C: precision recording (2, 4). Both set
    ///   `$08BC` = 2, `$0E82` = 1, and write the list header at $D000 with I/O banked out
    ///   (`$0E83` = $D016, `$0E86` = 1).
    /// - B: `$08BC` = 2; when a recording exists (`$0E86`), `$0E82` = 2 (display).
    /// - D: `$0E82` = 0 and `$08BC` = 0.
    /// - E: return. Any other key, and A-D, show the menu again.
    /// Clobbers A, X, Y.
    public func coursePlotterMenu() {
        while true {
            charge(6)
            clearWindow()
            charge(10)                            // the records' address, then the call
            drawTextList(CoursePlotter.menuText)
            charge(6)
            let key = waitForKey()
            switch key {
            case 0x41:                                   // A: $F649
                charge(5)
                plotterStartRecording(normal: true)
            case 0x42:                                   // B: $F654
                charge(9)
                plotterDisplayKey()
            case 0x43:                                   // C: $F671
                charge(13)
                plotterStartRecording(normal: false)
            case 0x44:                                   // D: $F666
                charge(17)
                plotterOff()
            case 0x45:                                   // E: return
                charge(26)
                return
            default:                                     // anything else: the menu again
                charge(21)
            }
        }
    }

    /// $F649 (A, `normal`: X = 6, A = 10) / $F671 (C: X = 4, A = 2), then $F67A: the scale and
    /// interval, display mode 1, and the list header at $D000 between the bank switches. Ends
    /// by jumping back to the menu at $F627 (charged here; the menu loop continues).
    private func plotterStartRecording(normal: Bool) {
        let m = mem
        m[CoursePlotter.editorCacheState] = 2
        charge(normal ? 13 : 10)   // the cache invalidated, scale and interval (A branches to C's tail)
        m[CoursePlotter.scale] = normal ? 6 : 4
        m[CoursePlotter.interval] = normal ? 0x0A : 0x02
        m[CoursePlotter.displayMode] = 1
        charge(20)                        // stored, recording on, I/O out
        bankOutIo()
        m[CoursePlotter.writePointer] = 0x00
        m[CoursePlotter.writePointer + 1] = 0xD0
        // The write pointer at $D000, then the origin op and its scale.
        var c = 36
        var y = 0
        func store(_ v: UInt8) {
            m[Machine.indirectY(m[CoursePlotter.writePointer], m[CoursePlotter.writePointer + 1], UInt8(y))] = v
            y += 1
        }
        store(0x07)
        store(m[CoursePlotter.scale])
        for i in 0..<12 { store(m[CoursePlotter.position + i]) }
        c += 12 * 16 + 11 * 3 + 2     // the 12 position bytes
        store(0x1C)
        store(0x01)
        for _ in 0..<6 { store(0x00) }
        c += 2 + 6 + 2 + 2 + 6 + 2 + 2 + 6 * 8     // op 1C and the moveto (0, 0, 0)
        // The end marker stays at Y (the index is not advanced past it).
        m[Machine.indirectY(m[CoursePlotter.writePointer], m[CoursePlotter.writePointer + 1], UInt8(y))] = 0x79
        c += 8                                       // the end marker
        m[CoursePlotter.recordPointer] = UInt8(y) &+ m[CoursePlotter.writePointer]
        m[CoursePlotter.recordPointer + 1] = m[CoursePlotter.writePointer + 1]
        m[CoursePlotter.recorded] = 1
        c += 30           // the end pointer, the recorded flag, then I/O back in
        charge(c)
        bankInIo()
        charge(3)                                        // back to the menu
    }

    /// $F654 (B): `$08BC` = 2; display mode 2 when a recording exists. Ends by returning to the
    /// menu at $F627 (a jump, or the branch when nothing was recorded).
    private func plotterDisplayKey() {
        let m = mem
        m[CoursePlotter.editorCacheState] = 2
        guard m[CoursePlotter.recorded] != 0 else {
            charge(13)                        // nothing recorded: back to the menu
            return
        }
        m[CoursePlotter.displayMode] = 2
        charge(21)                // display mode 2, back to the menu
    }

    /// $F666 (D): display mode 0 and `$08BC` = 0. Ends by jumping back to the menu at $F627.
    private func plotterOff() {
        mem[CoursePlotter.displayMode] = 0
        mem[CoursePlotter.editorCacheState] = 0
        charge(13)
    }

    // MARK: plotterDisplay ($F6E2)

    /// $F6E2 (every main-loop pass, after the physics): by `plotDisplayMode` `$0E82`:
    /// - 0 (or 3 and up): nothing.
    /// - 1 (recording): `$0E81` counts down; at 0 it reloads from `$0E80` and, while
    ///   $DFE0 - `$0E83` is not negative (16-bit), appends a lineto record `02 dx dy dz` and a new
    ///   end marker with I/O banked out. Each delta is bytes 1-3 of the 32-bit coordinate minus
    ///   the origin's (at $D003/$D007/$D00B), shifted right 4 unless the scale `$0E85` is 4; the
    ///   low 16 bits are stored.
    /// - 2 (display): `$8B/$8C` = $D000 and the scenery interpreter runs the list ($8006)
    ///   with I/O banked out.
    /// Clobbers A, X, Y.
    public func plotterDisplay() {
        let m = mem
        let mode = m[CoursePlotter.displayMode]
        if mode == 0 {
            charge(12)                            // off
            return
        }
        if mode == 1 {
            charge(13)                        // recording (the branch lands in page $F7)
            plotterRecordStep()
            return
        }
        if mode != 2 {
            charge(21)            // 3 and up: nothing
            return
        }
        // $F6F1: the plot.
        m[CoursePlotter.displayListPc] = 0x00
        m[CoursePlotter.displayListPc + 1] = 0xD0
        charge(32)   // the list PC at $D000, then I/O out
        bankOutIo()
        charge(9)                                    // through the $8006 vector
        do { try runScenery() } catch { preconditionFailure("course plot display list: \(error)") }
        charge(6)
        bankInIo()
        charge(6)
    }

    /// $F703: one recording pass (charges through its return).
    private func plotterRecordStep() {
        let m = mem
        m[CoursePlotter.countdown] &-= 1
        guard m[CoursePlotter.countdown] == 0 else {
            charge(14)                            // not yet
            return
        }
        m[CoursePlotter.countdown] = m[CoursePlotter.interval]
        // The room left: only the sign of $DFE0 − pointer (16 bits) is used.
        let borrow = m[CoursePlotter.recordPointer] > 0xE0 ? 1 : 0
        let room = Int(0xDF) - Int(m[CoursePlotter.recordPointer + 1]) - borrow
        let cycles = 31   // the countdown reloaded, the room computed
        guard UInt8(truncatingIfNeeded: room) & 0x80 == 0 else {
            charge(cycles + 8)                       // full: nothing more is recorded
            return
        }
        charge(cycles + 9)                           // room left: I/O out
        bankOutIo()
        m[CoursePlotter.writePointer] = m[CoursePlotter.recordPointer]
        m[CoursePlotter.writePointer + 1] = m[CoursePlotter.recordPointer + 1]
        var y: UInt8 = 0
        func store(_ v: UInt8) {
            m[Machine.indirectY(m[CoursePlotter.writePointer], m[CoursePlotter.writePointer + 1], y)] = v
            y &+= 1
        }
        store(0x02)
        var c = 26            // the write pointer at the end marker; op 02 over it
        // East ($5B-$5D), altitude ($5F-$61), north ($63-$65) minus the origin's bytes.
        for axis in 0..<3 {
            let p = CoursePlotter.position + 4 * axis + 1
            let o = CoursePlotter.listOrigin + 4 * axis + 1
            var difference = Int(m[p]) - Int(m[o])
            m[CoursePlotter.deltaLow] = UInt8(truncatingIfNeeded: difference)
            var borrow = difference < 0 ? 1 : 0
            difference = Int(m[p + 1]) - Int(m[o + 1]) - borrow
            m[CoursePlotter.deltaMid] = UInt8(truncatingIfNeeded: difference)
            borrow = difference < 0 ? 1 : 0
            difference = Int(m[p + 2]) - Int(m[o + 2]) - borrow
            m[CoursePlotter.deltaHigh] = UInt8(truncatingIfNeeded: difference)
            charge(c + 38)   // the 24-bit difference, then the scaling
            c = 0
            plotterScaleDelta()
            store(m[CoursePlotter.deltaLow])
            store(m[CoursePlotter.deltaMid])
            c += 22                   // its low 16 bits stored
        }
        m[Machine.indirectY(m[CoursePlotter.writePointer], m[CoursePlotter.writePointer + 1], y)] = 0x79
        let end = Int(y) + Int(m[CoursePlotter.writePointer])
        m[CoursePlotter.recordPointer] = UInt8(end & 0xFF)
        m[CoursePlotter.recordPointer + 1] = m[CoursePlotter.writePointer + 1] &+ (end > 0xFF ? 1 : 0)
        // The new end marker, the end pointer advanced (16-bit), then I/O back in.
        charge(c + 34)
        bankInIo()
        charge(6)
    }

    /// $F7BB: unless the scale `$0E85` is 4, the 24-bit delta `$BF:$BE:$B9` >>= 4 (logical).
    /// Charges through its return.
    private func plotterScaleDelta() {
        let m = mem
        guard m[CoursePlotter.scale] != 4 else {
            charge(15)                        // precision: left unshifted
            return
        }
        let v = (UInt32(m[CoursePlotter.deltaHigh]) << 16 | UInt32(m[CoursePlotter.deltaMid]) << 8
                 | UInt32(m[CoursePlotter.deltaLow])) >> 4
        m[CoursePlotter.deltaLow] = UInt8(v & 0xFF)
        m[CoursePlotter.deltaMid] = UInt8((v >> 8) & 0xFF)
        m[CoursePlotter.deltaHigh] = UInt8(v >> 16)
        charge(4 + 2 + 2 + 4 * 15 + 6)          // the test, then four one-bit shifts of all 24 bits
    }

    // MARK: Bank switches ($F7B0 / $F7B4)

    /// $F7B0: `$4B` = `$01` = $30 (I/O and ROMs out: $D000 is RAM). In the port $D000 is always
    /// RAM; the two stores are kept so the image matches the original's.
    public func bankOutIo() {
        mem[CoursePlotter.savedCpuPort] = 0x30
        mem[CoursePlotter.cpuPort] = 0x30
        charge(17)                        // shares the two stores of $F7B4
    }

    /// $F7B4: `$4B` = `$01` = $35 (I/O back in).
    public func bankInIo() {
        mem[CoursePlotter.savedCpuPort] = 0x35
        mem[CoursePlotter.cpuPort] = 0x35
        charge(14)
    }
}
