import Foundation
import FS2Core
import FS2LabKit
import Testing

/// Differential tests of the 2D raster primitives and the 3x5 text renderer ($9910-$9D04,
/// $851B, $1D54-$1EC9): every case runs the original routine and the port on the same RAM —
/// the running game at Meigs, with the window rows pointing at either bitmap — and expects the
/// whole memory image (stack page excluded) and the cycle count to match exactly.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"))
struct RasterDiffTests {
    // MARK: Fixtures

    /// The regular-flight RAM, with the 112 window rows pointing at bitmap B ($6000, as captured)
    /// or flipped to bitmap A ($4000) the way the main loop flips them.
    static func baseRAM(bitmapA: Bool) throws -> [UInt8] {
        var ram = try Original.regularFlight()
        if bitmapA {
            for row in 0..<112 {
                let hi = ram[0x0200 + row]
                ram[0x0200 + row] = hi &+ (hi >= 0x60 ? 0xE0 : 0x20)
            }
        }
        return ram
    }

    /// RAM after running an original routine (used to put the pen code into a given state).
    static func prepared(_ ram: [UInt8], _ address: UInt16, _ regs: RoutineHarness.Registers) -> [UInt8] {
        let r = Original.call(address, ram: ram, regs)
        precondition(r.result.completed)
        return r.ram
    }

    /// The display-list ops end with a jump to $8749; a return opcode planted there makes them
    /// callable alone.
    static func withDlAdvanceStub(_ ram: [UInt8]) -> [UInt8] {
        var r = ram
        r[0x8749] = 0x60
        return r
    }

    /// The line/plot pen states to test: every plain and XOR pen, the dotted patch (op $1C), and
    /// the operands the code has on disk.
    static func penStates(_ base: [UInt8]) throws -> [(String, [UInt8])] {
        var states: [(String, [UInt8])] = []
        for pen: UInt8 in [0, 1, 2, 3, 0x80, 0x81, 0x82, 0x83] {
            states.append((String(format: "pen $%02X", pen), prepared(base, 0x9BF5, .init(a: pen))))
        }
        var night = withDlAdvanceStub(base)
        night[0x083C] &= 0xFE
        var dotted = prepared(night, 0x9B9B, .init())
        dotted[0x8749] = base[0x8749]
        dotted[0x083C] = base[0x083C]
        states.append(("dotted", dotted))
        var cold = base
        let disk = Original.data!.coldMemory
        for site in PixelSite.allCases.map(\.rawValue) {
            for i in 0..<6 { cold[site + i] = disk[site + i] }
        }
        for i in 0..<3 { cold[PixelSite.dottedOp + i] = disk[PixelSite.dottedOp + i] }
        states.append(("cold operands", cold))
        return states
    }

    // MARK: Comparison

    /// Runs original routines and their ports on the same RAM and records mismatches: memory
    /// outside the stack page, or cycles. `expectClean` reports them (the first 20 in detail).
    final class Rig {
        let machine = Machine(memory: [UInt8](repeating: 0, count: 0x10000))
        var cases = 0
        var failed = 0
        var failures: [String] = []
        /// The original's RAM after the last case (operation sequences continue from it).
        var lastOriginalRAM: [UInt8] = []

        /// Runs the original at `address` (with `regs`) and `port` on copies of `ram`, then compares
        /// them; `cycleOffset` is added to the port's cycles. Returns the original's result.
        @discardableResult
        func check(_ label: @autoclosure () -> String, _ ram: [UInt8], _ address: UInt16,
                   _ regs: RoutineHarness.Registers = .init(), cycleOffset: Int = 0,
                   port: (Machine) -> Void) -> RoutineHarness.Result {
            cases += 1
            let o = Original.call(address, ram: ram, regs)
            lastOriginalRAM = o.ram
            machine.load(memory: ram)
            machine.clock.cycles = 0
            port(machine)
            guard o.result.completed else { fail(label(), "original did not return"); return o.result }
            let pm = machine.mem
            let same = o.ram.withUnsafeBufferPointer { ob in
                memcmp(ob.baseAddress!, pm, 0x100) == 0
                    && memcmp(ob.baseAddress! + 0x200, pm + 0x200, 0xFE00) == 0
            }
            if !same {
                let diffs = Original.differences(o.ram, machine.memoryImage)
                let shown = diffs.prefix(8).map { String(format: "$%04X orig %02X port %02X", $0, o.ram[$0], pm[$0]) }
                fail(label(), "\(diffs.count) bytes differ: " + shown.joined(separator: ", "))
            } else if Int(machine.clock.cycles) + cycleOffset != Int(o.result.cycles) {
                fail(label(), "cycles: original \(o.result.cycles), port \(Int(machine.clock.cycles) + cycleOffset)")
            }
            return o.result
        }

        func fail(_ label: String, _ what: String) {
            failed += 1
            if failures.count < 20 { failures.append("\(label): \(what)") }
        }

