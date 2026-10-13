import C64Kit
import Foundation
import FS2Data
import Testing

enum TestDisk {
    /// The disk image: $FS2_D64, else the app's import (~/Library/Application Support/FS2/FlightSimulatorII.d64).
    static let image: D64Image? = {
        var candidates: [URL] = []
        if let p = ProcessInfo.processInfo.environment["FS2_D64"] { candidates.append(URL(fileURLWithPath: p)) }
        candidates.append(GameData.importedDiskURL)
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let image = try? D64Image(contentsOf: url) { return image }
        }
        return nil
    }()

    /// Whether the image is a modified copy (the patches the import scrubs are on it); a clean
    /// image of the original disk is not.
    static let isModifiedCopy: Bool = image.flatMap { try? GameData(d64: $0) }.map {
        ColdImage.crackPresent(in: DiskValidationTests.rawMemory($0.disk))
    } ?? false
}

/// The disk check and the crack scrub (`SubLogicDisk.mismatchedBlocks`, `ColdImage.scrubCrack`):
/// the user's disk validates, and a modified copy (title records overwritten, the disk-error line
/// tagged) is scrubbed; a clean copy (the crack's bytes replaced by others) validates and keeps its
/// own bytes; any other change is rejected and named. The disk is read at test time and the
/// variants are built in memory; nothing of it is written here.
@Suite(.enabled(if: TestDisk.image != nil, "needs the Flight Simulator II disk image"))
struct DiskValidationTests {
    static var image: D64Image? { TestDisk.image }

    /// The byte offset in the .d64 file of offset `offset` of logical block `block`.
    static func fileOffset(block: Int, offset: Int) -> Int {
        let (track, sector) = SubLogicDisk.usedSectors[block * 4 + offset / 256]
        return D64Image.offset(track: track, sector: sector) + offset % 256
    }

    /// The image with `change` applied to its bytes.
    static func variant(_ change: (inout [UInt8]) -> Void) throws -> D64Image {
        var bytes = try #require(image).bytes
        change(&bytes)
        return try D64Image(data: bytes)
    }

    /// A stand-in for what a clean disk has where the crack wrote: letters that are not the crack's.
    static func cleanByte(_ i: Int) -> UInt8 { UInt8(0x41 + i % 26) }

    /// Every crack-modified byte replaced by `cleanByte`, `i` counting from 0 in each block on
    /// through its masked ranges (so the two tag slots of block 13 hold different letters), as a
    /// clean copy would differ there.
    static func cleanImage(only blocks: Set<Int>? = nil) throws -> D64Image {
        try variant { bytes in
            var count: [Int: Int] = [:]
            for (block, offsets) in SubLogicDisk.crackModifiedBytes where blocks?.contains(block) ?? true {
                for o in offsets {
                    bytes[fileOffset(block: block, offset: o)] = cleanByte(count[block, default: 0])
                    count[block, default: 0] += 1
                }
            }
        }
    }

    /// Memory after the boot loads, as the disk has it (no scrub).
    static func rawMemory(_ disk: SubLogicDisk) -> [UInt8] {
        var mem = [UInt8](repeating: 0, count: 0x10000)
        ColdImage.load(FS2Layout.stage2, from: disk, into: &mem)
        ColdImage.load(FS2Layout.stage3, from: disk, into: &mem)
        for l in FS2Layout.bootLoads { ColdImage.load(l, from: disk, into: &mem) }
        return mem
    }

