import Foundation

/// The reverse-engineering knowledge base, `re/symbols.json`: the source of truth for names, types and
/// comments of the original program. Addresses are `"$XXXX"` strings; `overlay == nil` means resident
/// memory, otherwise the entry lives in the $A7E0 overlay window of that overlay. Schema: re/README.md.
public struct SymbolDatabase: Codable, Sendable {
    public enum Overlay: String, Codable, CaseIterable, Sendable {
        case coldStart, editor, war, flight, databaseInfo
    }

    public enum RegionKind: String, Codable, CaseIterable, Sendable {
        case code, data, table, text, asset, buffer, free, residue, crack, loader, protection

        /// Bytes that are not part of the port (the listing summarizes them under a NOT PORTED banner).
        public var isExcluded: Bool { [.residue, .crack, .loader, .protection].contains(self) }
    }

    public enum Confidence: String, Codable, Sendable { case high, medium, low }

    public enum VariableType: String, Codable, Sendable {
        case u8, s8, u16, s16, u24, s24, u32, s32, bcd, ascii, ptr, bytes

        /// The size the type implies, or nil when any size is allowed.
        public var fixedSize: Int? {
            switch self {
            case .u8, .s8: return 1
            case .u16, .s16, .ptr: return 2
            case .u24, .s24: return 3
            case .u32, .s32: return 4
            case .bcd, .ascii, .bytes: return nil
            }
        }
    }

    public enum TableElement: String, Codable, Sendable {
        case u8, s8, u16, s16, ptr, bytes
        public var size: Int { [.u16, .s16, .ptr].contains(self) ? 2 : 1 }
    }

    /// Character set of a text region, for the listing's comments: `ascii` (the game's 3x5 font
    /// records) or `screen` (C64 screen codes in the upper/lowercase ROM set, as the editor uses).
    public enum TextEncoding: String, Codable, Sendable { case ascii, screen }

    public struct Region: Codable, Sendable {
        public var start: String
        public var end: String
        public var kind: RegionKind
        public var name: String
        public var subsystem: String
        public var overlay: Overlay?
        public var confidence: Confidence?
        public var comment: String
        public var encoding: TextEncoding?

        public var range: ClosedRange<Int>? {
            guard let s = SymbolDatabase.parseAddress(start), let e = SymbolDatabase.parseAddress(end), s <= e else { return nil }
            return Int(s)...Int(e)
        }
    }

    public struct Variable: Codable, Sendable {
        public var addr: String
        public var name: String
        public var type: VariableType
        public var size: Int
        public var subsystem: String
        public var overlay: Overlay?
        public var units: String?
        public var confidence: Confidence
        public var comment: String
    }

    public struct Routine: Codable, Sendable {
        public var addr: String
        public var name: String
        public var subsystem: String
        public var overlay: Overlay?
        public var inputs: String?
        public var outputs: String?
        public var sideEffects: String?
        public var calledFrom: [String]?
        public var confidence: Confidence
        public var comment: String
    }

    public struct Table: Codable, Sendable {
        public var addr: String
        public var name: String
        public var length: Int
        public var element: TableElement
        /// Bytes per listing row (a record size); optional.
        public var stride: Int?
        public var format: String
        public var subsystem: String
        public var overlay: Overlay?
        public var confidence: Confidence
        public var comment: String
    }

    /// A comment attached to one address (self-modified operands, branch points of interest).
    public struct Note: Codable, Sendable {
        public var addr: String
        public var overlay: Overlay?
        public var text: String
    }

    public var schemaVersion: Int
    public var game: String?
    public var description: String?
    public var regions: [Region]
    public var variables: [Variable]
    public var routines: [Routine]
    public var tables: [Table]
    public var notes: [Note]?

    // MARK: - Loading

