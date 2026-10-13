import Foundation
import Testing

/// The repository holds no SubLogic code or data: no file in the repository's own folders has a run
/// of 12 or more bytes that also occurs in the disk's 164 logical blocks, written as raw bytes, hex
/// or decimal byte lists, 16-, 32- or 64-bit hex words (either byte order), hex strings or base64.
/// The disk is read at test time; nothing of it is written here.
///
/// Three kinds of match are not content and are allowed: windows with fewer than 4 distinct byte
/// values (runs of spaces, zeros or fill bytes), counting sequences (0, 1, 2 … as bytes or words),
/// and the 1541's own status line, which the port and the lab write as the drive would. Quoted
/// on-screen text (printable ASCII) is allowed in the reverse-engineering notes under `re/`, which
/// describe the game's screens. Everywhere else (the sources, tests, packaging, scripts and the
/// README) the only text allowed is a short label from `allowedLabels`: the name of a prompt, a
/// menu or an editor field, quoted so the player can find it on the screen. A run of matching
/// bytes passes only when, without the spaces and NULs at its ends, it is printable text lying
/// inside one quoted label; anything longer, anything next to more of the game's text and any
/// data still fails.
///
/// `make audit` also scans the shipped app binary (`FS2_AUDIT_BINARY`) with the same rules: the
/// compiler lays tables out contiguously, so a list of constants that is harmless in a source file
/// (say, a jump table's addresses written as separate declarations, in the table's order) can still
/// turn up in it, and the help and the keyboard reference name the same labels as the README.
///
/// A second pass looks for the game's code written out as an instruction listing (`Instruction
/// listings` below): mnemonics with their operands, in comments, notes or data, assembled with the
/// standard opcode table and searched on the disk.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"), .serialized)
struct SubLogicBytesAuditTests {
    static let window = 12

    /// The game's on-screen labels that the user documentation, the app's help and keyboard
    /// reference, the tests and the scripts may quote, each with where it appears in the game. The
    /// project allows short identifying strings: every entry is at most 40 characters of printable
    /// text, a single label as the game shows it, and occurs on the disk (`allowedLabelsAreShort`).
    /// Add an entry only for a label a player has to recognize on the screen; describe anything
    /// longer instead of quoting it.
    static let allowedLabels: [(label: String, place: String)] = [
        ("WHAT DISPLAY ARE YOU USING?", "title screen: the first prompt (A color, B black and white)"),
        ("SELECT OPERATING MODE", "title screen: the second prompt (A demo, B regular flight)"),
        ("COURSE PLOTTER SYSTEM", "the course plotter menu's heading (Q)"),
        ("REALITY MODE", "editor page 0, line 5"),
        ("EUROPE 1917", "editor page 0, line 6 (the World War I game)"),
        ("ADF ENABLE", "editor page 1, line 21"),
    ]

    /// A 12-byte window as a hashable key.
    struct Key: Hashable {
        var a: UInt64, b: UInt32
        init(_ p: UnsafeBufferPointer<UInt8>, _ i: Int) {
            var x: UInt64 = 0, y: UInt32 = 0
            for k in 0..<8 { x |= UInt64(p[i + k]) << (8 * k) }
            for k in 0..<4 { y |= UInt32(p[i + 8 + k]) << (8 * k) }
            a = x; b = y
        }
    }

    struct Match: CustomStringConvertible {
        var file: String, line: Int, encoding: String
        /// The matched run when it is printable text (spaces and NULs at its ends trimmed), else nil.
        var text: String?
        /// Whether that text lies inside an allowed label quoted at the same place.
        var label = false
        var description: String { "\(file):\(line) [\(encoding)]" + (text.map { " \"\($0.prefix(48))\"" } ?? "") }
    }

    /// The disk's logical blocks in block order, as one run.
    static let disk: [UInt8] = Original.data.map { $0.disk.blocks.flatMap { $0 } } ?? []

    /// Every 12-byte window of the disk's logical blocks (in block order, so runs across a block
    /// boundary count too).
    static let windows: Set<Key> = {
        let all = disk
        guard all.count >= window else { return [] }
        var set = Set<Key>(minimumCapacity: all.count)
        all.withUnsafeBufferPointer { p in
            for i in 0...(p.count - window) { set.insert(Key(p, i)) }
        }
        return set
    }()

    /// The 1541 status line "00, OK,00,00" + CR: Commodore DOS output, not SubLogic's (with the
    /// zero bytes that end it in a binary and in the disk's copy).
    static let driveStatus = Array("00, OK,00,00\r".utf8) + [UInt8](repeating: 0, count: window)

    /// Whether a window is a piece of the drive status line.
    static func isDriveStatus(_ w: ArraySlice<UInt8>) -> Bool {
        driveStatus.indices.contains { driveStatus[$0...].starts(with: w) }
    }

    /// Windows that carry no content: fewer than 4 distinct byte values, or two interleaved
    /// arithmetic progressions (even and odd bytes each step by a constant: counting tables such as
    /// 0, 1, 2 … as bytes or as 16-bit words).
    static func isGeneric(_ p: UnsafeBufferPointer<UInt8>, _ i: Int) -> Bool {
        if Set(p[i..<i + window]).count < 4 { return true }
        for phase in 0..<2 {
            let step = p[i + phase + 2] &- p[i + phase]
            for k in stride(from: i + phase + 2, to: i + window, by: 2) where p[k] &- p[k - 2] != step {
                return false
            }
        }
        return true
    }

