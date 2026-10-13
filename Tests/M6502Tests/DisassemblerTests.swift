import Foundation
import M6502
import Testing

/// Disassembles `bytes` placed at `pc` (unmapped addresses read as 0).
private func dis(_ bytes: [UInt8], at pc: UInt16 = 0x2000, labels: [UInt16: String] = [:]) -> (text: String, length: Int) {
    Disassembler().line(at: pc, read: { a in
        let i = Int(a &- pc)
        return i < bytes.count ? bytes[i] : 0
    }, labels: { labels[$0] })
}

@Suite struct DisassemblerFormatting {
    @Test func everyAddressingMode() {
        #expect(dis([0xEA]) == ("nop", 1))                               // implied
        #expect(dis([0x0A]) == ("asl a", 1))                             // accumulator
        #expect(dis([0xA9, 0x12]) == ("lda #$12", 2))                    // immediate
        #expect(dis([0xA5, 0x4A]) == ("lda $4A", 2))                     // zero page
        #expect(dis([0xB5, 0x4A]) == ("lda $4A,x", 2))                   // zero page,x
        #expect(dis([0xB6, 0x4A]) == ("ldx $4A,y", 2))                   // zero page,y
        #expect(dis([0xA1, 0x8E]) == ("lda ($8E,x)", 2))                 // (zp,x)
        #expect(dis([0xB1, 0x8E]) == ("lda ($8E),y", 2))                 // (zp),y
        #expect(dis([0xD0, 0x05]) == ("bne $2007", 2))                   // relative
        #expect(dis([0xAD, 0x4C, 0x0A]) == ("lda $0A4C", 3))             // absolute
        #expect(dis([0xBD, 0x4C, 0x0A]) == ("lda $0A4C,x", 3))           // absolute,x
        #expect(dis([0x99, 0x00, 0x04]) == ("sta $0400,y", 3))           // absolute,y
        #expect(dis([0x6C, 0xFE, 0xFF]) == ("jmp ($FFFE)", 3))           // indirect
    }

    @Test func absoluteOperandBelowPageOneKeepsItsMode() {
        // ca65 would otherwise assemble zero-page addressing; `a:` forces the absolute form.
        #expect(dis([0xAD, 0x12, 0x00]) == ("lda a:$0012", 3))
        #expect(dis([0x9D, 0x00, 0x00]) == ("sta a:$0000,x", 3))
        // ...also when the operand is named (it would otherwise read like `lda irqPhase,x` = B5 4A).
        let names: [UInt16: String] = [0x004A: "irqPhase", 0x00FC: "selectedItem"]
        #expect(dis([0xBD, 0x4A, 0x00], labels: names) == ("lda a:irqPhase,x", 3))
        #expect(dis([0xBE, 0xFC, 0x00], labels: names) == ("ldx a:selectedItem,y", 3))
        #expect(dis([0xB5, 0x4A], labels: names) == ("lda irqPhase,x", 2))
        #expect(dis([0x6C, 0x4A, 0x00], labels: names).text == "jmp (irqPhase)")   // JMP (ind) has no zero-page form
    }