        func expectClean(_ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
            let report = "\(what): \(failed) failing of \(cases)\n" + failures.joined(separator: "\n")
            #expect(failed == 0, "\(report)", sourceLocation: sourceLocation)
        }
    }

    // MARK: Pens

    @Test func setPenAllValues() throws {
        let rig = Rig()
        for start in try Self.penStates(try Self.baseRAM(bitmapA: false)) {
            for a in 0..<256 {
                rig.check("\(start.0) then setPen $\(String(a, radix: 16))", start.1, 0x9BF5, .init(a: UInt8(a))) {
                    $0.setPen(UInt8(a))
                }
            }
        }
        rig.expectClean("setPen")
    }

    @Test func spanColorAllValues() throws {
        let rig = Rig()
        let base = try Self.baseRAM(bitmapA: false)
        for x in 0..<256 {
            rig.check("setSpanColor X=$\(String(x, radix: 16))", base, 0x9C9C, .init(x: UInt8(x))) {
                $0.setSpanColor(UInt8(x))
            }
        }
        for color in 0..<256 {
            var ram = base
            ram[0x0876] = UInt8(color)
            rig.check("setSpanColorFromPalette $0876=$\(String(color, radix: 16))", ram, 0x9C93) {
                $0.setSpanColorFromPalette()
            }
        }
        rig.expectClean("span colors")
    }