    /// Loads `symbols.json` and merges every fragment in the sibling `symbols.d/` directory
    /// (one per porting work unit, so parallel work never edits the same file). A fragment entry
    /// with the same address and overlay as an existing entry of its kind replaces it.
    public static func load(from url: URL) throws -> SymbolDatabase {
        var db = try decode(SymbolDatabase.self, from: url)
        let dir = url.deletingLastPathComponent().appendingPathComponent("symbols.d", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.path < $1.path }) {
            db.merge(try decode(Fragment.self, from: f))
        }
        return db
    }

    private static func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch let error as DecodingError {
            throw LoadError(url: url, detail: Self.describe(error))
        }
    }

    /// A partial database in `re/symbols.d/*.json`; every array is optional.
    public struct Fragment: Codable, Sendable {
        public var regions: [Region]?
        public var variables: [Variable]?
        public var routines: [Routine]?
        public var tables: [Table]?
        public var notes: [Note]?
    }

    mutating func merge(_ f: Fragment) {
        func replace<T>(_ list: inout [T], with new: [T]?, key: (T) -> String) {
            for item in new ?? [] {
                if let i = list.firstIndex(where: { key($0) == key(item) }) { list[i] = item } else { list.append(item) }
            }
        }
        replace(&regions, with: f.regions) { "\($0.start)/\($0.overlay.map { "\($0)" } ?? "-")" }
        replace(&variables, with: f.variables) { "\($0.addr)/\($0.overlay.map { "\($0)" } ?? "-")" }
        replace(&routines, with: f.routines) { "\($0.addr)/\($0.overlay.map { "\($0)" } ?? "-")" }
        replace(&tables, with: f.tables) { "\($0.addr)/\($0.overlay.map { "\($0)" } ?? "-")" }
        if let n = f.notes { notes = (notes ?? []) + n }
    }

    public struct LoadError: Error, CustomStringConvertible {
        public let url: URL, detail: String
        public var description: String { "\(url.path): \(detail)" }
    }

    static func describe(_ e: DecodingError) -> String {
        func path(_ c: [CodingKey]) -> String {
            c.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
        }
        switch e {
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c):
            return "\(path(c.codingPath)): \(c.debugDescription)"
        case .keyNotFound(let k, let c):
            return "\(path(c.codingPath)): missing key '\(k.stringValue)'"
        @unknown default:
            return "\(e)"
        }
    }

    /// Finds `re/symbols.json` from the working directory or one of its parents.
    public static func defaultURL() -> URL? {
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            let u = dir.appendingPathComponent("re/symbols.json")
            if FileManager.default.fileExists(atPath: u.path) { return u }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    /// Parses `"$XXXX"` (exactly four uppercase hex digits).
    public static func parseAddress(_ s: String) -> UInt16? {
        let u = Array(s.utf8)
        guard u.count == 5, u[0] == UInt8(ascii: "$") else { return nil }
        var v: UInt16 = 0
        for c in u.dropFirst() {
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): v = v << 4 | UInt16(c - UInt8(ascii: "0"))
            case UInt8(ascii: "A")...UInt8(ascii: "F"): v = v << 4 | UInt16(c - UInt8(ascii: "A") + 10)
            default: return nil
            }
        }
        return v
    }

    public static func hex(_ a: Int) -> String { String(format: "$%04X", a) }

    // MARK: - Lookup

    /// A named address (variable, routine or table) as the listing sees it.
    public struct Symbol: Sendable {
        public enum Kind: String, Sendable { case variable, routine, table }
        public let name: String
        public let address: Int
        public let size: Int
        public let kind: Kind
        public let overlay: Overlay?
    }

    /// Every variable, routine and table with a valid address.
    public var symbols: [Symbol] {
        var out: [Symbol] = []
        for v in variables { if let a = Self.parseAddress(v.addr) { out.append(Symbol(name: v.name, address: Int(a), size: max(1, v.size), kind: .variable, overlay: v.overlay)) } }
        for r in routines { if let a = Self.parseAddress(r.addr) { out.append(Symbol(name: r.name, address: Int(a), size: 1, kind: .routine, overlay: r.overlay)) } }
        for t in tables { if let a = Self.parseAddress(t.addr) { out.append(Symbol(name: t.name, address: Int(a), size: max(1, t.length), kind: .table, overlay: t.overlay)) } }
        return out
    }

    /// Regions visible in a context, sorted by start: an overlay's own regions, or the resident ones.
    public func regions(in overlay: Overlay?) -> [Region] {
        regions.filter { $0.overlay == overlay && $0.range != nil }.sorted { $0.range!.lowerBound < $1.range!.lowerBound }
    }

    /// The region containing `address` (the overlay's own region first, then a resident one).
    public func region(containing address: Int, overlay: Overlay?) -> Region? {
        if let o = overlay, let r = regions.first(where: { $0.overlay == o && $0.range?.contains(address) == true }) { return r }
        return regions.first { $0.overlay == nil && $0.range?.contains(address) == true }
    }

    /// Address-to-name resolver for one context. Exact starts win; otherwise the smallest variable or
    /// table containing the address yields `name+offset`. Overlay entries shadow resident ones.
    public struct Resolver: Sendable {
        public let overlay: Overlay?
        var exact: [Int: String] = [:]
        var inside: [Int: (name: String, offset: Int, size: Int)] = [:]

        public init(_ db: SymbolDatabase, overlay: Overlay?) {
            self.overlay = overlay
            let all = db.symbols
            // Resident entries first; an overlay's own entries then shadow them address by address.
            var layers = [all.filter { $0.overlay == nil }]
            if let overlay { layers.append(all.filter { $0.overlay == overlay }) }
            for layer in layers {
                var exactLayer: [Int: (name: String, size: Int)] = [:]
                var insideLayer: [Int: (name: String, offset: Int, size: Int)] = [:]
                for s in layer {
                    // The most specific (smallest) entry names an address; routines count as size 1.
                    if let prev = exactLayer[s.address], prev.size <= s.size {} else { exactLayer[s.address] = (s.name, s.size) }
                    guard s.kind != .routine, s.size > 1 else { continue }
                    for k in 1..<s.size where s.address + k <= 0xFFFF {
                        if let cur = insideLayer[s.address + k], cur.size <= s.size { continue }
                        insideLayer[s.address + k] = (s.name, k, s.size)
                    }
                }
                for (a, v) in exactLayer { exact[a] = v.name }
                for (a, v) in insideLayer { inside[a] = v }
            }
        }

        /// The name at `address`, or `name+k` inside a multi-byte variable or table.
        public func expression(for address: Int) -> String? {
            if let n = exact[address] { return n }
            if let i = inside[address] { return "\(i.name)+\(i.offset)" }
            return nil
        }

        /// A name defined exactly at `address`.
        public func label(at address: Int) -> String? { exact[address] }
    }

    public func notes(in overlay: Overlay?) -> [Int: [String]] {
        var out: [Int: [String]] = [:]
        for n in notes ?? [] where n.overlay == overlay {
            if let a = Self.parseAddress(n.addr) { out[Int(a), default: []].append(n.text) }
        }
        return out
    }

    // MARK: - Validation

    public struct Issue: CustomStringConvertible, Sendable {
        public enum Severity: String, Sendable { case error, warning }
        public let severity: Severity
        public let message: String
        public var description: String { "\(severity.rawValue): \(message)" }
    }

    /// Checks addresses, region overlaps, name uniqueness and spelling, sizes and overlay placement.
    public func validate() -> [Issue] {
        var issues: [Issue] = []
        func error(_ m: String) { issues.append(Issue(severity: .error, message: m)) }
        func warning(_ m: String) { issues.append(Issue(severity: .warning, message: m)) }
        func isName(_ s: String) -> Bool {
            guard let f = s.unicodeScalars.first, ("a"..."z").contains(f) else { return false }
            return s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
        }
        func checkAddress(_ s: String, _ what: String) -> Int? {
            guard let a = Self.parseAddress(s) else { error("\(what): bad address '\(s)' (expected \"$XXXX\", uppercase)"); return nil }
            return Int(a)
        }
        func checkPlacement(_ a: Int, _ overlay: Overlay?, _ what: String) {
            if overlay != nil && a < FS2OverlayWindow.start { error("\(what): overlay entry below the overlay window $A7E0") }
        }

        if schemaVersion != 1 { error("schemaVersion \(schemaVersion) is not supported (expected 1)") }

        // Regions: well-formed, no overlap within one overlay, unique names per overlay.
        var byOverlay: [Overlay?: [(ClosedRange<Int>, String)]] = [:]
        var regionNames: [Overlay?: Set<String>] = [:]
        for r in regions {
            let what = "region \(r.name)"
            if !isName(r.name) { error("\(what): name is not lowerCamelCase") }
            if regionNames[r.overlay, default: []].insert(r.name).inserted == false {
                error("\(what): duplicate region name in overlay \(r.overlay?.rawValue ?? "resident")")
            }
            guard let s = checkAddress(r.start, what + ".start"), let e = checkAddress(r.end, what + ".end") else { continue }
            if s > e { error("\(what): start \(r.start) is after end \(r.end)"); continue }
            checkPlacement(s, r.overlay, what)
            byOverlay[r.overlay, default: []].append((s...e, r.name))
        }
        // Coverage: every resident byte from $0002 up, outside the overlay window $A7E0-$BFFF.
        var next = 0x0002
        for (r, _) in (byOverlay[nil] ?? []).sorted(by: { $0.0.lowerBound < $1.0.lowerBound }) {
            if r.lowerBound > next {
                let gap = next..<r.lowerBound
                let outside = gap.clamped(to: 0..<FS2OverlayWindow.start).count + gap.clamped(to: 0xC000..<0x10000).count
                if outside > 0 { warning("resident bytes \(Self.hex(gap.lowerBound))-\(Self.hex(gap.upperBound - 1)) belong to no region") }
            }
            next = max(next, r.upperBound + 1)
        }
        if next <= 0xFFFF { warning("resident bytes \(Self.hex(next))-$FFFF belong to no region") }
        for (o, list) in byOverlay {
            let sorted = list.sorted { $0.0.lowerBound < $1.0.lowerBound }
            for (a, b) in zip(sorted, sorted.dropFirst()) where b.0.lowerBound <= a.0.upperBound {
                error("regions \(a.1) \(Self.hex(a.0.lowerBound))-\(Self.hex(a.0.upperBound)) and \(b.1) \(Self.hex(b.0.lowerBound))-\(Self.hex(b.0.upperBound)) overlap in \(o?.rawValue ?? "resident")")
            }
        }

        // Labels: variables, routines and tables share one namespace per overlay; overlay names must not
        // shadow resident names (both are visible in an overlay listing).
        var labels: [Overlay?: [String: String]] = [:]
        func addLabel(_ name: String, _ overlay: Overlay?, _ addr: String, _ what: String) {
            if !isName(name) { error("\(what) \(name): name is not lowerCamelCase") }
            if let prev = labels[overlay]?[name] {
                error("\(what) \(name) at \(addr): duplicate name in \(overlay?.rawValue ?? "resident") (also at \(prev))")
            }
            labels[overlay, default: [:]][name] = addr
        }
        for v in variables {
            addLabel(v.name, v.overlay, v.addr, "variable")
            guard let a = checkAddress(v.addr, "variable \(v.name)") else { continue }
            checkPlacement(a, v.overlay, "variable \(v.name)")
            if v.size < 1 { error("variable \(v.name): size \(v.size) < 1") }
            if let f = v.type.fixedSize, f != v.size { error("variable \(v.name): type \(v.type.rawValue) implies size \(f), not \(v.size)") }
            if a + v.size - 1 > 0xFFFF { error("variable \(v.name): extends past $FFFF") }
        }
        for r in routines {
            addLabel(r.name, r.overlay, r.addr, "routine")
            guard let a = checkAddress(r.addr, "routine \(r.name)") else { continue }
            checkPlacement(a, r.overlay, "routine \(r.name)")
            for c in r.calledFrom ?? [] { _ = checkAddress(c, "routine \(r.name).calledFrom") }
            let kinds: [RegionKind] = [.code, .loader, .protection, .residue]
            if let reg = region(containing: a, overlay: r.overlay), !kinds.contains(reg.kind) {
                warning("routine \(r.name) \(r.addr) is in \(reg.kind.rawValue) region \(reg.name)")
            }
        }
        for t in tables {
            addLabel(t.name, t.overlay, t.addr, "table")
            guard let a = checkAddress(t.addr, "table \(t.name)") else { continue }
            checkPlacement(a, t.overlay, "table \(t.name)")
            if t.length < 1 { error("table \(t.name): length \(t.length) < 1") }
            if a + t.length - 1 > 0xFFFF { error("table \(t.name): extends past $FFFF") }
            if let s = t.stride, s < 1 { error("table \(t.name): stride \(s) < 1") }
        }
        for n in notes ?? [] { _ = checkAddress(n.addr, "note '\(n.text.prefix(30))'") }
        // Variables may nest (record fields inside a record) but must not partially overlap.
        let spans = variables.compactMap { v in Self.parseAddress(v.addr).map { (v.overlay, Int($0)...(Int($0) + max(1, v.size) - 1), v.name) } }
        for o in Set(spans.map { $0.0 }) {
            let list = spans.filter { $0.0 == o }.sorted { ($0.1.lowerBound, -$0.1.count) < ($1.1.lowerBound, -$1.1.count) }
            var open: [(ClosedRange<Int>, String)] = []
            for (_, r, name) in list {
                open.removeAll { $0.0.upperBound < r.lowerBound }
                for (outer, outerName) in open where r.upperBound > outer.upperBound {
                    error("variables \(outerName) and \(name) partially overlap at \(Self.hex(r.lowerBound))")
                }
                open.append((r, name))
            }
        }
        let resident = labels[nil] ?? [:]
        for (o, names) in labels where o != nil {
            for (name, addr) in names where resident[name] != nil {
                error("\(o!.rawValue) name \(name) at \(addr) shadows the resident name at \(resident[name]!)")
            }
        }
        return issues
    }
}