    @Test func everyDocumentedOpcodeReassemblesToItsBytes() {
        // The text alone must identify the instruction: re-assembling it with ca65's mode choice
        // gives back the same bytes, with and without names, for operands above and below $0100.
        let names: [String: UInt16] = ["zpVar": 0x0034, "absVar": 0x1234, "loop": 0x2036]
        let labels = Dictionary(uniqueKeysWithValues: names.map { ($0.value, $0.key) })
        for op in 0...255 where Opcodes.table[op].documented {
            for bytes: [UInt8] in [[UInt8(op), 0x34, 0x12], [UInt8(op), 0x34, 0x00]] {
                for named in [false, true] {
                    let r = dis(bytes, at: 0x2000, labels: named ? labels : [:])
                    #expect(reassemble(r.text, at: 0x2000, names: names) == Array(bytes.prefix(r.length)),
                            "opcode $\(Disassembler.hex2(UInt8(op))): \(r.text)")
                }
            }
        }
    }

    @Test func labelsReplaceOperands() {
        let names: [UInt16: String] = [0x9A1D: "drawLine", 0x004A: "irqPhase", 0x0A4D: "airspeed+1", 0x2010: "loop", 0xFFFE: "irqVector"]
        #expect(dis([0x20, 0x1D, 0x9A], labels: names).text == "jsr drawLine")
        #expect(dis([0x46, 0x4A], labels: names).text == "lsr irqPhase")
        #expect(dis([0xBD, 0x4D, 0x0A], labels: names).text == "lda airspeed+1,x")
        #expect(dis([0xF0, 0x0E], labels: names).text == "beq loop")
        #expect(dis([0x6C, 0xFE, 0xFF], labels: names).text == "jmp (irqVector)")
        #expect(dis([0xA9, 0x4A], labels: names).text == "lda #$4A")   // immediates are never named
    }

    @Test func branchTargets() {
        #expect(dis([0xD0, 0xFE], at: 0x1000).text == "bne $1000")       // branch to itself
        #expect(dis([0x10, 0x80], at: 0x1000).text == "bpl $0F82")       // most negative offset
        #expect(dis([0x30, 0x7F], at: 0x1000).text == "bmi $1081")       // most positive offset
        #expect(dis([0xF0, 0x20], at: 0xFFF0).text == "beq $0012")       // wraps past $FFFF
        let d = Disassembler().decode(at: 0x22CB, read: { [0x22CB: 0xF0, 0x22CC: 0x3D][$0] ?? 0 })
        #expect(d.target == 0x230A && d.isControlTransfer && !d.endsFlow)
    }

    @Test func undocumentedOpcodesRenderAsBytes() {
        for op in 0...255 where !Opcodes.table[op].documented {
            let r = dis([UInt8(op), 0x34, 0x12])
            #expect(r.text == ".byte $" + Disassembler.hex2(UInt8(op)))
            #expect(r.length == 1)
        }
        #expect(Opcodes.table.filter(\.documented).count == 151)
        #expect(Disassembler().decode(at: 0, read: { _ in 0x02 }).target == nil)
    }

    @Test func lengthsFollowTheOpcodeTable() {
        for op in 0...255 where Opcodes.table[op].documented {
            let r = dis([UInt8(op), 0x34, 0x12])
            #expect(r.length == Opcodes.table[op].length, "opcode \(op)")
            #expect(r.text.hasPrefix(Opcodes.table[op].mnemonic.lowercased()), "opcode \(op)")
        }
    }

    @Test func flowClassification() {
        let read = { (bytes: [UInt8]) in { (a: UInt16) -> UInt8 in Int(a) < bytes.count ? bytes[Int(a)] : 0 } }
        let jmp = Disassembler().decode(at: 0, read: read([0x4C, 0x4B, 0x20]))
        #expect(jmp.endsFlow && jmp.isControlTransfer && jmp.target == 0x204B)
        let jsr = Disassembler().decode(at: 0, read: read([0x20, 0x30, 0x23]))
        #expect(!jsr.endsFlow && jsr.isControlTransfer && jsr.target == 0x2330)
        let rts = Disassembler().decode(at: 0, read: read([0x60]))
        #expect(rts.endsFlow && !rts.isControlTransfer && rts.target == nil)
        let lda = Disassembler().decode(at: 0, read: read([0xB9, 0x00, 0x02]))
        #expect(!lda.isControlTransfer && lda.target == 0x0200)
        // jmp (ind): the target is the pointer (often a self-modified operand), not code.
        let ind = Disassembler().decode(at: 0, read: read([0x6C, 0xFF, 0x27]))
        #expect(ind.endsFlow && !ind.isControlTransfer && ind.target == 0x27FF)
    }
}

/// Assembles one disassembled line back to bytes, choosing modes as ca65 does: `a:` or a value
/// above $FF means absolute, otherwise zero page when the mnemonic has a zero-page form.
private func reassemble(_ text: String, at pc: UInt16, names: [String: UInt16]) -> [UInt8]? {
    let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
    let mnemonic = parts[0].uppercased()
    func opcode(_ mode: AddressingMode) -> UInt8? {
        (0...255).first { Opcodes.table[$0].documented && Opcodes.table[$0].mnemonic == mnemonic && Opcodes.table[$0].mode == mode }
            .map { UInt8($0) }
    }
    func value(_ s: Substring) -> (value: UInt16, forcedAbsolute: Bool)? {
        let forced = s.hasPrefix("a:")
        let e = forced ? s.dropFirst(2) : s
        if e.hasPrefix("$") { return UInt16(e.dropFirst(), radix: 16).map { ($0, forced) } }
        return names[String(e)].map { ($0, forced) }
    }
    func encode(_ mode: AddressingMode, _ v: UInt16) -> [UInt8]? {
        guard let op = opcode(mode) else { return nil }
        switch mode.length {
        case 2: return v < 0x100 ? [op, UInt8(v)] : nil
        default: return [op, UInt8(v & 0xFF), UInt8(v >> 8)]
        }
    }
    guard parts.count == 2 else { return opcode(.implied).map { [$0] } }
    let arg = Substring(parts[1])
    if arg == "a" { return opcode(.accumulator).map { [$0] } }
    if arg.hasPrefix("#$") { return UInt8(arg.dropFirst(2), radix: 16).flatMap { v in opcode(.immediate).map { [$0, v] } } }
    if arg.hasPrefix("("), arg.hasSuffix(",x)") { return value(arg.dropFirst().dropLast(3)).flatMap { encode(.indexedIndirect, $0.value) } }
    if arg.hasPrefix("("), arg.hasSuffix("),y") { return value(arg.dropFirst().dropLast(3)).flatMap { encode(.indirectIndexed, $0.value) } }
    if arg.hasPrefix("("), arg.hasSuffix(")") { return value(arg.dropFirst().dropLast()).flatMap { encode(.indirect, $0.value) } }
    var base = arg, index = ""
    if arg.hasSuffix(",x") || arg.hasSuffix(",y") { base = arg.dropLast(2); index = String(arg.suffix(1)) }
    guard let operand = value(base) else { return nil }
    let v = operand.value, forced = operand.forcedAbsolute
    if index.isEmpty, let op = opcode(.relative) {
        let offset = Int(v) - Int(pc &+ 2)
        return (-128...127).contains(offset) ? [op, UInt8(bitPattern: Int8(offset))] : nil
    }
    let (zp, abs): (AddressingMode, AddressingMode) = index == "x" ? (.zeroPageX, .absoluteX) : index == "y" ? (.zeroPageY, .absoluteY) : (.zeroPage, .absolute)
    if !forced, v < 0x100, opcode(zp) != nil { return encode(zp, v) }
    return encode(abs, v)
}