    /// The runs of `bytes` that match the disk: every window that carries content (and is not part
    /// of the drive status line, when `skipDriveStatus`), merged where windows overlap or touch.
    static func spans(_ bytes: [UInt8], skipDriveStatus: Bool = false) -> [Range<Int>] {
        guard bytes.count >= window else { return [] }
        var out: [Range<Int>] = []
        bytes.withUnsafeBufferPointer { p in
            for i in 0...(p.count - window) where windows.contains(Key(p, i)) && !isGeneric(p, i) {
                if skipDriveStatus && isDriveStatus(bytes[i..<i + window]) { continue }
                if let last = out.last, i <= last.upperBound {
                    out[out.count - 1] = last.lowerBound..<(i + window)
                } else {
                    out.append(i..<i + window)
                }
            }
        }
        return out
    }

    // MARK: Labels

    /// A span without the spaces and NULs at its ends (a padded record, a C string's terminator).
    static func trimmed(_ bytes: [UInt8], _ span: Range<Int>) -> Range<Int> {
        var lo = span.lowerBound, hi = span.upperBound
        while lo < hi && (bytes[lo] == 0x20 || bytes[lo] == 0) { lo += 1 }
        while hi > lo && (bytes[hi - 1] == 0x20 || bytes[hi - 1] == 0) { hi -= 1 }
        return lo..<hi
    }

    /// The span's text when it is printable (after trimming), else nil.
    static func text(_ bytes: [UInt8], _ span: Range<Int>) -> String? {
        let t = trimmed(bytes, span)
        guard !t.isEmpty, bytes[t].allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        return String(decoding: bytes[t], as: UTF8.self)
    }

    /// Whether the span (trimmed) lies inside one occurrence of an allowed label in `bytes`.
    static func isAllowedLabel(_ bytes: [UInt8], _ span: Range<Int>) -> Bool {
        guard text(bytes, span) != nil else { return false }
        let t = trimmed(bytes, span)
        return allowedLabels.contains { entry in
            let label = Array(entry.label.utf8)
            guard t.count <= label.count else { return false }
            let first = max(0, t.upperBound - label.count), last = min(t.lowerBound, bytes.count - label.count)
            guard first <= last else { return false }
            return (first...last).contains { bytes[$0..<$0 + label.count].elementsEqual(label) }
        }
    }

    // MARK: Encodings

    /// Characters that separate the items of a list: white space, `, ; :`, brackets, quotes and
    /// table bars.
    static func isDelimiter(_ c: UInt8) -> Bool {
        switch c {
        case 0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x3B, 0x3A, 0x5B, 0x5D, 0x28, 0x29, 0x7B, 0x7D, 0x22, 0x27, 0x60, 0x7C: true
        default: false
        }
    }

    static func hexValue(_ c: UInt8) -> UInt64? {
        switch c {
        case 0x30...0x39: UInt64(c - 0x30)
        case 0x41...0x46: UInt64(c - 0x41 + 10)
        case 0x61...0x66: UInt64(c - 0x61 + 10)
        default: nil
        }
    }

    /// A word's value as a hex literal (`0x`, `$`, `#$` or `\x` prefix optional) and its digit count.
    static func hexWord(_ w: ArraySlice<UInt8>) -> (value: UInt64, digits: Int)? {
        var s = number(w)
        for prefix in ["0x", "0X", "#$", "$", "\\x"].map({ Array($0.utf8) }) where s.starts(with: prefix) {
            s = s.dropFirst(prefix.count)
            break
        }
        guard (1...16).contains(s.count) else { return nil }
        var v: UInt64 = 0
        for c in s {
            guard let d = hexValue(c) else { return nil }
            v = v << 4 | d
        }
        return (v, s.count)
    }

    /// A word without the punctuation that can end a number in prose (`$12.`, `0x34*`).
    static func number(_ w: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        var s = w
        while let c = s.last, c == 0x2E || c == 0x2A || c == 0x21 || c == 0x3F { s = s.dropLast() }
        return s
    }

    /// The byte sequences a file's text can encode, each with the text offset it starts at.
    static func encodings(_ text: [UInt8]) -> [(name: String, start: Int, bytes: [UInt8])] {
        // Words: maximal runs between delimiters.
        var words: [(start: Int, end: Int)] = []
        var i = 0
        while i < text.count {
            if isDelimiter(text[i]) { i += 1; continue }
            let s = i
            while i < text.count && !isDelimiter(text[i]) { i += 1 }
            words.append((s, i))
        }
        var out: [(String, Int, [UInt8])] = []
        // Runs of consecutive words of one kind, each word giving `width` bytes (both byte orders).
        func runs(_ name: String, width: Int, _ value: (ArraySlice<UInt8>) -> UInt64?) {
            var le: [UInt8] = [], be: [UInt8] = [], start = 0
            func flush() {
                if le.count >= window {
                    out.append((name, start, le))
                    if width > 1 { out.append((name + "-be", start, be)) }
                }
                le = []; be = []
            }
            for w in words {
                guard let v = value(text[w.start..<w.end]) else { flush(); continue }
                if le.isEmpty { start = w.start }
                for k in 0..<width { le.append(UInt8(truncatingIfNeeded: v >> (8 * k))) }
                for k in (0..<width).reversed() { be.append(UInt8(truncatingIfNeeded: v >> (8 * k))) }
            }
            flush()
        }
        runs("hex8", width: 1) { w in hexWord(w).flatMap { $0.digits <= 2 ? $0.value : nil } }
        runs("hex16", width: 2) { w in hexWord(w).flatMap { (3...4).contains($0.digits) ? $0.value : nil } }
        runs("hex32", width: 4) { w in hexWord(w).flatMap { (5...8).contains($0.digits) ? $0.value : nil } }
        runs("hex64", width: 8) { w in hexWord(w).flatMap { (9...16).contains($0.digits) ? $0.value : nil } }
        runs("decimal", width: 1) { word in
            let w = number(word)
            guard (1...3).contains(w.count), w.allSatisfy({ (0x30...0x39).contains($0) }),
                  let v = Int(String(decoding: w, as: UTF8.self)), v <= 255 else { return nil }
            return UInt64(v)
        }
        runs("binary", width: 1) { w in
            guard w.count >= 3, w.count <= 10, w.starts(with: Array("0b".utf8)) else { return nil }
            return UInt64(String(decoding: w.dropFirst(2), as: UTF8.self), radix: 2)
        }
        for w in words {
            let word = text[w.start..<w.end]
            // Hex strings: 24 or more hex digits in one word, at both alignments.
            let digits = word.prefix { hexValue($0) != nil }
            if digits.count >= 2 * window {
                for skip in 0...1 {
                    let d = Array(digits.dropFirst(skip))
                    out.append(("hexstring", w.start, stride(from: 0, to: d.count - 1, by: 2).map {
                        UInt8(hexValue(d[$0])! << 4 | hexValue(d[$0 + 1])!)
                    }))
                }
            }
            // Base64: 16 or more base64 characters, at all four alignments.
            let b64 = word.drop { !isBase64($0) }.prefix(while: isBase64)
            if b64.count >= 16 {
                for skip in 0..<4 {
                    let s = Array(b64.dropFirst(skip))
                    let usable = s.count / 4 * 4
                    if let d = Data(base64Encoded: Data(s[0..<usable])) { out.append(("base64", w.start, [UInt8](d))) }
                }
            }
        }
        return out
    }

