import FS2Data
import Foundation
import M6502

public enum ListingError: Error, CustomStringConvertible {
    case usage(String)
    public var description: String {
        switch self { case .usage(let s): return s }
    }
}

/// Annotated, ca65-flavored listings of the original program driven by re/symbols.json: one file per
/// region group (the resident image and each overlay). Code is disassembled with labels and routine
/// headers, data and tables become `.byte`/`.word` rows, text gets character comments, and residue,
/// crack, loader and protection bytes are summarized under a NOT PORTED banner instead of dumped.
/// The output contains SubLogic bytes: it goes to re/out/, which is git-ignored.
public enum Listing {
    /// One output file: the regions of one overlay context over one memory image.
    public struct Group: Sendable {
        public let fileName: String
        public let title: String
        public let overlay: SymbolDatabase.Overlay?
        public let memory: [UInt8]
    }

    public struct Summary: Sendable, CustomStringConvertible {
        public let fileName: String
        public let regions: Int
        public let bytes: Int
        public let excludedBytes: Int
        public let undocumentedOpcodes: Int
        public let gaps: [ClosedRange<Int>]
        public var description: String {
            let g = gaps.isEmpty ? "" : ", unclassified " + gaps.map { "\(SymbolDatabase.hex($0.lowerBound))-\(SymbolDatabase.hex($0.upperBound))" }.joined(separator: " ")
            let u = undocumentedOpcodes == 0 ? "" : ", \(undocumentedOpcodes) undocumented opcode(s) in code regions"
            return "\(fileName): \(regions) regions, \(bytes) bytes (\(excludedBytes) not ported)\(u)\(g)"
        }
    }

    /// `fs2lab listing [--d64 path] [--out dir] [--symbols path]`.
    public static func run(arguments: [String]) throws {
        var d64: URL?
        var out: URL?
        var symbolsURL = SymbolDatabase.defaultURL()
        var i = 0
        let usage = "usage: fs2lab listing [--d64 disk.d64] [--out re/out] [--symbols re/symbols.json]"
        while i < arguments.count {
            guard i + 1 < arguments.count else { throw ListingError.usage(usage) }
            let v = URL(fileURLWithPath: arguments[i + 1])
            switch arguments[i] {
            case "--d64": d64 = v
            case "--out": out = v
            case "--symbols": symbolsURL = v
            default: throw ListingError.usage(usage)
            }
            i += 2
        }
        guard let symbolsURL else { throw ListingError.usage("re/symbols.json not found (pass --symbols)") }
        if d64 == nil, let env = ProcessInfo.processInfo.environment["FS2_D64"] { d64 = URL(fileURLWithPath: env) }
        if d64 == nil, FileManager.default.fileExists(atPath: GameData.importedDiskURL.path) { d64 = GameData.importedDiskURL }
        guard let d64 else { throw ListingError.usage("no disk image: pass --d64 or set FS2_D64\n" + usage) }
        let outDir = out ?? symbolsURL.deletingLastPathComponent().appendingPathComponent("out", isDirectory: true)

        let db = try SymbolDatabase.load(from: symbolsURL)
        let errors = db.validate().filter { $0.severity == .error }
        if !errors.isEmpty {
            errors.forEach { print($0) }
            throw SymbolsCheck.Failed(errors: errors.count)
        }
        let data = try GameData(d64URL: d64)
        let summaries = try write(groups(data), symbols: db, to: outDir)
        for s in summaries { print(s) }
        print("wrote \(summaries.count) files to \(outDir.path)")
    }

    /// The resident image plus one group per overlay. Every overlay except the cold-start one gets the
    /// scenery root block loaded at its end address, as the overlay manager does.
    public static func groups(_ data: GameData) -> [Group] {
        var out = [Group(fileName: "main.s", title: "resident image (cold start)", overlay: nil, memory: data.coldMemory),
                   Group(fileName: "overlay-cold-start.s", title: "overlay 0: cold start / stage 3 (blocks 2-4)", overlay: .coldStart, memory: data.coldMemory)]
        let files: [(FS2Layout.Overlay, SymbolDatabase.Overlay, String, String)] = [
            (.editor, .editor, "overlay-editor.s", "overlay 1: editor (blocks 42-47)"),
            (.war, .war, "overlay-war.s", "overlay 2: Europe 1917 war game (blocks 158-160)"),
            (.flight, .flight, "overlay-flight.s", "overlay 3: plain flight (block 65) + scenery root (block 66)"),
            (.databaseInfo, .databaseInfo, "overlay-database-info.s", "overlay 4: database info screen (block 64)"),
        ]
        for (layout, overlay, file, title) in files {
            var mem = [UInt8](repeating: 0, count: 0x10000)
            let bytes = data.overlay(layout)
            let base = FS2Layout.overlayBase
            for (k, b) in bytes.enumerated() where base + k < 0x10000 { mem[base + k] = b }
            let end = Int(mem[base]) | Int(mem[base + 1]) << 8
            let root = data.disk.block(FS2Layout.rootBlock)
            for (k, b) in root.enumerated() where end + k < 0x10000 { mem[end + k] = b }
            out.append(Group(fileName: file, title: title, overlay: overlay, memory: mem))
        }
        return out
    }