/// re/symbols.json must load and be self-consistent. This mirrors the core of `fs2lab symbols-check`
/// (FS2LabKit's `SymbolDatabase.validate`) without depending on the lab target.
@Suite struct SymbolDatabaseFile {
    static let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("re/symbols.json")

    static func load() throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func address(_ v: Any?) -> Int? {
        guard let s = v as? String, s.count == 5, s.first == "$",
              s.dropFirst().allSatisfy({ "0123456789ABCDEF".contains($0) }) else { return nil }
        return Int(s.dropFirst(), radix: 16)
    }

    static func isName(_ s: String) -> Bool {
        guard let f = s.first, f.isLowercase, f.isASCII else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    @Test func loadsWithTheExpectedShape() throws {
        let db = try Self.load()
        #expect(db["schemaVersion"] as? Int == 1)
        for key in ["regions", "variables", "routines", "tables"] {
            let list = try #require(db[key] as? [[String: Any]], "\(key)")
            #expect(!list.isEmpty, "\(key)")
        }
        let total = ["regions", "variables", "routines", "tables"].map { (db[$0] as? [Any])?.count ?? 0 }.reduce(0, +)
        #expect(total > 300)
    }

    @Test func addressesNamesAndKindsAreWellFormed() throws {
        let db = try Self.load()
        let kinds: Set<String> = ["code", "data", "table", "text", "asset", "buffer", "free", "residue", "crack", "loader", "protection"]
        let types: Set<String> = ["u8", "s8", "u16", "s16", "u24", "s24", "u32", "s32", "bcd", "ascii", "ptr", "bytes"]
        let overlays: Set<String> = ["coldStart", "editor", "war", "flight", "databaseInfo"]
        for (key, fields) in [("regions", ["start", "end"]), ("variables", ["addr"]), ("routines", ["addr"]), ("tables", ["addr"]), ("notes", ["addr"])] {
            for e in db[key] as? [[String: Any]] ?? [] {
                let what = "\(key) \(e["name"] ?? e["text"] ?? "?")"
                for f in fields { #expect(Self.address(e[f]) != nil, "\(what).\(f) = \(e[f] ?? "nil")") }
                if let o = e["overlay"], !(o is NSNull) { #expect(overlays.contains(o as? String ?? ""), "\(what) overlay") }
                if key != "notes" { #expect(Self.isName(e["name"] as? String ?? ""), "\(what) name") }
                if key == "regions" { #expect(kinds.contains(e["kind"] as? String ?? ""), "\(what) kind") }
                if key == "variables" { #expect(types.contains(e["type"] as? String ?? ""), "\(what) type") }
            }
        }
    }

    @Test func regionsDoNotOverlapWithinAnOverlay() throws {
        let db = try Self.load()
        var byOverlay: [String: [(ClosedRange<Int>, String)]] = [:]
        var names: [String: Set<String>] = [:]
        for r in db["regions"] as? [[String: Any]] ?? [] {
            let o = r["overlay"] as? String ?? "resident", name = r["name"] as? String ?? "?"
            #expect(names[o, default: []].insert(name).inserted, "duplicate region name \(name) in \(o)")
            guard let s = Self.address(r["start"]), let e = Self.address(r["end"]) else { continue }
            #expect(s <= e, "region \(name)")
            byOverlay[o, default: []].append((s...max(s, e), name))
        }
        for (o, list) in byOverlay {
            let sorted = list.sorted { $0.0.lowerBound < $1.0.lowerBound }
            for (a, b) in zip(sorted, sorted.dropFirst()) {
                #expect(b.0.lowerBound > a.0.upperBound, "regions \(a.1) and \(b.1) overlap in \(o)")
            }
        }
    }

    @Test func labelNamesAreUniquePerOverlay() throws {
        let db = try Self.load()
        var seen: [String: [String: String]] = [:]
        for key in ["variables", "routines", "tables"] {
            for e in db[key] as? [[String: Any]] ?? [] {
                let o = e["overlay"] as? String ?? "resident", name = e["name"] as? String ?? "?"
                #expect(seen[o]?[name] == nil, "duplicate name \(name) in \(o)")
                seen[o, default: [:]][name] = e["addr"] as? String
            }
        }
        let resident = seen["resident"] ?? [:]
        for (o, list) in seen where o != "resident" {
            for name in list.keys { #expect(resident[name] == nil, "\(o) name \(name) shadows a resident name") }
        }
    }

    @Test func sizesPlacementAndNestingAreConsistent() throws {
        // The rest of validate()'s errors: fixed-size types, overlay entries inside the $A7E0
        // window, nothing past $FFFF, and variables that nest but never partially overlap.
        let db = try Self.load()
        let fixed: [String: Int] = ["u8": 1, "s8": 1, "u16": 2, "s16": 2, "ptr": 2, "u24": 3, "s24": 3, "u32": 4, "s32": 4]
        var spans: [String: [(ClosedRange<Int>, String)]] = [:]
        for v in db["variables"] as? [[String: Any]] ?? [] {
            let name = v["name"] as? String ?? "?", size = v["size"] as? Int ?? 0, o = v["overlay"] as? String
            guard let a = Self.address(v["addr"]) else { continue }
            if let f = fixed[v["type"] as? String ?? ""] { #expect(size == f, "variable \(name): size \(size)") }
            #expect(size >= 1 && a + size - 1 <= 0xFFFF, "variable \(name): size \(size)")
            if o != nil { #expect(a >= 0xA7E0, "variable \(name) below the overlay window") }
            spans[o ?? "resident", default: []].append((a...(a + max(1, size) - 1), name))
        }
        for key in ["routines", "tables", "notes"] {
            for e in db[key] as? [[String: Any]] ?? [] where e["overlay"] is String {
                #expect((Self.address(e["addr"]) ?? 0) >= 0xA7E0, "\(key) \(e["name"] ?? e["text"] ?? "?") below the overlay window")
            }
        }
        for t in db["tables"] as? [[String: Any]] ?? [] {
            let a = Self.address(t["addr"]) ?? 0, n = t["length"] as? Int ?? 0
            #expect(n >= 1 && a + n - 1 <= 0xFFFF, "table \(t["name"] ?? "?")")
        }
        for (o, list) in spans {
            let sorted = list.sorted { ($0.0.lowerBound, -$0.0.count) < ($1.0.lowerBound, -$1.0.count) }
            var open: [(ClosedRange<Int>, String)] = []
            for (r, name) in sorted {
                open.removeAll { $0.0.upperBound < r.lowerBound }
                for (outer, outerName) in open {
                    #expect(r.upperBound <= outer.upperBound, "variables \(outerName) and \(name) partially overlap in \(o)")
                }
                open.append((r, name))
            }
        }
    }

    @Test func anchorRoutinesAreNamed() throws {
        // Entry points the plan and the port modules are built around.
        let db = try Self.load()
        var resident: [Int: String] = [:]
        for r in db["routines"] as? [[String: Any]] ?? [] where !(r["overlay"] is String) {
            if let a = Self.address(r["addr"]) { resident[a] = r["name"] as? String }
        }
        let anchors = [0x16C9, 0x1802, 0x1A86, 0x2048, 0x2285, 0x2348, 0x27D8, 0x2F45, 0x32EE, 0x8111, 0x83A4, 0x8742,
                       0x9A1D, 0xA378, 0xA532, 0xA5C8, 0xCC16, 0xE58F, 0xE5F6, 0xEE6B, 0xF16A, 0xF239, 0xF627]
        for a in anchors { #expect(resident[a] != nil, "no routine at $\(String(a, radix: 16, uppercase: true))") }
    }

    @Test func containsNoByteDumps() throws {
        // Names, addresses and short descriptions only: no run of 12 or more hex byte values.
        let text = try String(contentsOf: Self.url, encoding: .utf8)
        let regex = try Regex(#"(\$?[0-9A-Fa-f]{2}[ ,]+){12,}"#)
        #expect(text.firstMatch(of: regex) == nil)
    }
}