/// The $A7E0 window that SubLogic's overlay manager loads overlays into.
enum FS2OverlayWindow {
    static let start = 0xA7E0
}

/// `fs2lab symbols-check [--symbols path]`: loads and validates re/symbols.json.
public enum SymbolsCheck {
    public struct Failed: Error, CustomStringConvertible {
        public let errors: Int
        public var description: String { "symbols-check failed with \(errors) error(s)" }
    }

    public static func run(arguments: [String]) throws {
        var url = SymbolDatabase.defaultURL()
        var i = 0
        while i < arguments.count {
            switch arguments[i] {
            case "--symbols" where i + 1 < arguments.count:
                url = URL(fileURLWithPath: arguments[i + 1]); i += 2
            default:
                throw ListingError.usage("usage: fs2lab symbols-check [--symbols re/symbols.json]")
            }
        }
        guard let url else { throw ListingError.usage("re/symbols.json not found (pass --symbols)") }
        let db = try SymbolDatabase.load(from: url)
        let issues = db.validate()
        print(summary(db, url: url))
        for issue in issues { print(issue) }
        let errors = issues.filter { $0.severity == .error }.count
        if errors > 0 { throw Failed(errors: errors) }
        print("ok: no errors, \(issues.count) warning(s)")
    }

    public static func summary(_ db: SymbolDatabase, url: URL) -> String {
        var kinds: [String: Int] = [:]
        for r in db.regions { kinds[r.kind.rawValue, default: 0] += 1 }
        let kindList = kinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        return """
        \(url.path)
          regions \(db.regions.count) (\(kindList))
          variables \(db.variables.count), routines \(db.routines.count), tables \(db.tables.count), notes \(db.notes?.count ?? 0)
        """
    }
}