    @discardableResult
    public static func write(_ groups: [Group], symbols db: SymbolDatabase, to dir: URL) throws -> [Summary] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var summaries: [Summary] = []
        for g in groups {
            let (text, summary) = render(g, symbols: db)
            try Data(text.utf8).write(to: dir.appendingPathComponent(g.fileName))
            summaries.append(summary)
        }
        return summaries
    }

    // MARK: - Rendering

    /// Renders one group to listing text.
    public static func render(_ g: Group, symbols db: SymbolDatabase) -> (String, Summary) {
        var r = Renderer(group: g, db: db)
        return r.render()
    }

    struct Renderer {
        let group: Group
        let db: SymbolDatabase
        let regions: [SymbolDatabase.Region]
        let resolver: SymbolDatabase.Resolver
        let notes: [Int: [String]]
        /// Every name defined at an address in this context (aliases included), for label lines.
        var definitions: [Int: [String]] = [:]
        var variableAt: [Int: SymbolDatabase.Variable] = [:]
        var tableAt: [Int: SymbolDatabase.Table] = [:]
        var routineAt: [Int: SymbolDatabase.Routine] = [:]
        /// Auto labels for branch/jump targets inside this group's code regions.
        var autoLabels: [Int: String] = [:]
        var defined: Set<String> = []
        var referenced: [String: Int] = [:]
        var lines: [String] = []
        var undocumented = 0
        let dis = Disassembler()

        init(group: Group, db: SymbolDatabase) {
            self.group = group
            self.db = db
            regions = db.regions(in: group.overlay)
            resolver = SymbolDatabase.Resolver(db, overlay: group.overlay)
            notes = db.notes(in: group.overlay).merging(group.overlay == nil ? [:] : db.notes(in: nil)) { a, _ in a }
            // Names defined here: this context's own entries, plus resident names that fall inside this
            // group's regions (the overlay slot ABI, for example).
            let ranges = regions.map { $0.range! }
            func mine(_ o: SymbolDatabase.Overlay?, _ s: String) -> Int? {
                guard let a = SymbolDatabase.parseAddress(s).map(Int.init) else { return nil }
                if o == group.overlay { return a }
                return o == nil && ranges.contains { $0.contains(a) } ? a : nil
            }
            for v in db.variables {
                if let a = mine(v.overlay, v.addr) { definitions[a, default: []].append(v.name); variableAt[a] = variableAt[a] ?? v }
            }
            for t in db.tables {
                if let a = mine(t.overlay, t.addr) { definitions[a, default: []].append(t.name); tableAt[a] = t }
            }
            for r in db.routines {
                if let a = mine(r.overlay, r.addr) { definitions[a, default: []].append(r.name); routineAt[a] = r }
            }
        }

        func byte(_ a: Int) -> UInt8 { group.memory[a & 0xFFFF] }

        /// Operand naming: symbols, then auto labels, then hardware registers. The CPU port names
        /// ($00/$01) apply only to `direct` operands: as an index base, a pointer or a data word,
        /// $0000/$0001 is plain zero page (`lda $00,x`, `jmp ($0000)`, a null pointer).
        func peekName(_ a: Int, direct: Bool = true) -> String? {
            resolver.expression(for: a) ?? autoLabels[a] ?? (direct || a > 1 ? Hardware.names[a] : nil)
        }

        /// Names an operand and records the base name so the header can define external names.
        mutating func reference(_ a: Int, direct: Bool = true) -> String? {
            guard let n = peekName(a, direct: direct) else { return nil }
            let parts = n.split(separator: "+")
            referenced[String(parts[0])] = a - (parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
            return n
        }

        mutating func render() -> (String, Summary) {
            collectAutoLabels()
            var bytes = 0, excluded = 0
            for region in regions {
                let range = region.range!
                bytes += range.count
                if region.kind.isExcluded { excluded += range.count }
                emitRegionHeader(region, range)
                switch region.kind {
                case .code: emitCode(range)
                case .data, .table, .asset: emitData(range, region: region)
                case .text: emitText(range, encoding: region.encoding ?? .ascii)
                case .buffer, .free: emitReserved(range, region: region)
                case .residue, .crack, .loader, .protection: emitExcluded(range, region: region)
                }
            }
            let gaps = unclassifiedRanges()
            var head: [String] = []
            head.append("; Flight Simulator II (C64) - annotated listing: \(group.title)")
            head.append("; Generated by `fs2lab listing` from re/symbols.json. Contains SubLogic bytes: never commit (re/out/ is git-ignored).")
            head.append("; \(regions.count) regions, \(bytes) bytes, \(excluded) bytes not ported.")
            for gap in gaps { head.append("; Unclassified: \(SymbolDatabase.hex(gap.lowerBound))-\(SymbolDatabase.hex(gap.upperBound)) (\(gap.count) bytes)") }
            if undocumented > 0 { head.append("; WARNING: \(undocumented) undocumented opcode(s) in code regions (embedded data?)") }
            head.append("")
            head.append("        .setcpu \"6502\"")
            let externals = referenced.filter { !defined.contains($0.key) }.sorted { $0.value < $1.value }
            if !externals.isEmpty {
                head.append("")
                head.append("; ---- names defined outside this file")
                for (n, a) in externals { head.append(pad("\(n) = \(SymbolDatabase.hex(a))", 40) + "; " + (Hardware.names[a] == n ? "C64 hardware" : "symbols.json")) }
            }
            head.append("")
            let summary = Summary(fileName: group.fileName, regions: regions.count, bytes: bytes, excludedBytes: excluded,
                                  undocumentedOpcodes: undocumented, gaps: gaps)
            return ((head + lines).joined(separator: "\n") + "\n", summary)
        }

        /// Ranges inside this group's span not covered by any region (the overlay window for overlays).
        /// The resident span starts at $0002, as in `validate()`: $00/$01 are the CPU port, not RAM.
        func unclassifiedRanges() -> [ClosedRange<Int>] {
            let span: ClosedRange<Int>
            if group.overlay == nil { span = 0x0002...0xFFFF } else {
                guard let last = regions.last?.range?.upperBound else { return [] }
                span = FS2OverlayWindow.start...last
            }
            var gaps: [ClosedRange<Int>] = []
            var next = span.lowerBound
            for r in regions.map({ $0.range! }) {
                if r.lowerBound > next { gaps.append(next...(r.lowerBound - 1)) }
                next = max(next, r.upperBound + 1)
            }
            if next <= span.upperBound { gaps.append(next...span.upperBound) }
            // The overlay window belongs to the overlay listings.
            if group.overlay == nil {
                gaps = gaps.flatMap { g -> [ClosedRange<Int>] in
                    let w = FS2OverlayWindow.start...0xBFFF
                    guard g.overlaps(w) else { return [g] }
                    var parts: [ClosedRange<Int>] = []
                    if g.lowerBound < w.lowerBound { parts.append(g.lowerBound...(w.lowerBound - 1)) }
                    if g.upperBound > w.upperBound { parts.append((w.upperBound + 1)...g.upperBound) }
                    return parts
                }
            }
            return gaps
        }

        mutating func collectAutoLabels() {
            let codeRanges = regions.filter { $0.kind == .code }.map { $0.range! }
            for range in codeRanges {
                var pc = range.lowerBound
                while pc <= range.upperBound {
                    let d = dis.decode(at: UInt16(pc)) { byte(Int($0)) }
                    if d.isControlTransfer, let t = d.target.map(Int.init), resolver.label(at: t) == nil,
                       codeRanges.contains(where: { $0.contains(t) }) {
                        autoLabels[t] = "L" + Disassembler.hex4(UInt16(t))
                    }
                    pc += d.length
                }
            }
        }

        // MARK: Lines

        func pad(_ s: String, _ w: Int) -> String { s.count >= w ? s + " " : s + String(repeating: " ", count: w - s.count) }

        /// One statement with its address (and, for instructions, the raw bytes) in the comment.
        mutating func emit(_ body: String, at a: Int, hexBytes n: Int = 0, extra: String = "") {
            var comment = "; \(Disassembler.hex4(UInt16(a)))"
            if n > 0 { comment += "  " + (0..<n).map { Disassembler.hex2(byte(a + $0)) }.joined(separator: " ") }
            if !extra.isEmpty { comment = pad(comment, n > 0 ? 16 : 6) + " " + extra }
            lines.append(pad("        " + body, 48) + comment)
        }

        /// Label lines and notes for an address at a line start; names inside the next `length` bytes
        /// become `name = * + k` equates.
        mutating func emitLabels(at a: Int, length: Int) {
            for n in notes[a] ?? [] { lines.append("; NOTE: " + n) }
            if let r = routineAt[a] { emitRoutineHeader(r) }
            if let v = variableAt[a] { emitVariableComment(v) }
            if let t = tableAt[a] { emitTableComment(t) }
            for n in labelNames(at: a) { lines.append(n + ":"); defined.insert(n) }
            if length > 1 {
                for k in 1..<length {
                    for n in notes[a + k] ?? [] { lines.append("; NOTE (\(Disassembler.hex4(UInt16(a + k)))): " + n) }
                    for n in labelNames(at: a + k) {
                        lines.append(pad("\(n) = * + \(k)", 48) + "; \(Disassembler.hex4(UInt16(a + k))) (inside the next line)")
                        defined.insert(n)
                    }
                }
            }
        }

        func labelNames(at a: Int) -> [String] {
            var names = definitions[a] ?? []
            if names.isEmpty, let l = autoLabels[a] { names = [l] }
            return names
        }

        mutating func emitRoutineHeader(_ r: SymbolDatabase.Routine) {
            lines.append("")
            lines.append("; " + String(repeating: "-", count: 94))
            lines.append("; \(r.name) (\(r.addr)) [\(r.subsystem), \(r.confidence.rawValue) confidence]")
            for l in wrap(r.comment) { lines.append("; " + l) }
            if let s = r.inputs, !s.isEmpty { lines.append("; in:  " + s) }
            if let s = r.outputs, !s.isEmpty { lines.append("; out: " + s) }
            if let s = r.sideEffects, !s.isEmpty { lines.append("; side effects: " + s) }
            if let c = r.calledFrom, !c.isEmpty { lines.append("; called from: " + c.joined(separator: ", ")) }
        }

        mutating func emitVariableComment(_ v: SymbolDatabase.Variable) {
            let units = v.units.map { $0.isEmpty ? "" : ", " + $0 } ?? ""
            let text = "\(v.name): \(v.type.rawValue)\(v.size > 1 && v.type.fixedSize == nil ? "[\(v.size)]" : "")\(units). \(v.comment)"
            for (k, l) in wrap(text).enumerated() { lines.append((k == 0 ? "; " : ";   ") + l) }
        }

        mutating func emitTableComment(_ t: SymbolDatabase.Table) {
            let text = "\(t.name): table of \(t.length) bytes, \(t.element.rawValue). \(t.format). \(t.comment)"
            for (k, l) in wrap(text).enumerated() { lines.append((k == 0 ? "; " : ";   ") + l) }
        }

        func wrap(_ s: String, width: Int = 94) -> [String] {
            var out: [String] = [], cur = ""
            for w in s.split(separator: " ", omittingEmptySubsequences: true) {
                if !cur.isEmpty && cur.count + 1 + w.count > width { out.append(cur); cur = "" }
                cur += (cur.isEmpty ? "" : " ") + w
            }
            if !cur.isEmpty { out.append(cur) }
            return out
        }

        mutating func emitRegionHeader(_ r: SymbolDatabase.Region, _ range: ClosedRange<Int>) {
            lines.append("")
            lines.append("; " + String(repeating: "=", count: 94))
            if r.kind.isExcluded { lines.append("; NOT PORTED") }
            lines.append("; \(r.kind.rawValue.uppercased()) \(r.name) \(r.start)-\(r.end) (\(range.count) bytes) [\(r.subsystem)\(r.confidence.map { ", \($0.rawValue) confidence" } ?? "")]")
            for l in wrap(r.comment) { lines.append("; " + l) }
            lines.append("; " + String(repeating: "=", count: 94))
            lines.append("        .org \(r.start)")
        }

        // MARK: Region bodies

        mutating func emitCode(_ range: ClosedRange<Int>) {
            var pc = range.lowerBound
            while pc <= range.upperBound {
                let d = dis.decode(at: UInt16(pc)) { byte(Int($0)) }
                if pc + d.length - 1 > range.upperBound {
                    emitLabels(at: pc, length: 1)
                    emit(".byte $" + Disassembler.hex2(byte(pc)), at: pc, hexBytes: 1, extra: "(instruction would cross the region end)")
                    pc += 1
                    continue
                }
                emitLabels(at: pc, length: d.length)
                let direct = d.info.mode == .zeroPage || d.info.mode == .absolute
                let text = dis.format(d) { a in self.peekName(Int(a), direct: direct) }
                if d.info.documented {
                    if let t = d.target { _ = reference(Int(t), direct: direct) }
                } else {
                    undocumented += 1
                }
                emit(text, at: pc, hexBytes: d.length, extra: d.info.documented ? "" : "undocumented opcode")
                if d.endsFlow, pc + d.length <= range.upperBound { lines.append("") }
                pc += d.length
            }
        }

        /// Data, table and asset bytes: `.word` rows inside 16-bit tables and variables (pointers named),
        /// `.byte` rows elsewhere; a row never runs past a label, note, table end or the region end.
        mutating func emitData(_ range: ClosedRange<Int>, region: SymbolDatabase.Region) {
            var a = range.lowerBound
            var table: (end: Int, element: SymbolDatabase.TableElement, stride: Int?)?
            let perRow = region.kind == .asset ? 16 : 8
            while a <= range.upperBound {
                if let t = tableAt[a] { table = (a + t.length - 1, t.element, t.stride) }
                if let t = table, a > t.end { table = nil }
                var unit = 1, isPointer = false, limit = perRow, rowEnd = range.upperBound
                if let t = table {
                    unit = t.element.size
                    isPointer = t.element == .ptr
                    limit = t.stride.map { max(1, $0 / unit) } ?? (unit == 2 ? 8 : perRow)
                    rowEnd = min(rowEnd, t.end)
                } else if let v = variableAt[a], v.type.fixedSize == 2 {
                    unit = 2
                    isPointer = v.type == .ptr
                    limit = 1
                    rowEnd = min(rowEnd, a + 1)
                }
                var n = 0
                while n < limit {
                    let p = a + n * unit
                    if p + unit - 1 > rowEnd { break }
                    if n > 0, hasBreak(at: p) { break }
                    if n > 0, unit == 2, hasBreak(at: p + 1) { break }
                    n += 1
                }
                if n == 0 { unit = 1; n = 1 }
                emitLabels(at: a, length: n * unit)
                if unit == 2 {
                    var words: [String] = []
                    for k in 0..<n {
                        let w = Int(byte(a + 2 * k)) | Int(byte(a + 2 * k + 1)) << 8
                        words.append(isPointer ? (reference(w, direct: false) ?? "$" + Disassembler.hex4(UInt16(w))) : "$" + Disassembler.hex4(UInt16(w)))
                    }
                    emit(".word " + words.joined(separator: ","), at: a)
                } else {
                    emit(".byte " + (0..<n).map { "$" + Disassembler.hex2(byte(a + $0)) }.joined(separator: ","), at: a)
                }
                a += n * unit
            }
        }

        func hasBreak(at a: Int) -> Bool {
            definitions[a] != nil || notes[a] != nil || autoLabels[a] != nil
        }

        /// Text: `.byte` rows with the characters in the comment. ASCII rows end after each 0 byte
        /// (record terminators); screen-code pages run 40 bytes per row (one screen line).
        mutating func emitText(_ range: ClosedRange<Int>, encoding: SymbolDatabase.TextEncoding) {
            var a = range.lowerBound
            let limit = encoding == .screen ? 40 : 16
            while a <= range.upperBound {
                var n = 0
                while n < limit, a + n <= range.upperBound {
                    if n > 0, hasBreak(at: a + n) { break }
                    n += 1
                    if encoding == .ascii, byte(a + n - 1) == 0 { break }
                }
                emitLabels(at: a, length: 1)
                let chars = String((0..<n).map { Self.character(byte(a + $0), encoding) })
                let body = ".byte " + (0..<n).map { "$" + Disassembler.hex2(byte(a + $0)) }.joined(separator: ",")
                emit(body, at: a, extra: "\"" + chars + "\"")
                a += n
            }
        }

        static func character(_ b: UInt8, _ e: SymbolDatabase.TextEncoding) -> Character {
            switch e {
            case .ascii:
                return (0x20...0x5F).contains(b) ? Character(Unicode.Scalar(b)) : "."
            case .screen:
                // Screen codes in the upper/lowercase character set ($D018=$16), reverse video ignored.
                let c = b & 0x7F
                switch c {
                case 0x01...0x1A: return Character(Unicode.Scalar(c + 0x60))
                case 0x20...0x3F: return Character(Unicode.Scalar(c))
                case 0x40: return "-"
                case 0x41...0x5A: return Character(Unicode.Scalar(c))
                default: return "."
                }
            }
        }

        mutating func emitReserved(_ range: ClosedRange<Int>, region: SymbolDatabase.Region) {
            let nonzero = range.filter { byte($0) != 0 }.count
            emitLabels(at: range.lowerBound, length: 1)
            defineInside(range.dropFirst())
            lines.append(pad("        .res \(range.count)", 48) + "; \(region.kind.rawValue): contents not listed (\(nonzero == 0 ? "all zero" : "\(nonzero) non-zero bytes") in this image)")
        }

        /// Names inside a summarized region stay defined (as equates) so references still resolve.
        mutating func defineInside(_ addresses: ClosedRange<Int>.SubSequence) {
            for a in addresses {
                for n in definitions[a] ?? [] {
                    lines.append(pad("\(n) = \(SymbolDatabase.hex(a))", 48) + "; inside this region")
                    defined.insert(n)
                }
            }
        }

        mutating func emitExcluded(_ range: ClosedRange<Int>, region: SymbolDatabase.Region) {
            let nonzero = range.filter { byte($0) != 0 }.count
            lines.append("; " + String(repeating: "#", count: 94))
            lines.append("; ### NOT PORTED: \(region.kind.rawValue) \(region.name), \(range.count) bytes (\(nonzero) non-zero). Contents omitted.")
            lines.append("; " + String(repeating: "#", count: 94))
            defineInside(range[...])
            lines.append(pad("        .res \(range.count)", 48) + "; contents omitted")
        }
    }

    /// C64 I/O register names used for operands the symbol database does not name.
    enum Hardware {
        static let names: [Int: String] = {
            var n: [Int: String] = [0x0000: "cpuPortDdr", 0x0001: "cpuPort", 0xD800: "colorRam"]
            for s in 0..<8 {
                n[0xD000 + 2 * s] = "vicSprite\(s)X"
                n[0xD001 + 2 * s] = "vicSprite\(s)Y"
                n[0xD027 + s] = "vicSprite\(s)Color"
            }
            let vic = ["vicSpriteXMsb", "vicControl1", "vicRaster", "vicLightPenX", "vicLightPenY", "vicSpriteEnable",
                       "vicControl2", "vicSpriteExpandY", "vicMemoryPointers", "vicIrqStatus", "vicIrqEnable",
                       "vicSpritePriority", "vicSpriteMulticolor", "vicSpriteExpandX", "vicSpriteCollision",
                       "vicSpriteBackgroundCollision", "vicBorderColor", "vicBackground0", "vicBackground1",
                       "vicBackground2", "vicBackground3", "vicSpriteMulticolor0", "vicSpriteMulticolor1"]
            for (k, s) in vic.enumerated() { n[0xD010 + k] = s }
            for v in 0..<3 {
                let regs = ["FreqLo", "FreqHi", "PulseLo", "PulseHi", "Control", "AttackDecay", "SustainRelease"]
                for (k, r) in regs.enumerated() { n[0xD400 + 7 * v + k] = "sidVoice\(v + 1)\(r)" }
            }
            let sid = ["sidCutoffLo", "sidCutoffHi", "sidResonanceRouting", "sidModeVolume", "sidPotX", "sidPotY", "sidOsc3", "sidEnv3"]
            for (k, s) in sid.enumerated() { n[0xD415 + k] = s }
            let cia = ["PortA", "PortB", "DdrA", "DdrB", "TimerALo", "TimerAHi", "TimerBLo", "TimerBHi", "TodTenths",
                       "TodSeconds", "TodMinutes", "TodHours", "Serial", "InterruptControl", "ControlA", "ControlB"]
            for (k, s) in cia.enumerated() { n[0xDC00 + k] = "cia1" + s; n[0xDD00 + k] = "cia2" + s }
            return n
        }()
    }
}