    static func isBase64(_ c: UInt8) -> Bool {
        (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c) || (0x30...0x39).contains(c) || c == 0x2B || c == 0x2F
    }

    // MARK: The scan

    /// The repository's own files: every file git tracks, plus everything under the tracked folders
    /// and the top-level files (so a file not added yet is scanned too), without build products
    /// and other ignored output.
    static func repositoryFiles() -> [URL] {
        let root = Original.repoRoot
        var files = ["Package.swift", "Makefile", "README.md", ".gitignore"].map { root.appendingPathComponent($0) }
        files += trackedFiles() ?? []
        for dir in ["Sources", "Tests", "Packaging", "Scripts", "re/docs", "re/sessions", "re/symbols.d", "re/tools", "re"] {
            let base = root.appendingPathComponent(dir)
            guard let items = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil,
                                                             options: dir == "re" ? [.skipsSubdirectoryDescendants] : [])
            else { continue }
            while let url = items.nextObject() as? URL {
                if !url.hasDirectoryPath && !url.lastPathComponent.hasPrefix(".") { files.append(url) }
            }
        }
        var seen = Set<String>()
        return files.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// `git ls-files` (nil when git cannot be run here).
    static func trackedFiles() -> [URL]? {
        git(["ls-files", "-z"])?.map { Original.repoRoot.appendingPathComponent($0) }
    }

    /// The NUL-separated paths a git listing command prints in the repository (`ls-files -z` and
    /// its options), relative to the repository's root; nil when git cannot be run here.
    static func git(_ arguments: [String]) -> [String]? {
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", Original.repoRoot.path] + arguments
        let out = Pipe()
        git.standardOutput = out
        git.standardError = FileHandle.nullDevice
        guard (try? git.run()) != nil else { return nil }
        let listing = out.fileHandleForReading.readDataToEndOfFile()
        git.waitUntilExit()
        guard git.terminationStatus == 0 else { return nil }
        return listing.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The matches in `raw` (named `name` in the report): the raw runs, then every encoding.
    static func scan(_ raw: [UInt8], name: String) -> [Match] {
        func line(_ offset: Int) -> Int { raw[..<min(offset, raw.count)].reduce(1) { $1 == 0x0A ? $0 + 1 : $0 } }
        var found: [Match] = []
        for span in spans(raw, skipDriveStatus: true) {
            found.append(Match(file: name, line: line(span.lowerBound), encoding: "raw", text: text(raw, span),
                               label: isAllowedLabel(raw, span)))
        }
        for e in encodings(raw) where !spans(e.bytes).isEmpty {
            found.append(Match(file: name, line: line(e.start), encoding: e.name))
        }
        return found
    }

    static func scan(_ url: URL) -> [Match] {
        guard let raw = try? [UInt8](Data(contentsOf: url)) else { return [] }
        return scan(raw, name: url.path.replacingOccurrences(of: Original.repoRoot.path + "/", with: ""))
    }

    @Test func noSubLogicBytesInTheRepository() throws {
        #expect(Self.windows.count > 50_000)
        let files = Self.repositoryFiles()
        #expect(files.count > 250, "\(files.count) files")
        let tracked = Set((Self.trackedFiles() ?? []).map(\.standardizedFileURL.path))
        #expect(tracked.isEmpty || tracked.isSubset(of: files.map(\.standardizedFileURL.path)),
                "every tracked file is scanned")
        let found = files.flatMap(Self.scan)
        let data = found.filter { $0.text == nil }
        #expect(data.isEmpty, "SubLogic bytes: \(data.prefix(20))")
        let quotes = found.filter { $0.text != nil && !$0.label && !$0.file.hasPrefix("re/") }
        #expect(quotes.isEmpty, "verbatim on-screen text outside re/ that is not an allowed label: \(quotes.prefix(20))")
        let labels = found.filter { $0.label && !$0.file.hasPrefix("re/") }
        let notes = found.filter { $0.text != nil && $0.file.hasPrefix("re/") }
        print("SubLogic bytes audit: \(files.count) files, no data; \(labels.count) quoted labels outside re/; "
              + "\(notes.count) quoted screen texts in re/")
        // An entry only this file's own list matches is one no other file needs any more.
        let needed = labels.filter { !$0.file.hasSuffix("/SubLogicBytesAuditTests.swift") }
        let unused = Self.allowedLabels.map(\.label).filter { label in !needed.contains { $0.text?.contains(label) == true } }
        if !unused.isEmpty { print("SubLogic bytes audit: allowed labels no other file needs any more: \(unused)") }
    }