    /// The masked ranges are where the documentation says they load: stage 2 $7835-$7897,
    /// overlay 0 $A839-$A87D and $AAF7-$AAF9, and the $0200 load's $0E91-$0E93 and $0EAF-$0EB1.
    @Test func maskedRangesLoadAtTheDocumentedAddresses() {
        func address(_ load: FS2Layout.Load, _ block: Int, _ offset: Int) -> Int {
            load.address + (block - load.block) * SubLogicDisk.blockSize + offset
        }
        let m = SubLogicDisk.crackModifiedBytes
        #expect(m.count == 5)
        #expect(address(FS2Layout.stage2, m[0].block, m[0].offsets.lowerBound) == 0x7835)
        #expect(address(FS2Layout.stage2, m[0].block, m[0].offsets.upperBound) == 0x7897)
        #expect(address(FS2Layout.stage3, m[1].block, m[1].offsets.lowerBound) == 0xA839)
        #expect(address(FS2Layout.stage3, m[1].block, m[1].offsets.upperBound) == 0xA87D)
        #expect(address(FS2Layout.stage3, m[2].block, m[2].offsets.lowerBound) == 0xAAF7)
        #expect(address(FS2Layout.stage3, m[2].block, m[2].offsets.upperBound) == 0xAAF9)
        let main = FS2Layout.bootLoads[0]
        #expect(address(main, m[3].block, m[3].offsets.lowerBound) == 0x0E91)
        #expect(address(main, m[3].block, m[3].offsets.upperBound) == 0x0E93)
        #expect(address(main, m[4].block, m[4].offsets.lowerBound) == 0x0EAF)
        #expect(address(main, m[4].block, m[4].offsets.upperBound) == 0x0EB1)
        // The scrub detects exactly what the check masks.
        #expect(ColdImage.crackPatches.flatMap(\.detect) == [0xA839...0xA87D, 0x0E91...0x0E93, 0x0EAF...0x0EB1])
        #expect(ColdImage.crackPatches.flatMap(\.blank) == ColdImage.crackRanges)
    }

