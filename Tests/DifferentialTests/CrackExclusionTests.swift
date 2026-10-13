import C64Kit
import Foundation
import FS2Core
import FS2Data
import Testing

/// The crack-exclusion audit (`re/docs/excluded.md`): nothing a crack added to the disk is shown,
/// kept in the images the port starts from, or named anywhere in the repository. The crack's text
/// is never written in this file either: it is read from the user's disk at test time.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"), .serialized)
struct CrackExclusionTests {
    /// Memory after the boot loads as the disk has it: `ColdImage.memory` without the scrub.
    static func unscrubbedMemory(_ disk: SubLogicDisk) -> [UInt8] {
        var mem = [UInt8](repeating: 0, count: 0x10000)
        ColdImage.load(FS2Layout.stage2, from: disk, into: &mem)
        ColdImage.load(FS2Layout.stage3, from: disk, into: &mem)
        for l in FS2Layout.bootLoads { ColdImage.load(l, from: disk, into: &mem) }
        return mem
    }

    /// Bytes as text: screen codes $01-$1A as capitals, printable ASCII as itself, anything else a space.
    static func text(_ bytes: some Collection<UInt8>) -> String {
        String(bytes.map { b -> Character in
            switch b {
            case 0x01...0x1A: Character(UnicodeScalar(b + 0x40))
            case 0x20...0x7E: Character(UnicodeScalar(b))
            default: " "
            }
        })
    }

    /// Whether a character is an ASCII letter.
    static func isLetter(_ c: Character) -> Bool { c.isASCII && c.isLetter }

    /// The words of `text` (runs of ASCII letters) of at least `minimum` letters, lowercased.
    static func words(_ text: String, minimum: Int) -> [String] {
        text.split(whereSeparator: { !isLetter($0) }).filter { $0.count >= minimum }.map { $0.lowercased() }
    }