    /// The binaries `FS2_AUDIT_BINARY` names (colon-separated; `make audit` passes the shipped app).
    static let auditedBinaries: [URL] = (ProcessInfo.processInfo.environment["FS2_AUDIT_BINARY"] ?? "")
        .split(separator: ":").map { URL(fileURLWithPath: String($0)) }

    /// The shipped app binary holds no run of the disk's bytes either: no table the compiler laid out
    /// from the port's constants, no copied text beyond the allowed labels its help and keyboard
    /// reference quote.
    @Test(.enabled(if: !auditedBinaries.isEmpty, "set FS2_AUDIT_BINARY (make audit)"))
    func noSubLogicBytesInTheShippedBinary() throws {
        for url in Self.auditedBinaries {
            let raw = try [UInt8](Data(contentsOf: url))
            #expect(raw.count > 100_000, "\(url.path) is a binary")
            let found = Self.spans(raw, skipDriveStatus: true).filter { !Self.isAllowedLabel(raw, $0) }
            let offsets = found.prefix(20).map { span in
                String(format: "0x%X", span.lowerBound) + (Self.text(raw, span).map { " \"\($0.prefix(48))\"" } ?? "")
            }
            #expect(found.isEmpty, "\(url.lastPathComponent): SubLogic bytes at file offsets \(offsets)")
        }
    }

    /// Every allowed label is short printable text that the game shows: at most 40 characters, no
    /// padding, listed once with the place it appears, and present on the disk.
    @Test func allowedLabelsAreShort() throws {
        #expect(Self.disk.count > 100_000)
        var seen = Set<String>()
        for (label, place) in Self.allowedLabels {
            let bytes = Array(label.utf8)
            #expect((1...40).contains(bytes.count), "\(label): \(bytes.count) characters")
            #expect(bytes.allSatisfy { (0x20...0x7E).contains($0) }, "\(label): printable text only")
            #expect(bytes.first != 0x20 && bytes.last != 0x20, "\(label): no padding")
            #expect(!place.isEmpty, "\(label): where it appears in the game")
            #expect(seen.insert(label).inserted, "\(label) is listed twice")
            let onDisk = Self.disk.withUnsafeBufferPointer { d in
                (0...(d.count - bytes.count)).contains { d[$0..<$0 + bytes.count].elementsEqual(bytes) }
            }
            #expect(onDisk, "\(label) is not on the disk")
        }
    }

    /// The scan finds the disk's bytes in every encoding it checks (a self-test on a run of the
    /// disk that is not written anywhere: it is taken from the disk at test time).
    @Test func scanFindsEveryEncoding() throws {
        let data = try #require(Original.data)
        let block = data.disk.blocks[20]
        let content = (0..<1000).filter { s in
            block.withUnsafeBufferPointer { p in (0...4).allSatisfy { !Self.isGeneric(p, s + $0) } }
        }
        let start = try #require(content.max { Set(block[$0..<$0 + 16]).count < Set(block[$1..<$1 + 16]).count })
        let run = Array(block[start..<start + 16])
        let samples: [(String, String)] = [
            ("hex8", "[" + run.map { String(format: "0x%02X", $0) }.joined(separator: ", ") + "]"),
            ("hex8", run.map { String(format: "$%02x", $0) }.joined(separator: " ")),
            ("decimal", run.map(String.init).joined(separator: ",")),
            ("hex16", stride(from: 0, to: 16, by: 2).map {
                String(format: "0x%04X", Int(run[$0]) | Int(run[$0 + 1]) << 8) }.joined(separator: ", ")),
            ("hex16-be", stride(from: 0, to: 16, by: 2).map {
                String(format: "$%04X", Int(run[$0]) << 8 | Int(run[$0 + 1])) }.joined(separator: " ")),
            ("hexstring", "\"" + run.map { String(format: "%02x", $0) }.joined() + "\""),
            ("base64", "\"" + Data([0x5A] + run).base64EncodedString() + "\""),
        ]
        for (name, text) in samples {
            let found = Self.encodings(Array(text.utf8)).contains { $0.name == name && !Self.spans($0.bytes).isEmpty }
            #expect(found, "\(name) not found")
        }
        #expect(!Self.spans(Array("xyz".utf8) + run).isEmpty, "raw not found")
        // What the filters let through is no content: counting tables and the drive status line.
        let counting = (0..<12).map { UInt8(0x1B + $0) }, words = (0..<6).flatMap { [UInt8(0), UInt8($0)] }
        #expect(counting.withUnsafeBufferPointer { Self.isGeneric($0, 0) })
        #expect(words.withUnsafeBufferPointer { Self.isGeneric($0, 0) })
        #expect(!run.withUnsafeBufferPointer { Self.isGeneric($0, 0) })
        #expect(Self.isDriveStatus(Array(",00,00\r".utf8)[...] + [0, 0, 0, 0, 0]))
        #expect(!Self.isDriveStatus(run[0..<12]))
    }