    /// Why stage 2's drive-status check is masked: its copy in block 1 and the copy the boot's $77E0
    /// load brings back (block 26) differ only at $783B (query 3's expected status), probably the
    /// crack's patch to the copy the boot runs; the compare at $7876 is the same in both. Block 26 is
    /// not masked (its $7876 is one of the positions `anyOtherChangeIsRejected` changes).
    @Test func stageTwoCheckDiffersFromItsReloadedCopyOnlyAt783B() throws {
        let disk = try SubLogicDisk(try #require(Self.image))
        let reload = FS2Layout.bootLoads[2]
        #expect(reload.address == 0x77E0 && reload.block == 26)
        let stage2 = disk.block(1), copy = disk.block(26)
        // Block 1 is $7700-$7AFF; block 26 starts at $77E0.
        let differ = (0x77E0...0x7AFF).filter { stage2[$0 - 0x7700] != copy[$0 - 0x77E0] }
        #expect(differ == [0x783B])
        let masked = SubLogicDisk.crackModifiedBytes[0]
        #expect(masked.block == 1 && masked.offsets.contains(0x783B - 0x7700) && masked.offsets.contains(0x7876 - 0x7700))
        #expect(!SubLogicDisk.crackModifiedBytes.contains { $0.block == 26 })
    }

    /// The user's disk, a modified copy: every block matches, the crack's patches are on it, and the
    /// cold image and overlay 0 have them blanked to spaces.
    @Test(.enabled(if: TestDisk.isModifiedCopy, "needs a modified copy of the disk"))
    func modifiedCopyValidatesAndIsScrubbed() throws {
        let data = try GameData(d64: try #require(Self.image))
        #expect(data.disk.mismatchedBlocks().isEmpty)
        let raw = Self.rawMemory(data.disk)
        for patch in ColdImage.crackPatches {
            #expect(patch.blank.allSatisfy { r in r.contains { raw[$0] != 0x20 } }, "the crack is on the disk")
        }
        #expect(ColdImage.crackPresent(in: raw))
        for r in ColdImage.crackRanges {
            #expect(r.allSatisfy { data.coldMemory[$0] == 0x20 }, "cold image at \(r.lowerBound)")
        }
        #expect(!ColdImage.crackPresent(in: data.coldMemory))
        let overlay = data.overlay(.coldStart)
        for r in ColdImage.crackRanges where r.lowerBound >= FS2Layout.overlayBase {
            #expect(r.allSatisfy { overlay[$0 - FS2Layout.overlayBase] == 0x20 })
        }
        // Everything else above zero page is the disk's.
        let blanked = Set(ColdImage.crackRanges.flatMap { $0 })
        let differ = (0x0100..<0x10000).filter { !blanked.contains($0) && raw[$0] != data.coldMemory[$0] }
        #expect(differ.isEmpty, "only the crack's bytes are changed above zero page")
        // The scrub is idempotent.
        var again = data.coldMemory
        ColdImage.scrubCrack(&again)
        #expect(again == data.coldMemory)
    }

    /// A clean copy: the crack-modified bytes are other bytes. It validates, nothing is detected,
    /// and the cold image and overlay 0 keep its bytes (its own title lines and disk-error line).
    @Test func cleanDiskValidatesAndIsNotScrubbed() throws {
        let clean = try GameData(d64: try Self.cleanImage())
        #expect(clean.disk.mismatchedBlocks().isEmpty)
        let raw = Self.rawMemory(clean.disk)
        #expect(!ColdImage.crackPresent(in: raw))
        // The ranges the scrub would blank keep the clean disk's bytes (each patch's ranges are the
        // first masked ones of their block, so `cleanImage` counts through them in this order).
        for patch in ColdImage.crackPatches {
            for (i, a) in patch.detect.joined().enumerated() {
                #expect(clean.coldMemory[a] == Self.cleanByte(i), "cold image at \(a)")
            }
        }
        #expect(clean.coldMemory[0x100...] == raw[0x100...], "the cold image is the disk's above zero page")
        let overlay = clean.overlay(.coldStart)
        for (i, a) in (0xA839...0xA87D).enumerated() {
            #expect(overlay[a - FS2Layout.overlayBase] == Self.cleanByte(i))
        }
        // A 64 KB image in memory the caller owns (the port's) is left alone too.
        var mem = raw
        mem.withUnsafeMutableBufferPointer { ColdImage.scrubCrack(memory: $0.baseAddress!) }
        #expect(mem == raw)
    }

    /// Each patch is detected on its own: a disk with the clean title records but the crack's tags
    /// keeps the records and loses the tags.
    @Test func eachPatchIsDetectedOnItsOwn() throws {
        let data = try GameData(d64: try Self.cleanImage(only: [2]))
        #expect(data.disk.mismatchedBlocks().isEmpty)
        for (i, a) in (0xA839...0xA87D).enumerated() { #expect(data.coldMemory[a] == Self.cleanByte(i)) }
        for r in ColdImage.crackRanges where r.lowerBound < 0x1000 {
            #expect(r.allSatisfy { data.coldMemory[$0] == 0x20 }, "the crack's tags are blanked")
        }
        #expect(!ColdImage.crackPresent(in: data.coldMemory))
    }

    /// One changed byte anywhere outside the masked ranges, including right next to them and in the
    /// rest of the masked blocks, is rejected, and the error names the block.
    @Test func anyOtherChangeIsRejected() throws {
        var positions: [(block: Int, offset: Int)] = [(0, 100), (26, 0x96), (163, 1023), (65, 0)]
        for (block, offsets) in SubLogicDisk.crackModifiedBytes {
            positions.append((block, offsets.lowerBound - 1))
            positions.append((block, offsets.upperBound + 1))
        }
        for (block, offset) in positions {
            for base in [try #require(Self.image), try Self.cleanImage()] {
                var bytes = base.bytes
                bytes[Self.fileOffset(block: block, offset: offset)] ^= 0x01
                let image = try D64Image(data: bytes)
                #expect(try SubLogicDisk(image).mismatchedBlocks() == [block])
                let error = #expect(throws: GameData.Error.self, "block \(block) offset \(offset) changed") {
                    try GameData(d64: image)
                }
                if case .notFlightSimulatorII(let mismatched)? = error { #expect(mismatched == [block]) }
                #expect(error?.description == "this disk does not match Flight Simulator II v1.0: block \(block) "
                        + "differs (1 of 164)")
            }
        }
        // Several blocks.
        let many = try Self.variant { bytes in
            for block in [3, 7, 12] { bytes[Self.fileOffset(block: block, offset: 512)] ^= 0x80 }
        }
        #expect(throws: GameData.Error.self) { try GameData(d64: many) }
        #expect(GameData.Error.notFlightSimulatorII(mismatched: [3, 7, 12]).description
                == "this disk does not match Flight Simulator II v1.0: blocks 3, 7, 12 differ (3 of 164)")
        #expect(GameData.Error.notFlightSimulatorII(mismatched: Array(0..<10)).description
                == "this disk does not match Flight Simulator II v1.0: blocks 0, 1, 2, 3, 4, 5, 6, 7, … differ (10 of 164)")
    }
}