    @Test func displayListPenOps() throws {
        let rig = Rig()
        let base = Self.withDlAdvanceStub(try Self.baseRAM(bitmapA: false))
        for start in try Self.penStates(base) {
            var ram = Self.withDlAdvanceStub(start.1)
            rig.check("\(start.0) then op 1B", ram, 0x9B91, cycleOffset: 6) { #expect($0.opPen3() == 1) }
            for night in [false, true] {
                ram[0x083C] = night ? 0x04 : 0x01
                rig.check("\(start.0) then op 1C night=\(night)", ram, 0x9B9B, cycleOffset: 6) {
                    #expect($0.opDottedPen() == 1)
                }
            }
        }
        // Op 12 n for every n, with the display list inside a page and across a page boundary.
        for listAddress in [0x1F00, 0x1EFF] {
            for n in 0..<256 {
                var ram = base
                ram[0x8B] = UInt8(listAddress & 0xFF)
                ram[0x8C] = UInt8(listAddress >> 8)
                ram[listAddress] = 0x12
                ram[listAddress + 1] = UInt8(n)
                rig.check("op 12 \(n) at $\(String(listAddress, radix: 16))", ram, 0x9BE6, cycleOffset: 6) {
                    #expect($0.opPen() == 2)
                }
            }
        }
        rig.expectClean("display-list pen ops")
    }

    // MARK: Plot and lines

    @Test func plotEveryPen() throws {
        let rig = Rig()
        var rnd = TestRandom(seed: 0x9_9FD)
        for bitmapA in [false, true] {
            for start in try Self.penStates(try Self.baseRAM(bitmapA: bitmapA)) {
                for i in 0..<120 {
                    let x = i < 100 ? UInt8(rnd.next() % 160) : rnd.byte()
                    let row = UInt8(rnd.next() % 200)
                    var ram = start.1
                    ram[0xF3] = rnd.byte()
                    var regs = RoutineHarness.Registers()
                    let result = rig.check("\(start.0) A=\(bitmapA) plot \(x),\(row)", ram, 0x99FD, .init(x: x, y: row)) {
                        let r = $0.plot(x: x, row: row)
                        regs = .init(a: r.a, x: r.x, y: r.y)
                    }
                    #expect(result.registers.a == regs.a && result.registers.x == regs.x && result.registers.y == regs.y)
                }
            }
        }
        rig.expectClean("plot")
    }

    /// Line endpoints: random lines over the whole screen plus the special shapes.
    static func lineCases(_ rnd: inout TestRandom, count: Int) -> [(UInt8, UInt8, UInt8, UInt8)] {
        var lines: [(UInt8, UInt8, UInt8, UInt8)] = []
        func x() -> UInt8 { UInt8(rnd.next() % 160) }
        func y() -> UInt8 { UInt8(rnd.next() % 200) }
        func near(_ v: UInt8, _ limit: Int, _ r: Int) -> UInt8 {
            UInt8(min(max(Int(v) + Int(rnd.next() % UInt64(2 * r + 1)) - r, 0), limit - 1))
        }
        for i in 0..<count {
            switch i % 8 {
            case 0, 1, 2:                                        // anywhere
                lines.append((x(), y(), x(), y()))
            case 3:                                              // short, any octant
                let x1 = x(), y1 = y()
                lines.append((x1, y1, near(x1, 160, 6), near(y1, 200, 6)))
            case 4:                                              // horizontal
                let y1 = y()
                lines.append((x(), y1, x(), y1))
            case 5:                                              // vertical
                let x1 = x()
                lines.append((x1, y(), x1, y()))
            case 6:                                              // crossing x = 128
                lines.append((UInt8(96 + rnd.next() % 32), y(), UInt8(128 + rnd.next() % 32), y()))
            default:                                             // diagonals and near-diagonals
                let x1 = x(), y1 = y()
                let d = Int(rnd.next() % 60)
                let s: Int = rnd.next() & 1 == 0 ? 1 : -1
                let x2 = UInt8(min(max(Int(x1) + (rnd.next() & 1 == 0 ? d : -d), 0), 159))
                let y2 = UInt8(min(max(Int(y1) + s * (d + Int(rnd.next() % 3)) - 1, 0), 199))
                lines.append((x1, y1, x2, y2))
            }
        }
        // Edges, corners, single pixels and the full-screen extremes.
        let xs: [UInt8] = [0, 1, 3, 4, 127, 128, 131, 158, 159]
        let ys: [UInt8] = [0, 7, 8, 111, 112, 191, 199]
        for (i, x1) in xs.enumerated() {
            for (j, y1) in ys.enumerated() {
                lines.append((x1, y1, x1, y1))
                lines.append((x1, y1, xs[(i + 4) % xs.count], ys[(j + 3) % ys.count]))
            }
        }
        lines += [(0, 0, 159, 199), (159, 0, 0, 199), (0, 199, 159, 0), (0, 0, 159, 0), (0, 199, 0, 0),
                  (159, 111, 0, 111), (80, 0, 80, 199), (0, 100, 159, 101), (159, 100, 0, 99),
                  (5, 5, 6, 6), (6, 5, 5, 6), (10, 10, 11, 10), (10, 10, 10, 11)]
        return lines
    }

    @Test func linesEveryPenBothBuffers() throws {
        let rig = Rig()
        var rnd = TestRandom(seed: 0x9A1D)
        for bitmapA in [false, true] {
            for start in try Self.penStates(try Self.baseRAM(bitmapA: bitmapA)) {
                for (x1, y1, x2, y2) in Self.lineCases(&rnd, count: 240) {
                    var ram = start.1
                    ram[0xEB] = x1; ram[0xEC] = y1; ram[0xED] = x2; ram[0xEE] = y2
                    for a in [0x18, 0x19, 0xAF, 0xB2, 0xB3, 0xF3, 0xF4] { ram[a] = rnd.byte() }
                    rig.check("\(start.0) A=\(bitmapA) line \(x1),\(y1)-\(x2),\(y2)", ram, 0x9A1D) { $0.drawLine() }
                }
            }
        }
        rig.expectClean("drawLine")
    }

    /// Lines with x beyond the 160-pixel window (the routine does not clip; the turn coordinator
    /// draws on the panel in 2-pixel units) and lines drawn through the turn-coordinator XOR pen.
    @Test func linesWideCoordinates() throws {
        let rig = Rig()
        var rnd = TestRandom(seed: 0xA532)
        let base = try Self.baseRAM(bitmapA: true)
        let xor3 = Self.prepared(base, 0x9BF5, .init(a: 0x83))
        for _ in 0..<400 {
            var ram = xor3
            ram[0xEB] = rnd.byte(); ram[0xEC] = UInt8(rnd.next() % 200)
            ram[0xED] = rnd.byte(); ram[0xEE] = UInt8(rnd.next() % 200)
            rig.check("wide line \(ram[0xEB]),\(ram[0xEC])-\(ram[0xED]),\(ram[0xEE])", ram, 0x9A1D) { $0.drawLine() }
        }
        rig.expectClean("wide lines")
    }

    // MARK: Spans

    /// The span-color states: the captured (cold) operands and every pen via the original $9C9C.
    static func spanStates(_ base: [UInt8]) -> [(String, [UInt8])] {
        [("captured span color", base)]
            + (0..<4).map { ("span color \($0)", prepared(base, 0x9C9C, .init(x: UInt8($0)))) }
    }

    static func spanRAM(_ start: [UInt8], row: Int, x: UInt8) -> [UInt8] {
        var ram = start
        ram[0x8E] = ram[0x02C8 + row]
        ram[0x8F] = ram[0x0200 + row]
        ram[0x1E] = x
        return ram
    }

    @Test func spansEveryLengthAndPosition() throws {
        let rig = Rig()
        var rnd = TestRandom(seed: 0x9996)
        for bitmapA in [false, true] {
            for start in Self.spanStates(try Self.baseRAM(bitmapA: bitmapA)) {
                // Every right end with the boundary lengths.
                let row = Int(rnd.next() % 200)
                for x in 0..<160 {
                    for a in Set([0, min(x, 3), min(x, 22), min(x, 23), min(x, 24), x]) {
                        let ram = Self.spanRAM(start.1, row: row, x: UInt8(x))
                        rig.check("\(start.0) A=\(bitmapA) row \(row) span x=\(x) a=\(a)", ram, 0x9996, .init(a: UInt8(a))) {
                            $0.span(UInt8(a))
                        }
                    }
                }
                // Random short and long spans on random rows.
                for i in 0..<300 {
                    let row = Int(rnd.next() % 200)
                    let x = Int(rnd.next() % 160)
                    let a = i & 1 == 0 || x < 24 ? Int(rnd.next() % UInt64(min(x, 23) + 1))
                                                 : 24 + Int(rnd.next() % UInt64(x - 23))
                    var ram = Self.spanRAM(start.1, row: row, x: UInt8(x))
                    for z in [0x9A, 0x9B, 0xAF, 0xF3, 0xF5] { ram[z] = rnd.byte() }
                    rig.check("\(start.0) A=\(bitmapA) row \(row) span x=\(x) a=\(a)", ram, 0x9996, .init(a: UInt8(a))) {
                        $0.span(UInt8(a))
                    }
                }
            }
        }
        rig.expectClean("span")
    }

    /// $851B called the way the horizon fill uses it: whole rows, and halves cut by a return
    /// opcode planted on the first byte of a column's entry.
    @Test func unrolledRowFillAsHorizonUsesIt() throws {
        let rig = Rig()
        var rnd = TestRandom(seed: 0x851B)
        let base = try Self.baseRAM(bitmapA: false)
        for row in stride(from: 0, to: 200, by: 7) {
            let pattern = rnd.byte()
            var ram = base
            ram[0x8E] = ram[0x02C8 + row]; ram[0x8F] = ram[0x0200 + row]
            var y: UInt8 = 0
            var r = rig.check("whole row \(row)", ram, 0x851B, .init(a: pattern)) {
                y = $0.unrolledRowFill(entry: 0x851B, stop: 0x85BF, pattern: pattern)
            }
            #expect(r.registers.y == y)
            // Split at column c: run 0..<c with a return planted on c's entry, then c..<40 from it.
            let c = Int(rnd.next() % 39) + 1
            let ldy = 0x851B + 4 * c + (c >= 32 ? 2 : 0)
            var cut = ram
            cut[ldy] = 0x60
            r = rig.check("row \(row) columns 0..<\(c)", cut, 0x851B, .init(a: pattern)) {
                y = $0.unrolledRowFill(entry: 0x851B, stop: ldy, pattern: pattern)
            }
            #expect(r.registers.y == y)
            r = rig.check("row \(row) columns \(c)..<40", ram, UInt16(ldy), .init(a: pattern)) {
                y = $0.unrolledRowFill(entry: ldy, stop: 0x85BF, pattern: pattern)
            }
            #expect(r.registers.y == y)
        }
        rig.expectClean("unrolled row fill")
    }

    // MARK: Text

    @Test func clearWindow() throws {
        let rig = Rig()
        rig.check("clearWindow", try Self.baseRAM(bitmapA: false), 0x1EAF) { $0.clearWindow() }
        rig.expectClean("clearWindow")
    }

    /// A random text record: row, x, characters (mostly the font's $20-$5A, some $5B-$9F past it), and a
    /// terminator (0, a control code, or a byte >= $A0).
    static func randomRecord(_ rnd: inout TestRandom) -> [UInt8] {
        var bytes = [UInt8(rnd.next() % 196), rnd.next() % 4 == 0 ? rnd.byte() : UInt8(rnd.next() % 150)]
        for _ in 0..<Int(rnd.next() % 11) {
            bytes.append(rnd.next() % 10 == 0 ? UInt8(0x5B + rnd.next() % 0x45) : UInt8(0x20 + rnd.next() % 0x3B))
        }
        switch rnd.next() % 4 {
        case 0: bytes.append(UInt8(rnd.next() % 0x20))
        case 1: bytes.append(0xA0 + UInt8(rnd.next() % 0x60))
        default: bytes.append(0)
        }
        return bytes
    }

    @Test func textRecords() throws {
        let rig = Rig()
        var rnd = TestRandom(seed: 0x1DDE)
        for bitmapA in [false, true] {
            let base = try Self.baseRAM(bitmapA: bitmapA)
            for i in 0..<300 {
                let record = Self.randomRecord(&rnd)
                // Some records straddle a page boundary ($C0 wraps).
                let at = i % 5 == 0 ? 0x1F00 - Int(rnd.next() % UInt64(record.count)) : 0x1F00 + Int(rnd.next() % 64)
                var ram = base
                for (k, b) in record.enumerated() { ram[at + k] = b }
                let lo = UInt8(at & 0xFF), hi = UInt8(at >> 8)
                var carry = false
                let r = rig.check("A=\(bitmapA) record \(record) at $\(String(at, radix: 16))", ram, 0x1DDE, .init(a: lo, x: hi)) {
                    carry = $0.drawTextRecord(UInt16(at))
                }
                #expect(r.registers.carry == carry, "carry after record \(record)")
            }
        }
        rig.expectClean("drawTextRecord")
    }

    @Test func textRecordInnerEntries() throws {
        let rig = Rig()
        var rnd = TestRandom(seed: 0x1E01)
        let base = try Self.baseRAM(bitmapA: true)
        for _ in 0..<200 {
            let record = Self.randomRecord(&rnd)
            var ram = base
            for (k, b) in record.enumerated() { ram[0x1F40 + k] = b }
            ram[0xC0] = 0x40; ram[0xC1] = 0x1F
            var carry = false
            var r = rig.check("$1DE2 record \(record)", ram, 0x1DE2) { carry = $0.drawTextRecordAt() }
            #expect(r.registers.carry == carry, "carry after record \(record)")
            // $1E01: glyph A at ($C3, $C2), then the rest of the record (its characters only).
            let index = UInt8(rnd.next() % 0x60)
            ram[0xC2] = UInt8(rnd.next() % 196); ram[0xC3] = rnd.byte()
            ram[0xC0] = 0x42
            r = rig.check("$1E01 glyph \(index) then \(record.dropFirst(2))", ram, 0x1E01, .init(a: index)) {
                carry = $0.drawGlyph(index)
            }
            #expect(r.registers.carry == carry, "carry after glyph \(index), \(record.dropFirst(2))")
        }
        rig.expectClean("text inner entries")
    }

    @Test func textLists() throws {
        let rig = Rig()
        var rnd = TestRandom(seed: 0x1E99)
        for bitmapA in [false, true] {
            let base = try Self.baseRAM(bitmapA: bitmapA)
            for _ in 0..<60 {
                var list: [UInt8] = []
                for _ in 0..<Int(rnd.next() % 5) {
                    var record = Self.randomRecord(&rnd)
                    if rnd.next() % 6 == 0 { record[0] = 0 }   // row 0 with x != 0 is a record, not the end
                    if record[0] == 0 && record[1] == 0 { record[1] = 1 }
                    list += record
                }
                list += [0, 0]
                let at = 0x1F00 - Int(rnd.next() % 8)
                var ram = base
                for (k, b) in list.enumerated() { ram[at + k] = b }
                rig.check("A=\(bitmapA) list \(list)", ram, 0x1E99, .init(a: UInt8(at & 0xFF), x: UInt8(at >> 8))) {
                    $0.drawTextList(UInt16(at))
                }
            }
        }
        rig.expectClean("drawTextList")
    }

    @Test func signedNumbers() throws {
        let rig = Rig()
        var rnd = TestRandom(seed: 0x1D54)
        var values: [Int16] = [0, 1, -1, 9, 10, -10, 99, 100, 999, 1000, 9999, 10000, -10000, 12345, -12345,
                               19999, 20000, 29999, 30000, 32767, -32767, -32768, -9999, -1000, -100, 5, -5]
        for _ in 0..<200 { values.append(Int16(bitPattern: UInt16(truncatingIfNeeded: rnd.next()))) }
        for bitmapA in [false, true] {
            let base = try Self.baseRAM(bitmapA: bitmapA)
            for value in values {
                // Records inside a page, at a page end (record + 2 carries) and straddling one.
                for at in [0x1F10, 0x1EFE, 0x1EFB] {
                    var ram = base
                    ram[at] = UInt8(rnd.next() % 196)
                    ram[at + 1] = UInt8(rnd.next() % 136)
                    for k in 2..<8 { ram[at + k] = rnd.byte() }
                    ram[at + 8] = 0
                    ram[0xB8] = UInt8(truncatingIfNeeded: value)
                    ram[0xB9] = UInt8(truncatingIfNeeded: value >> 8)
                    var carry = false
                    let r = rig.check("A=\(bitmapA) print \(value) at $\(String(at, radix: 16))", ram, 0x1D54,
                                      .init(a: UInt8(at & 0xFF), x: UInt8(at >> 8))) {
                        carry = $0.printSigned5(record: UInt16(at))
                    }
                    #expect(r.registers.carry == carry)
                }
            }
        }
        rig.expectClean("printSigned5")
    }

    // MARK: Exhaustive sweeps

    /// Every short line (|dx|, |dy| < 10) from every start pixel (x & 3) and every row within a
    /// character cell (row & 7), in a random direction and endpoint order, on both sides of the
    /// x = 128 step and across the window/panel boundary (rows 104-120), with the pen state
    /// rotating through every state and both buffers: every Bresenham error pattern of the small
    /// slopes at every byte and character-cell alignment.
    @Test func shortLinesEveryPhase() throws {
        let rig = Rig()
        var rnd = TestRandom(seed: 0x5107)
        let states = try Self.penStates(try Self.baseRAM(bitmapA: false))
            + Self.penStates(try Self.baseRAM(bitmapA: true))
        var k = 0
        for xBase in [36, 128] {
            for phase in 0..<4 {
                for rowPhase in 0..<8 {
                    for dx in 0..<10 {
                        for dy in 0..<10 {
                            let xr = UInt8(xBase + phase), yr = UInt8(104 + rowPhase)
                            let xl = xr - UInt8(dx)
                            let yo = rnd.next() & 1 == 0 ? yr - UInt8(dy) : yr + UInt8(dy)
                            let (x1, y1, x2, y2) = rnd.next() & 1 == 0 ? (xr, yr, xl, yo) : (xl, yo, xr, yr)
                            let start = states[k % states.count]
                            k += 1
                            var ram = start.1
                            ram[0xEB] = x1; ram[0xEC] = y1; ram[0xED] = x2; ram[0xEE] = y2
                            ram[0xAF] = rnd.byte(); ram[0xF3] = rnd.byte(); ram[0xF4] = rnd.byte()
                            rig.check("\(start.0) line \(x1),\(y1)-\(x2),\(y2)", ram, 0x9A1D) { $0.drawLine() }
                        }
                    }
                }
            }
        }
        rig.expectClean("short lines")
    }

    /// Every span (x, length) in the window: x 0-159 and every A from 0 to x, on random rows, with
    /// the span color rotating through the captured state and pens 0-3, on both buffers. This runs
    /// every long-span entry/stop pair of the unrolled filler.
    @Test func spansExhaustive() throws {
        let rig = Rig()
        var rnd = TestRandom(seed: 0x9910)
        let states = Self.spanStates(try Self.baseRAM(bitmapA: false))
            + Self.spanStates(try Self.baseRAM(bitmapA: true))
        var k = 0
        for x in 0..<160 {
            for a in 0...x {
                let start = states[k % states.count]
                k += 1
                let row = Int(rnd.next() % 200)
                var ram = Self.spanRAM(start.1, row: row, x: UInt8(x))
                ram[0xAF] = rnd.byte(); ram[0xF5] = rnd.byte(); ram[0x9A] = rnd.byte(); ram[0x9B] = rnd.byte()
                rig.check("\(start.0) row \(row) span x=\(x) a=\(a)", ram, 0x9996, .init(a: UInt8(a))) {
                    $0.span(UInt8(a))
                }
            }
        }
        rig.expectClean("all spans")
    }

    /// `plot` at every x 0-255 on rows at character-cell, page-cross and window/panel edges, with
    /// the returned registers.
    @Test func plotEveryColumn() throws {
        let rig = Rig()
        var rnd = TestRandom(seed: 0x800C)
        let states = try Self.penStates(try Self.baseRAM(bitmapA: false))
            + Self.penStates(try Self.baseRAM(bitmapA: true))
        var k = 0
        var badRegisters = 0
        for row: UInt8 in [0, 7, 8, 31, 55, 56, 57, 111, 112, 150, 199] {
            for x in 0..<256 {
                let start = states[k % states.count]
                k += 1
                var ram = start.1
                ram[0xF3] = rnd.byte(); ram[0xAF] = rnd.byte()
                var regs = RoutineHarness.Registers()
                let r = rig.check("\(start.0) plot \(x),\(row)", ram, 0x99FD, .init(x: UInt8(x), y: row)) {
                    let p = $0.plot(x: UInt8(x), row: row)
                    regs = .init(a: p.a, x: p.x, y: p.y)
                }
                if r.registers.a != regs.a || r.registers.x != regs.x || r.registers.y != regs.y { badRegisters += 1 }
            }
        }
        #expect(badRegisters == 0)
        rig.expectClean("plot every column")
    }

    /// Every glyph index $00-$7F (the 59 font glyphs and the code bytes past them) at every x & 3
    /// phase, through the $1E01 entry with a one-byte rest of record (a random terminator).
    @Test func everyGlyphEveryPhase() throws {
        let rig = Rig()
        var rnd = TestRandom(seed: 0x1634)
        let bases = [try Self.baseRAM(bitmapA: false), try Self.baseRAM(bitmapA: true)]
        for index in 0..<0x80 {
            for phase in 0..<4 {
                var ram = bases[(index + phase) & 1]
                ram[0xC2] = UInt8(rnd.next() % 196)
                ram[0xC3] = UInt8(phase) | UInt8(rnd.next() % 64) << 2
                ram[0x1F40] = rnd.next() & 1 == 0 ? UInt8(rnd.next() % 0x20) : 0xA0 | rnd.byte()
                ram[0xC0] = 0x40; ram[0xC1] = 0x1F
                var carry = false
                let r = rig.check("glyph \(index) at \(ram[0xC3]),\(ram[0xC2])", ram, 0x1E01, .init(a: UInt8(index))) {
                    carry = $0.drawGlyph(UInt8(index))
                }
                #expect(r.registers.carry == carry)
            }
        }
        rig.expectClean("every glyph")
    }

    /// `printSigned5` at every digit boundary: m·10^n - 1, m·10^n and m·10^n + 1 for every leading
    /// digit m, positive and negative, and the 16-bit edges.
    @Test func signedNumberDigitBoundaries() throws {
        let rig = Rig()
        var rnd = TestRandom(seed: 0x1DBB)
        var values: Set<Int> = [0x7FFF, -0x8000, -0x7FFF, 0xFF, 0x100, 0x101, -0xFF, -0x100, -0x101, 0x7F00, -0x7F00]
        for p in [1, 10, 100, 1000, 10000] {
            for m in 1...9 where m * p <= 32767 {
                for d in -1...1 {
                    let v = m * p + d
                    if v <= 32767 { values.insert(v); values.insert(-v) }
                }
            }
        }
        let base = try Self.baseRAM(bitmapA: true)
        for value in values.sorted() {
            let at = [0x1F10, 0x1EFE, 0x1EFB][Int(rnd.next() % 3)]
            var ram = base
            ram[at] = UInt8(rnd.next() % 196)
            ram[at + 1] = UInt8(rnd.next() % 136)
            ram[at + 8] = 0
            ram[0xB8] = UInt8(truncatingIfNeeded: value)
            ram[0xB9] = UInt8(truncatingIfNeeded: value >> 8)
            rig.check("print \(value) at $\(String(at, radix: 16))", ram, 0x1D54, .init(a: UInt8(at & 0xFF), x: UInt8(at >> 8))) {
                $0.printSigned5(record: UInt16(at))
            }
        }
        rig.expectClean("printSigned5 digit boundaries")
    }

    // MARK: Pens decoded from arbitrary patched bytes

    /// The port draws with whatever the code bytes say. Patch every pixel-write site (plot, the
    /// four line loops, the dotted op and the three span sites) with random set/mask/toggle pixel
    /// ops and random mask-table operands — a third of them ending a page, so the indexed reads
    /// cross it — with the dotted-line call in some cases (also on the plot site, which the
    /// original never does), and draw lines, plots and spans with them.
    @Test func arbitraryPatchedPixelOps() throws {
        let rig = Rig()
        var rnd = TestRandom(seed: 0x05E1F)
        let bases = [try Self.baseRAM(bitmapA: false), try Self.baseRAM(bitmapA: true)]
        let kinds: [UInt8] = [0x1D, 0x3D, 0x5D]
        // Mask tables in $1000-$3EFF: memory these routines never write.
        func patch(_ ram: inout [UInt8], _ at: Int) {
            ram[at] = kinds[Int(rnd.next() % 3)]
            ram[at + 1] = rnd.next() % 3 == 0 ? 0xFD + UInt8(rnd.next() % 3) : rnd.byte()
            ram[at + 2] = 0x10 + UInt8(rnd.next() % 0x2F)
        }
        func jsrDotted(_ ram: inout [UInt8], _ op2: Int) {
            ram[op2] = 0x20; ram[op2 + 1] = 0x80; ram[op2 + 2] = 0x9B
        }
        for i in 0..<1500 {
            var ram = bases[i & 1]
            for site in PixelSite.allCases {
                patch(&ram, site.rawValue)
                patch(&ram, site.rawValue + 3)
            }
            patch(&ram, PixelSite.dottedOp)
            if i % 3 == 0 {
                for site in [PixelSite.lineYMajorUp, .lineYMajorDown, .lineXMajorUp, .lineXMajorDown] {
                    jsrDotted(&ram, site.rawValue + 3)
                }
            }
            if i % 5 == 0 { jsrDotted(&ram, PixelSite.plot.rawValue + 3) }
            ram[0xF3] = rnd.byte(); ram[0xAF] = rnd.byte()
            switch i % 3 {
            case 0, 1:
                let x1 = rnd.byte(), y1 = UInt8(rnd.next() % 200)
                let short = rnd.next() & 1 == 0
                let x2 = short ? x1 &+ UInt8(rnd.next() % 13) &- 6 : rnd.byte()
                let y2 = short ? UInt8(min(max(Int(y1) + Int(rnd.next() % 13) - 6, 0), 199)) : UInt8(rnd.next() % 200)
                ram[0xEB] = x1; ram[0xEC] = y1; ram[0xED] = x2; ram[0xEE] = y2
                rig.check("ops #\(i) line \(x1),\(y1)-\(x2),\(y2)", ram, 0x9A1D) { $0.drawLine() }
                let px = rnd.byte(), py = UInt8(rnd.next() % 200)
                rig.check("ops #\(i) plot \(px),\(py)", ram, 0x99FD, .init(x: px, y: py)) { $0.plot(x: px, row: py) }
            default:
                let x = Int(rnd.next() % 160), row = Int(rnd.next() % 200)
                let a = Int(rnd.next() % UInt64(x + 1))
                ram = Self.spanRAM(ram, row: row, x: UInt8(x))
                ram[0x1A] = rnd.byte()
                rig.check("ops #\(i) span x=\(x) a=\(a) row \(row)", ram, 0x9996, .init(a: UInt8(a))) { $0.span(UInt8(a)) }
            }
        }
        rig.expectClean("arbitrary patched ops")
    }

    // MARK: Operation sequences

    /// Random sequences of pen ops, span colors, plots, lines, spans, text records and numbers on
    /// one evolving RAM (each step starts from the original's RAM after the previous one), so every
    /// routine also runs from the states the others leave behind — the dotted patch and its $AF,
    /// a pen change after dotted mode, the planted-and-restored filler, the text temporaries.
    @Test func randomOperationSequences() throws {
        let rig = Rig()
        var rnd = TestRandom(seed: 0x5E0)
        for seq in 0..<24 {
            var ram = Self.withDlAdvanceStub(try Self.baseRAM(bitmapA: seq & 1 == 1))
            for step in 0..<100 {
                let label = "seq \(seq) step \(step)"
                switch rnd.next() % 14 {
                case 0:
                    let pen: UInt8 = [0, 1, 2, 3, 0x80, 0x81, 0x82, 0x83][Int(rnd.next() % 8)]
                    rig.check("\(label) setPen \(pen)", ram, 0x9BF5, .init(a: pen)) { $0.setPen(pen) }
                case 1:
                    ram[0x083C] = rnd.byte()
                    rig.check("\(label) op 1C", ram, 0x9B9B, cycleOffset: 6) { _ = $0.opDottedPen() }
                case 2:
                    rig.check("\(label) op 1B", ram, 0x9B91, cycleOffset: 6) { _ = $0.opPen3() }
                case 3:
                    ram[0x8B] = 0x80; ram[0x8C] = 0x1F; ram[0x1F80] = 0x12; ram[0x1F81] = UInt8(rnd.next() % 16)
                    rig.check("\(label) op 12 \(ram[0x1F81])", ram, 0x9BE6, cycleOffset: 6) { _ = $0.opPen() }
                case 4:
                    let x = UInt8(rnd.next() % 4)
                    rig.check("\(label) setSpanColor \(x)", ram, 0x9C9C, .init(x: x)) { $0.setSpanColor(x) }
                case 5:
                    ram[0x0876] = rnd.byte()
                    rig.check("\(label) setSpanColorFromPalette", ram, 0x9C93) { $0.setSpanColorFromPalette() }
                case 6:
                    let x = UInt8(rnd.next() % 160), y = UInt8(rnd.next() % 200)
                    rig.check("\(label) plot \(x),\(y)", ram, 0x99FD, .init(x: x, y: y)) { $0.plot(x: x, row: y) }
                case 7, 8, 9:
                    let x1 = UInt8(rnd.next() % 160), y1 = UInt8(rnd.next() % 200)
                    let x2 = UInt8(rnd.next() % 160), y2 = UInt8(rnd.next() % 200)
                    ram[0xEB] = x1; ram[0xEC] = y1; ram[0xED] = x2; ram[0xEE] = y2
                    rig.check("\(label) line \(x1),\(y1)-\(x2),\(y2)", ram, 0x9A1D) { $0.drawLine() }
                case 10, 11:
                    let x = Int(rnd.next() % 160), row = Int(rnd.next() % 200)
                    let a = UInt8(rnd.next() % UInt64(x + 1))
                    ram = Self.spanRAM(ram, row: row, x: UInt8(x))
                    rig.check("\(label) span x=\(x) a=\(a) row \(row)", ram, 0x9996, .init(a: a)) { $0.span(a) }
                case 12:
                    let record = Self.randomRecord(&rnd)
                    for (k, b) in record.enumerated() { ram[0x1F00 + k] = b }
                    rig.check("\(label) record \(record)", ram, 0x1DDE, .init(a: 0x00, x: 0x1F)) { $0.drawTextRecord(0x1F00) }
                default:
                    ram[0x1F40] = UInt8(rnd.next() % 196); ram[0x1F41] = UInt8(rnd.next() % 136); ram[0x1F48] = 0
                    ram[0xB8] = rnd.byte(); ram[0xB9] = rnd.byte()
                    rig.check("\(label) print", ram, 0x1D54, .init(a: 0x40, x: 0x1F)) { $0.printSigned5(record: 0x1F40) }
                }
                ram = rig.lastOriginalRAM
            }
        }
        rig.expectClean("operation sequences")
    }

    // MARK: Explicit pen state

    @Test func sitePenDecodesThePatchedBytes() throws {
        let states = try Self.penStates(try Self.baseRAM(bitmapA: false))
        func pen(_ name: String) -> SitePen {
            let m = Machine(memory: states.first { $0.0 == name }!.1)
            return m.sitePen(.lineXMajorUp)
        }
        #expect(pen("pen $01") == SitePen(first: .init(kind: .or, table: 0x157A), second: .init(kind: .and, table: 0x1586), dotted: false))
        #expect(pen("pen $83") == SitePen(first: .init(kind: .xor, table: 0x157A), second: .init(kind: .xor, table: 0x157E), dotted: false))
        #expect(pen("pen $80") == SitePen(first: .init(kind: .xor, table: 0x1582), second: .init(kind: .xor, table: 0x1586), dotted: false))
        #expect(pen("dotted") == SitePen(first: .init(kind: .or, table: 0x157A), second: .init(kind: .and, table: 0x1586), dotted: true))
        let dotted = Machine(memory: states.first { $0.0 == "dotted" }!.1)
        #expect(!dotted.sitePen(.plot).dotted)
    }
}