    /// The label allowance covers a label and nothing more: quoted in prose (or as a C string in a
    /// binary) it passes; the label with the disk's bytes around it, a longer text of the game, or
    /// a label quoted next to data fails. The texts come from the disk at test time.
    @Test func labelsAllowOnlyTheLabel() throws {
        let disk = Self.disk
        func flagged(_ bytes: [UInt8]) -> Bool {
            Self.scan(bytes, name: "sample").contains { !$0.label }
        }
        func allowed(_ bytes: [UInt8]) -> Bool {
            let found = Self.scan(bytes, name: "sample")
            return !found.isEmpty && found.allSatisfy(\.label)
        }
        let printable: (UInt8) -> Bool = { (0x20...0x7E).contains($0) }
        let padding: (UInt8) -> Bool = { $0 == 0x20 || $0 == 0 }
        /// The label at `start` (`count` bytes) with the disk's bytes up to the next window after it
        /// (or from the window before it) past its padding, when a window with content (not padding
        /// or fill bytes) reaches outside the label; nil when only padding and fill surround it.
        func runOn(_ start: Int, _ count: Int) -> [UInt8]? {
            var ranges: [Range<Int>] = []
            if let next = disk[(start + count)...].prefix(256).firstIndex(where: { !padding($0) }),
               next + Self.window <= disk.count {
                ranges.append(start..<next + Self.window)
            }
            if let previous = disk[..<start].suffix(256).lastIndex(where: { !padding($0) }), previous + 1 >= Self.window {
                ranges.append((previous + 1 - Self.window)..<(start + count))
            }
            for range in ranges {
                let sample = Array(disk[range]), label = (start - range.lowerBound)..<(start - range.lowerBound + count)
                let content = sample.withUnsafeBufferPointer { p in
                    (0...(p.count - Self.window)).contains { i in
                        !Self.isGeneric(p, i) && (i..<i + Self.window).contains { !label.contains($0) && !padding(p[$0]) }
                    }
                }
                if content { return sample }
            }
            return nil
        }
        var withNeighbors = 0, ranOn: [String] = []
        for (label, _) in Self.allowedLabels {
            let bytes = Array(label.utf8)
            let at = try #require((0...(disk.count - bytes.count)).first { disk[$0..<$0 + bytes.count].elementsEqual(bytes) })
            if bytes.count >= Self.window {
                // A label shorter than the window matches only with the disk's padding around it.
                #expect(allowed(Array("Answer \(label) with A or B.".utf8)), "\(label) in prose")
                #expect(allowed([0] + bytes + [0, 0]), "\(label) as a C string")
                // The label next to a run of the disk's code.
                let code = Array(disk[(20 * 1024)..<(20 * 1024 + 64)])
                #expect(flagged(bytes + code), "\(label) followed by data")
            }
            // The label with the game's text next to it on the disk (when there is more than padding).
            var lo = at, hi = at + bytes.count
            while lo > 0 && at - lo < 8 && printable(disk[lo - 1]) { lo -= 1 }
            while hi < disk.count && hi - at - bytes.count < 8 && printable(disk[hi]) { hi += 1 }
            if (disk[lo..<at] + disk[(at + bytes.count)..<hi]).contains(where: { $0 != 0x20 }) {
                #expect(flagged(Array(disk[lo..<hi])), "\(label) with the text next to it on the disk")
                withNeighbors += 1
            }
            // The label run on through its padding into the disk's bytes before or after it, at the
            // first occurrence where they hold more than padding and fill.
            let occurrences = (0...(disk.count - bytes.count)).lazy.filter { disk[$0..<$0 + bytes.count].elementsEqual(bytes) }
            if let sample = occurrences.compactMap({ runOn($0, bytes.count) }).first {
                #expect(flagged(sample), "\(label) run on into the disk's bytes around it")
                ranOn.append(label)
            }
        }
        #expect(withNeighbors > 0, "no label has text next to it on the disk")
        #expect(ranOn == Self.allowedLabels.map(\.label), "labels run on into the disk's bytes around them: \(ranOn)")
        // The disk's longest printable run, quoted whole, is not a label.
        var longest = 0..<0, s = 0
        for i in 0...disk.count {
            if i < disk.count && printable(disk[i]) { continue }
            if i - s > longest.count { longest = s..<i }
            s = i + 1
        }
        #expect(longest.count > 40)
        #expect(flagged(Array("\"".utf8) + Array(disk[longest]) + Array("\"".utf8)), "a long text of the game")
    }

    // MARK: Instruction listings

    /// 6502 addressing modes, as the listing pass tells them apart (accumulator forms count as implied).
    enum Mode: Hashable, Sendable { case imp, imm, zp, zpx, zpy, abs, abx, aby, ind, izx, izy, rel }