/// The rule that recognizes the tag on the disk-error line without knowing it: both 3-byte slots,
/// $0E91-$0E93 and $0EAF-$0EB1, hold the same three letters (screen codes $01-$1A or ASCII A-Z).
/// Built in memory with letters computed here; needs no disk.
@Suite struct CrackTagRuleTests {
    static let slots = [0x0E91...0x0E93, 0x0EAF...0x0EB1]

    /// 64 KB of spaces (the clean line has spaces where a tag would be) with `left` and `right` in
    /// the two slots.
    static func memory(_ left: [UInt8], _ right: [UInt8]) -> [UInt8] {
        var mem = [UInt8](repeating: 0x20, count: 0x10000)
        for (slot, bytes) in zip(slots, [left, right]) {
            for (a, b) in zip(slot, bytes) { mem[a] = b }
        }
        return mem
    }

    /// Three letters from `seed`, as ASCII capitals or as screen codes.
    static func letters(_ seed: Int, screenCodes: Bool = false) -> [UInt8] {
        (0..<3).map { UInt8((screenCodes ? 0x01 : 0x41) + (seed * 7 + $0 * 11) % 26) }
    }

    /// Whether the scrub blanks the slots, and that it changes nothing else.
    static func scrubbed(_ left: [UInt8], _ right: [UInt8]) -> Bool {
        let before = memory(left, right)
        var after = before
        ColdImage.scrubCrack(&after)
        let blank = slots.allSatisfy { $0.allSatisfy { after[$0] == 0x20 } }
        let elsewhere = (0..<0x10000).filter { a in !slots.contains { $0.contains(a) } && after[a] != before[a] }
        #expect(elsewhere.isEmpty)
        #expect(ColdImage.crackPresent(in: before) == (before != after))
        #expect(!ColdImage.crackPresent(in: after))
        return blank && before != after
    }

    @Test func sameLettersInBothSlotsAreBlanked() {
        for seed in 0..<26 {
            #expect(Self.scrubbed(Self.letters(seed), Self.letters(seed)), "ASCII, seed \(seed)")
            #expect(Self.scrubbed(Self.letters(seed, screenCodes: true), Self.letters(seed, screenCodes: true)),
                    "screen codes, seed \(seed)")
        }
    }

    @Test func anythingElseIsLeftAlone() {
        let spaces = [UInt8](repeating: 0x20, count: 3)
        #expect(!Self.scrubbed(spaces, spaces), "a clean line")
        #expect(!Self.scrubbed(Self.letters(1), Self.letters(2)), "different letters")
        #expect(!Self.scrubbed(Self.letters(3), spaces), "letters in one slot only")
        #expect(!Self.scrubbed(spaces, Self.letters(3)), "letters in the other slot only")
        #expect(!Self.scrubbed(Self.letters(4), Self.letters(4, screenCodes: true)),
                "the same letters, encoded differently")
        let digits: [UInt8] = [0x31, 0x39, 0x38]
        #expect(!Self.scrubbed(digits, digits), "digits")
        var mixed = Self.letters(5)
        mixed[1] = 0x2A
        #expect(!Self.scrubbed(mixed, mixed), "a letter replaced by punctuation")
        var lower = Self.letters(6)
        lower[2] |= 0x20
        #expect(!Self.scrubbed(lower, lower), "a lowercase ASCII letter")
        #expect(!Self.scrubbed([0, 0, 0], [0, 0, 0]), "zeros (memory before the loads)")
    }
}