    /// Every scrub range holds the crack's bytes on the disk (so the ranges are the right ones), and
    /// only spaces in the cold image, the cold-start overlay and the stage-2 handoff the port boots.
    @Test(.enabled(if: Original.isModifiedCopy, "needs a modified copy: the check reads its additions from the image"))
    func scrubRemovesEveryCrackByte() throws {
        let data = try #require(Original.data)
        let raw = Self.unscrubbedMemory(data.disk)
        let handoff = Machine.bootMemory(blocks: data.disk.blocks)
        let overlay = data.overlay(.coldStart)
        for range in ColdImage.crackRanges {
            #expect(range.contains { raw[$0] != 0x20 }, "the disk has only spaces at \(hex16(range.lowerBound))")
            #expect(range.allSatisfy { data.coldMemory[$0] == 0x20 }, "cold image at \(hex16(range.lowerBound))")
            if range.lowerBound >= FS2Layout.stage3.address {
                #expect(range.allSatisfy { handoff[$0] == 0x20 }, "handoff at \(hex16(range.lowerBound))")
                #expect(range.allSatisfy { overlay[$0 - FS2Layout.stage3.address] == 0x20 },
                        "overlay 0 at \(hex16(range.lowerBound))")
            }
        }
    }

    /// What the crack wrote, read from the disk and lowercased: its two title records, every word of
    /// six letters or more from them, every word of four letters or more of the boot banner it added
    /// (track 18 sector 2, outside the logical blocks), and its 3-letter tag.
    struct CrackNames {
        var records: [String], words: Set<String>, banner: Set<String>, tag: String
    }

    static func crackNames(_ data: GameData) throws -> CrackNames {
        let raw = Self.unscrubbedMemory(data.disk)
        let ranges = ColdImage.crackRanges
        let records = ranges.prefix(2).map { Self.text($0.map { raw[$0] }).trimmingCharacters(in: .whitespaces) }
        let tag = Self.text(ranges[2].map { raw[$0] }).trimmingCharacters(in: .whitespaces)
        try #require(records.allSatisfy { $0.count >= 12 } && tag.count == 3)
        let words = Set(records.flatMap { Self.words($0, minimum: 6) })
        let banner = Set(Self.words(Self.text(try data.d64.sector(track: 18, sector: 2)), minimum: 4))
        try #require(!words.isEmpty && !banner.isEmpty)
        return CrackNames(records: records.map { $0.lowercased() }, words: words, banner: banner, tag: tag.lowercased())
    }

    /// What `text` names of the crack, in any letter case: "record", "record word", "banner word", "tag".
    static func hits(_ text: some StringProtocol, _ names: CrackNames) -> [String] {
        let line = text.lowercased()
        var kinds: [String] = []
        if names.records.contains(where: { line.contains($0) }) { kinds.append("record") }
        if names.words.contains(where: { line.contains($0) }) { kinds.append("record word") }
        if names.banner.contains(where: { line.contains($0) }) { kinds.append("banner word") }
        // The tag as a word: no ASCII letter right before or after it.
        var rest = line[...]
        while let r = rest.range(of: names.tag) {
            let before = r.lowerBound > line.startIndex ? line[line.index(before: r.lowerBound)] : " "
            let after = r.upperBound < line.endIndex ? line[r.upperBound] : " "
            if !isLetter(before) && !isLetter(after) { kinds.append("tag"); break }
            rest = line[r.upperBound...]
        }
        return kinds
    }

    /// No file of the repository names the crack: neither its title records, nor any word of six
    /// letters or more from them, nor any word of four letters or more of its boot banner, nor its
    /// tag as a word, in any letter case. Every file git tracks is checked (and any file not added
    /// yet that git does not ignore), the reverse-engineering notes under `re/` included: they are
    /// published with the rest, so they describe the crack's additions without naming them.
    @Test(.enabled(if: Original.isModifiedCopy, "needs a modified copy: the check reads its additions from the image"))
    func repositoryNeverNamesTheCrack() throws {
        let names = try Self.crackNames(try #require(Original.data))
        let tracked = try #require(SubLogicBytesAuditTests.git(["ls-files", "-z"]), "git ls-files")
        let untracked = SubLogicBytesAuditTests.git(["ls-files", "-z", "--others", "--exclude-standard"]) ?? []
        let files = Array(Set(tracked + untracked)).sorted()
        #expect(files.count > 300, "\(files.count) files")
        var found: [String] = []
        for name in files {
            let url = Original.repoRoot.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = text.split(omittingEmptySubsequences: false,
                                   whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
            for (n, line) in lines.enumerated() {
                let kinds = Self.hits(line, names)
                if !kinds.isEmpty { found.append("\(name):\(n + 1) [\(kinds.joined(separator: ", "))]") }
            }
        }
        print("Crack exclusion audit: \(files.count) files, \(found.count) lines name the crack")
        #expect(found.isEmpty, "\(found.count) lines name the crack: \(found.prefix(40))")
    }

    /// The check finds each kind of name in any letter case, and the tag only as a word. The samples
    /// are built from the disk at test time.
    @Test(.enabled(if: Original.isModifiedCopy, "needs a modified copy: the check reads its additions from the image"))
    func checkFindsEveryKindOfName() throws {
        let names = try Self.crackNames(try #require(Original.data))
        for word in names.words {
            #expect(Self.hits("x " + word.uppercased() + " y", names).contains("record word"))
            #expect(Self.hits("x" + word.capitalized + "y", names).contains("record word"))
        }
        for word in names.banner {
            #expect(Self.hits("(" + word.uppercased() + ")", names).contains("banner word"))
        }
        #expect(Self.hits("// the " + names.tag.uppercased() + ": ", names).contains("tag"))
        #expect(Self.hits("`" + names.tag + "`", names).contains("tag"))
        #expect(!Self.hits("// the x" + names.tag + "y", names).contains("tag"), "the tag inside a longer word")
        #expect(Self.hits(names.records[0].uppercased(), names).contains("record"))
        #expect(Self.hits("nothing here", names).isEmpty)
    }

    /// The title the native engine presents: the title and version on top, then nothing where the
    /// crack's two records were (window rows 28-43), then the display prompt. Checked at the boot
    /// and again after a RUN/STOP + RESTORE restart, which reloads overlay 0 and repeats the boot
    /// loads from the disk's unscrubbed blocks; at both title prompts every scrubbed byte is a space.
    @Test(.enabled(if: Original.isModifiedCopy, "needs a modified copy: the check reads its additions from the image"))
    func titleFrameHasBlankCrackRows() throws {
        let data = try #require(Original.data)
        let engine = NativeEngine(data: data, modeLibrary: ModeLibrary.InMemoryStore().io)
        let session = NativeEngineThreadTests.session
        // The steps up to the title again after the restart (the boot's title is the first key wait).
        let titles = session.indices.filter {
            if case .keyWait(maxFrames: 9000) = session[$0] { return true } else { return false }
        }
        try #require(titles.count == 2 && titles[0] == 0)
        let frame = VirtualClock.cyclesPerFrame
        for (k, step) in session.prefix(through: titles[1]).enumerated() {
            switch step {
            case .keyWait(let maxFrames):
                #expect(engine.runToKeyWait(maxFrames: maxFrames, deliverFrames: false), "key wait at step \(k)")
            case .frames(let n, let input):
                engine.run(untilCycle: (engine.cycles / frame + n) * frame)
                engine.input = input
            }
            if titles.contains(k) { try Self.expectBlankCrackRows(engine, title: k == 0 ? "boot" : "restart") }
        }
        #expect(engine.machine.u16(0xA7E0) == 0xAD00, "overlay 0 is resident at the second title")
    }

    /// At a title prompt: the scrubbed bytes are spaces in memory and the crack's rows are blank.
    static func expectBlankCrackRows(_ engine: NativeEngine, title: String,
                                     sourceLocation: SourceLocation = #_sourceLocation) throws {
        for range in ColdImage.crackRanges {
            #expect(range.allSatisfy { engine.machine.mem[$0] == 0x20 },
                    "\(title) title: memory at \(hex16(range.lowerBound))", sourceLocation: sourceLocation)
        }
        var last: FrameOutput?
        engine.onFrame = { last = $0 }
        engine.run(untilCycle: engine.cycles + 10 * VirtualClock.cyclesPerFrame)
        engine.onFrame = nil
        let frame = try #require(last, sourceLocation: sourceLocation)
        // Window row r is raster line $33 + r; the 320 window columns start at frame column 32.
        func row(_ r: Int) -> ArraySlice<UInt8> {
            let y = (0x33 + r - VICPresenter.firstRasterLine + VICPresenter.rasterLines) % VICPresenter.rasterLines
            return frame.pixels[(y * VICPresenter.width + 32)..<(y * VICPresenter.width + 352)]
        }
        let background = try #require(row(0).first, sourceLocation: sourceLocation)
        #expect(row(0).allSatisfy { $0 == background }, "\(title) title: window row 0 is background",
                sourceLocation: sourceLocation)
        #expect((12...16).contains { row($0).contains { $0 != background } }, "\(title) title: the title is drawn",
                sourceLocation: sourceLocation)
        for r in 28..<44 {
            #expect(row(r).allSatisfy { $0 == background }, "\(title) title: window row \(r) is drawn",
                    sourceLocation: sourceLocation)
        }
        #expect((50...54).contains { row($0).contains { $0 != background } },
                "\(title) title: the display prompt is drawn", sourceLocation: sourceLocation)
    }

    /// The shipped app binary (`FS2_AUDIT_BINARY`, set by `make audit`) names nothing of the crack
    /// either: no title record and no word of six letters or more from them, in any letter case.
    @Test(.enabled(if: !SubLogicBytesAuditTests.auditedBinaries.isEmpty, "set FS2_AUDIT_BINARY (make audit)"),
          .enabled(if: Original.isModifiedCopy, "needs a modified copy: the check reads its additions from the image"))
    func shippedBinaryNeverNamesTheCrack() throws {
        let names = try Self.crackNames(try #require(Original.data))
        for url in SubLogicBytesAuditTests.auditedBinaries {
            let raw = try Data(contentsOf: url)
            #expect(raw.count > 100_000, "\(url.path) is a binary")
            // ASCII capitals lowercased, so one search covers every letter case.
            let lowered = Data(raw.map { (0x41...0x5A).contains($0) ? $0 | 0x20 : $0 })
            for needle in names.records + names.words.sorted() {
                #expect(lowered.range(of: Data(needle.utf8)) == nil, "\(url.lastPathComponent) names the crack")
            }
        }
    }
}