    /// The documented 6502 opcodes by mnemonic and addressing mode. The mnemonics are lowercase here
    /// so that the table is not a listing itself: the pass reads mnemonics in capitals only.
    static let opcodes: [String: [Mode: UInt8]] = [
        "adc": [.imm: 0x69, .zp: 0x65, .zpx: 0x75, .abs: 0x6D, .abx: 0x7D, .aby: 0x79, .izx: 0x61, .izy: 0x71],
        "and": [.imm: 0x29, .zp: 0x25, .zpx: 0x35, .abs: 0x2D, .abx: 0x3D, .aby: 0x39, .izx: 0x21, .izy: 0x31],
        "asl": [.imp: 0x0A, .zp: 0x06, .zpx: 0x16, .abs: 0x0E, .abx: 0x1E],
        "bcc": [.rel: 0x90], "bcs": [.rel: 0xB0], "beq": [.rel: 0xF0], "bmi": [.rel: 0x30],
        "bne": [.rel: 0xD0], "bpl": [.rel: 0x10], "bvc": [.rel: 0x50], "bvs": [.rel: 0x70],
        "bit": [.zp: 0x24, .abs: 0x2C], "brk": [.imp: 0x00],
        "clc": [.imp: 0x18], "cld": [.imp: 0xD8], "cli": [.imp: 0x58], "clv": [.imp: 0xB8],
        "cmp": [.imm: 0xC9, .zp: 0xC5, .zpx: 0xD5, .abs: 0xCD, .abx: 0xDD, .aby: 0xD9, .izx: 0xC1, .izy: 0xD1],
        "cpx": [.imm: 0xE0, .zp: 0xE4, .abs: 0xEC], "cpy": [.imm: 0xC0, .zp: 0xC4, .abs: 0xCC],
        "dec": [.zp: 0xC6, .zpx: 0xD6, .abs: 0xCE, .abx: 0xDE], "dex": [.imp: 0xCA], "dey": [.imp: 0x88],
        "eor": [.imm: 0x49, .zp: 0x45, .zpx: 0x55, .abs: 0x4D, .abx: 0x5D, .aby: 0x59, .izx: 0x41, .izy: 0x51],
        "inc": [.zp: 0xE6, .zpx: 0xF6, .abs: 0xEE, .abx: 0xFE], "inx": [.imp: 0xE8], "iny": [.imp: 0xC8],
        "jmp": [.abs: 0x4C, .ind: 0x6C], "jsr": [.abs: 0x20],
        "lda": [.imm: 0xA9, .zp: 0xA5, .zpx: 0xB5, .abs: 0xAD, .abx: 0xBD, .aby: 0xB9, .izx: 0xA1, .izy: 0xB1],
        "ldx": [.imm: 0xA2, .zp: 0xA6, .zpy: 0xB6, .abs: 0xAE, .aby: 0xBE],
        "ldy": [.imm: 0xA0, .zp: 0xA4, .zpx: 0xB4, .abs: 0xAC, .abx: 0xBC],
        "lsr": [.imp: 0x4A, .zp: 0x46, .zpx: 0x56, .abs: 0x4E, .abx: 0x5E],
        "nop": [.imp: 0xEA],
        "ora": [.imm: 0x09, .zp: 0x05, .zpx: 0x15, .abs: 0x0D, .abx: 0x1D, .aby: 0x19, .izx: 0x01, .izy: 0x11],
        "pha": [.imp: 0x48], "php": [.imp: 0x08], "pla": [.imp: 0x68], "plp": [.imp: 0x28],
        "rol": [.imp: 0x2A, .zp: 0x26, .zpx: 0x36, .abs: 0x2E, .abx: 0x3E],
        "ror": [.imp: 0x6A, .zp: 0x66, .zpx: 0x76, .abs: 0x6E, .abx: 0x7E],
        "rti": [.imp: 0x40], "rts": [.imp: 0x60],
        "sbc": [.imm: 0xE9, .zp: 0xE5, .zpx: 0xF5, .abs: 0xED, .abx: 0xFD, .aby: 0xF9, .izx: 0xE1, .izy: 0xF1],
        "sec": [.imp: 0x38], "sed": [.imp: 0xF8], "sei": [.imp: 0x78],
        "sta": [.zp: 0x85, .zpx: 0x95, .abs: 0x8D, .abx: 0x9D, .aby: 0x99, .izx: 0x81, .izy: 0x91],
        "stx": [.zp: 0x86, .zpy: 0x96, .abs: 0x8E], "sty": [.zp: 0x84, .zpx: 0x94, .abs: 0x8C],
        "tax": [.imp: 0xAA], "tay": [.imp: 0xA8], "tsx": [.imp: 0xBA], "txa": [.imp: 0x8A],
        "txs": [.imp: 0x9A], "tya": [.imp: 0x98],
    ]

