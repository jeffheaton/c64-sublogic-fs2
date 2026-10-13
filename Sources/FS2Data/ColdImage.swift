import C64Kit

/// Builds the memory image as SubLogic's boot leaves it, just before the init chain at $A970,
/// with every byte a crack added replaced by what belongs there.
public enum ColdImage {
    public static func load(_ load: FS2Layout.Load, from disk: SubLogicDisk, into mem: inout [UInt8]) {
        for i in 0..<load.count {
            let a = load.address + i * SubLogicDisk.blockSize
            let b = disk.block(load.block + i)
            for j in 0..<SubLogicDisk.blockSize where a + j < 0x10000 { mem[a + j] = b[j] }
        }
    }

    /// 64 KB: stage 2 at $7300, stage 3 at $A7E0, the five boot loads, zero page from $AC02.
    public static func memory(from disk: SubLogicDisk) -> [UInt8] {
        var mem = [UInt8](repeating: 0, count: 0x10000)
        load(FS2Layout.stage2, from: disk, into: &mem)
        load(FS2Layout.stage3, from: disk, into: &mem)
        for l in FS2Layout.bootLoads { load(l, from: disk, into: &mem) }
        for a in 2..<0x100 { mem[a] = mem[FS2Layout.zeroPageImage - 2 + a] }
        scrubCrack(&mem)
        return mem
    }

    /// An overlay's bytes as they appear at $A7E0 (with the crack scrub applied to the cold-start overlay).
    public static func overlay(_ o: FS2Layout.Overlay, from disk: SubLogicDisk) -> [UInt8] {
        var mem = [UInt8](repeating: 0, count: 0x10000)
        load(o.load, from: disk, into: &mem)
        if o == .coldStart { scrubCrack(&mem) }
        let l = o.load
        return Array(mem[l.address..<(l.address + l.count * SubLogicDisk.blockSize)])
    }

    /// A crack can overwrite two title records and tag the editor's disk-error line. What the title
    /// records held before is not on such a copy, so their characters become spaces (the records
    /// still exist so the list structure is unchanged; spaces draw nothing on a cleared view).
    /// `re/docs/excluded.md` describes the ranges; nothing in the repository names what is there.
    public static let crackRanges: [ClosedRange<Int>] = [
        0xA83B...0xA859,   // y=28 x=8: the text of the first title record the crack inserted
        0xA85D...0xA87C,   // y=36 x=7: the text of the second one
        0x0E91...0x0E93,   // the crack's tag before the editor's disk-error message
        0x0EAF...0x0EB1,   // and after it
    ]

    /// One thing the crack wrote: the memory it occupies, the rule that recognizes it there, and the
    /// bytes the scrub blanks when it is there.
    public struct CrackPatch: Sendable {
        /// How the crack's bytes in `detect` are recognized.
        enum Rule: Sendable {
            /// The first 8 bytes of the SHA-256 of the bytes in `detect`, in order: a hash over both
            /// whole records (69 bytes), not their content.
            case hash(String)
            /// Every range in `detect` holds the same letters, screen codes $01-$1A or ASCII A-Z
            /// (a tag written on both sides of a line). Encodes nothing of the letters themselves.
            case sameLetters
        }

        /// The ranges whose bytes identify the crack's version (`SubLogicDisk.crackModifiedBytes`).
        public let detect: [ClosedRange<Int>]
        /// The ranges blanked to spaces (`crackRanges`).
        public let blank: [ClosedRange<Int>]
        let rule: Rule
    }

    /// The crack's two patches the scrub undoes: the title records $A839-$A87D (overlay 0) and the
    /// two tags of the disk-error line, $0E91-$0E93 and $0EAF-$0EB1 (the $0200 load). Each is
    /// blanked only when its bytes are the crack's, so a clean disk keeps SubLogic's original title
    /// lines and disk-error line (spaces where a tag would be).
    public static let crackPatches: [CrackPatch] = [
        CrackPatch(detect: [0xA839...0xA87D], blank: [crackRanges[0], crackRanges[1]],
                   rule: .hash("ca1388849bf530d4")),
        CrackPatch(detect: [0x0E91...0x0E93, 0x0EAF...0x0EB1], blank: [crackRanges[2], crackRanges[3]],
                   rule: .sameLetters),
    ]

    /// A letter as a screen code ($01-$1A) or in ASCII (A-Z).
    static func isLetter(_ b: UInt8) -> Bool { (0x01...0x1A).contains(b) || (0x41...0x5A).contains(b) }

    /// Whether `patch`'s bytes in memory are the crack's.
    static func isPresent(_ patch: CrackPatch, read: (Int) -> UInt8) -> Bool {
        let slots = patch.detect.map { $0.map(read) }
        switch patch.rule {
        case .hash(let hash):
            return hexString(SHA2.sha256(slots.flatMap { $0 }).prefix(8)) == hash
        case .sameLetters:
            guard let first = slots.first, !first.isEmpty, first.allSatisfy(isLetter) else { return false }
            return slots.allSatisfy { $0 == first }
        }
    }

    /// Whether any of the crack's patches is in `mem` (64 KB).
    public static func crackPresent(in mem: [UInt8]) -> Bool {
        crackPatches.contains { isPresent($0) { mem[$0] } }
    }

    /// Blanks each of the crack's patches that `mem` (64 KB) holds; memory without them (a clean
    /// disk's, or memory already scrubbed) is left as it is.
    public static func scrubCrack(_ mem: inout [UInt8]) {
        mem.withUnsafeMutableBufferPointer { p in scrubCrack(memory: p.baseAddress!) }
    }

    /// `scrubCrack` on a 64 KB memory image the caller owns (the port's `Machine.mem`).
    public static func scrubCrack(memory mem: UnsafeMutablePointer<UInt8>) {
        for patch in crackPatches where isPresent(patch, read: { mem[$0] }) {
            for r in patch.blank { for a in r { mem[a] = 0x20 } }
        }
    }
}