    /// A mnemonic in capitals as a word, and what is written right after it as its operand (a
    /// number, a symbol, or a word of prose that ends up as no operand at all). The listing gate's
    /// assembler uses the same pattern, so both find the same runs.
    static func instructionPattern() -> NSRegularExpression {
        let mnemonics = opcodes.keys.sorted().map { $0.uppercased() }.joined(separator: "|")
        let operand = #"#?\(?[$%]?[0-9A-Za-z_+\-·'.]*\)?(?:,[XxYy]\)?)?(?:\),?[Yy])?"#
        return try! NSRegularExpression(pattern: #"\b("# + mnemonics + #")\b(?:[ \t]+("# + operand + "))?")
    }

    static func isHexDigit(_ c: Character) -> Bool { c.isASCII && c.isHexDigit }

    /// An operand's number: `$` and 1-4 hex digits, `%` and 1-8 binary digits, or 1-5 decimal
    /// digits; nil for anything else (a symbol).
    static func number(_ s: Substring) -> Int? {
        if s.hasPrefix("$") {
            let d = s.dropFirst()
            return (1...4).contains(d.count) && d.allSatisfy(isHexDigit) ? Int(d, radix: 16) : nil
        }
        if s.hasPrefix("%") {
            let d = s.dropFirst()
            return (1...8).contains(d.count) && d.allSatisfy({ $0 == "0" || $0 == "1" }) ? Int(d, radix: 2) : nil
        }
        return (1...5).contains(s.count) && s.allSatisfy({ $0.isASCII && $0.isNumber }) ? Int(s) : nil
    }

    /// One instruction's bytes, nil for each byte the text leaves open (a branch's target, an
    /// immediate written as a symbol); nil as a whole when the mnemonic has no such mode or the
    /// operand is no number (an address written as a symbol, or prose), which ends a run.
    static func assemble(_ mnemonic: String, _ operand: String) -> [UInt8?]? {
        guard let modes = opcodes[mnemonic.lowercased()] else { return nil }
        var op = Substring(operand.trimmingCharacters(in: .whitespaces))
        while let last = op.last, last == "." || last == "," { op = op.dropLast() }
        if op.isEmpty || op.uppercased() == "A" {
            if let o = modes[.imp] { return [o] }
            if let o = modes[.rel] { return [o, nil] }
            return nil
        }
        if let o = modes[.rel] { return [o, nil] }
        if op.hasPrefix("#") {
            guard let o = modes[.imm] else { return nil }
            return [o, number(op.dropFirst()).flatMap { $0 < 256 ? UInt8($0) : nil }]
        }
        let c = Array(op)
        func hex(_ r: Range<Int>) -> Int? {
            r.upperBound <= c.count && c[r].allSatisfy(isHexDigit) ? Int(String(c[r]), radix: 16) : nil
        }
        // Indirect: ($zp),Y, ($zp,X) or ($abs).
        if c.first == "(" {
            guard c.count == 7 && c[1] == "$" else { return nil }
            if c[4] == ")" && c[5] == "," && "Yy".contains(c[6]), let v = hex(2..<4) {
                return modes[.izy].map { [$0, UInt8(v)] }
            }
            if c[4] == "," && "Xx".contains(c[5]) && c[6] == ")", let v = hex(2..<4) {
                return modes[.izx].map { [$0, UInt8(v)] }
            }
            if c[6] == ")", let v = hex(2..<6) {
                return modes[.ind].map { [$0, UInt8(v & 0xFF), UInt8(v >> 8)] }
            }
            return nil
        }
        // Direct: $ and 1-4 hex digits, then ,X or ,Y; two digits or fewer is zero page when the
        // mnemonic has that mode.
        guard c.first == "$" else { return nil }
        var digits = 1..<c.count, index: Character?
        if c.count >= 3 && c[c.count - 2] == "," {
            index = Character(c[c.count - 1].lowercased())
            digits = 1..<(c.count - 2)
        }
        guard (1...4).contains(digits.count), index == nil || index == "x" || index == "y",
              let v = hex(digits) else { return nil }
        if digits.count <= 2, let o = modes[index == "x" ? .zpx : index == "y" ? .zpy : .zp] {
            return [o, UInt8(v)]
        }
        if let o = modes[index == "x" ? .abx : index == "y" ? .aby : .abs] {
            return [o, UInt8(v & 0xFF), UInt8(v >> 8)]
        }
        return nil
    }

    /// A byte string the listing pass searches, with where each byte value occurs in it.
    struct Corpus {
        let bytes: [UInt8]
        let at: [[Int32]]

        init(_ bytes: [UInt8]) {
            var at = [[Int32]](repeating: [], count: 256)
            for (i, b) in bytes.enumerated() { at[Int(b)].append(Int32(i)) }
            self.bytes = bytes
            self.at = at
        }
    }

    /// Where the listing pass looks: the disk's logical blocks in block order, and the memory image
    /// the boot loads them into (so that a run across the boundary of two loads counts too).
    static let corpora: [Corpus] = Original.data.map { [Corpus(Self.disk), Corpus($0.coldMemory)] } ?? []

    /// A run of instructions written in a file whose bytes are on the disk.
    struct ListingRun: CustomStringConvertible {
        var file: String, lines: ClosedRange<Int>, instructions: Int, known: Int
        var description: String {
            "\(file):\(lines.lowerBound)-\(lines.upperBound) (\(instructions) instructions, \(known) known bytes)"
        }
    }

    /// The runs of consecutive instructions in `text` whose bytes occur in one piece in a corpus and
    /// give at least `window` known bytes. Every mnemonic of the text counts, in order, whatever is
    /// written between two of them (code, prose, comment markers); one that cannot be assembled
    /// ends a run. Each run is the longest from its first instruction; the next starts after it.
    static func listingRuns(_ text: String, name: String, pattern: NSRegularExpression) -> [ListingRun] {
        // Line breaks as the listing gate reads them (CR LF and CR are breaks too).
        let text = text.utf8.contains(0x0D)
            ? text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") : text
        let ns = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [] }
        let tokens = matches.map { m -> (location: Int, bytes: [UInt8?]?) in
            let operand = m.range(at: 2).location == NSNotFound ? "" : ns.substring(with: m.range(at: 2))
            return (m.range.location, assemble(ns.substring(with: m.range(at: 1)), operand))
        }
        var breaks: [Int] = []
        for (i, u) in text.utf16.enumerated() where u == 0x0A { breaks.append(i) }
        /// The 1-based line of a UTF-16 offset: the line breaks before it, plus one.
        func line(_ location: Int) -> Int {
            var lo = 0, hi = breaks.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if breaks[mid] < location { lo = mid + 1 } else { hi = mid }
            }
            return lo + 1
        }
        var runs: [ListingRun] = []
        var i = 0
        while i < tokens.count {
            guard let first = tokens[i].bytes, let opcode = first[0] else { i += 1; continue }
            // The positions where the run so far starts, in each corpus.
            var starts = corpora.map { $0.at[Int(opcode)] }
            var length = 0, known = 0, best: (known: Int, end: Int)?
            var j = i
            while j < tokens.count, let bytes = tokens[j].bytes {
                var found = false
                for k in corpora.indices {
                    let corpus = corpora[k].bytes
                    starts[k] = starts[k].filter { start in
                        let at = Int(start) + length
                        guard at + bytes.count <= corpus.count else { return false }
                        for (n, b) in bytes.enumerated() { if let b, corpus[at + n] != b { return false } }
                        return true
                    }
                    found = found || !starts[k].isEmpty
                }
                if !found { break }
                length += bytes.count
                known += bytes.filter { $0 != nil }.count
                best = (known, j + 1)
                j += 1
            }
            if let best, best.known >= window {
                let lines = line(tokens[i].location)...line(tokens[best.end - 1].location)
                runs.append(ListingRun(file: name, lines: lines, instructions: best.end - i, known: best.known))
                i = best.end
            } else {
                i += 1
            }
        }
        return runs
    }

    /// No file of the repository holds the game's code as an instruction listing: no run of
    /// instructions written out (in a comment, a note or data) assembles to `window` or more known
    /// bytes that occur in one piece on the disk. Every tracked file is read whole, except the
    /// generic 6502 core and its tests (`Sources/M6502`, `Tests/M6502Tests`), whose tables and test
    /// programs are not the game's; in practice that is the comments of the Swift files and the
    /// notes (Markdown, JSON, text).
    @Test func noInstructionListingsOfTheDisk() throws {
        try #require(Self.corpora.count == 2 && Self.corpora[0].bytes.count > 100_000)
        let files = try #require(Self.git(["ls-files", "-z"]), "git ls-files")
            .filter { !$0.hasPrefix("Sources/M6502/") && !$0.hasPrefix("Tests/M6502Tests/") }
        #expect(files.count > 250, "\(files.count) files")
        let pattern = Self.instructionPattern()
        var runs: [ListingRun] = []
        for name in files {
            guard let data = FileManager.default.contents(atPath: Original.repoRoot.appendingPathComponent(name).path)
            else { continue }
            runs += Self.listingRuns(String(decoding: data, as: UTF8.self), name: name, pattern: pattern)
        }
        let perFile = Dictionary(grouping: runs, by: \.file).mapValues(\.count).sorted { $0.value > $1.value }
        print("Instruction-listing audit: \(files.count) files, \(runs.count) runs of \(Self.window)+ known bytes"
              + (perFile.isEmpty ? "" : ": " + perFile.map { "\($0.key) \($0.value)" }.joined(separator: ", ")))
        #expect(runs.isEmpty, "\(runs.count) instruction runs whose bytes are on the disk: \(runs.prefix(40))")
    }

    /// The listing pass finds a stretch of the disk's code written out as a listing, plain or in
    /// comments, and nothing once a word of prose follows every second instruction (the run ends
    /// before it reaches `window` known bytes). The listing is disassembled from the disk at test
    /// time with the inverse of `opcodes`; nothing of it is written here.
    @Test func listingPassFindsADisassembledRun() throws {
        try #require(!Self.corpora.isEmpty)
        let disk = Self.disk
        var decode: [UInt8: (mnemonic: String, mode: Mode)] = [:]
        for (mnemonic, modes) in Self.opcodes {
            for (mode, opcode) in modes { decode[opcode] = (mnemonic.uppercased(), mode) }
        }
        /// The instruction at `p` as a line of a listing, and its length.
        func instruction(at p: Int) -> (text: String, length: Int)? {
            guard let decoded = decode[disk[p]] else { return nil }
            let mode = decoded.mode
            let length: Int
            switch mode {
            case .imp: length = 1
            case .imm, .zp, .zpx, .zpy, .izx, .izy, .rel: length = 2
            case .abs, .abx, .aby, .ind: length = 3
            }
            guard p + length <= disk.count else { return nil }
            let byte = length > 1 ? Int(disk[p + 1]) : 0, word = length > 2 ? byte | Int(disk[p + 2]) << 8 : byte
            let operand: String
            switch mode {
            case .imp: operand = ""
            case .imm: operand = String(format: " #$%02X", byte)
            case .zp: operand = String(format: " $%02X", byte)
            case .zpx: operand = String(format: " $%02X,X", byte)
            case .zpy: operand = String(format: " $%02X,Y", byte)
            case .abs: operand = String(format: " $%04X", word)
            case .abx: operand = String(format: " $%04X,X", word)
            case .aby: operand = String(format: " $%04X,Y", word)
            case .ind: operand = String(format: " ($%04X)", word)
            case .izx: operand = String(format: " ($%02X,X)", byte)
            case .izy: operand = String(format: " ($%02X),Y", byte)
            case .rel: operand = " next"
            }
            return (decoded.mnemonic + operand, length)
        }
        // The first place in the main program (block 10 on) where 16 instructions in a row decode.
        var lines: [String] = []
        for start in (10 * 1024)..<(disk.count - 64) {
            var p = start
            lines = []
            while lines.count < 16, let next = instruction(at: p) {
                lines.append(next.text)
                p += next.length
            }
            if lines.count == 16 { break }
        }
        try #require(lines.count == 16)
        let pattern = Self.instructionPattern()
        let plain = Self.listingRuns(lines.joined(separator: "\n"), name: "plain", pattern: pattern)
        #expect(plain.count == 1 && plain.first?.lines == 1...16 && (plain.first?.known ?? 0) >= 16, "\(plain)")
        let commented = Self.listingRuns(lines.map { "    /// " + $0 + "    ; why" }.joined(separator: "\n"),
                                         name: "commented", pattern: pattern)
        #expect(commented.count == 1 && commented.first?.instructions == 16, "\(commented)")
        // A word written right after a mnemonic is taken as its operand; prose cannot be assembled.
        let word = "\n" + "rts".uppercased() + " here"
        let prose = lines.enumerated().map { $0.offset % 2 == 1 ? $0.element + word : $0.element }
        #expect(Self.listingRuns(prose.joined(separator: "\n"), name: "prose", pattern: pattern).isEmpty)
        // The assembler on its own: the operand forms, symbols and prose.
        #expect(Self.assemble("lda", "#$12") == [0xA9, 0x12] && Self.assemble("lda", "#value") == [0xA9, nil])
        #expect(Self.assemble("lda", "$12,X") == [0xB5, 0x12] && Self.assemble("lda", "$0012,X") == [0xBD, 0x12, 0x00])
        #expect(Self.assemble("ldx", "$12,Y") == [0xB6, 0x12] && Self.assemble("sta", "($12),Y") == [0x91, 0x12])
        #expect(Self.assemble("jmp", "($1234)") == [0x6C, 0x34, 0x12] && Self.assemble("bne", "loop") == [0xD0, nil])
        #expect(Self.assemble("asl", "A") == [0x0A] && Self.assemble("rts", "") == [0x60])
        #expect(Self.assemble("lda", "value") == nil && Self.assemble("rts", "here") == nil)
    }
}
