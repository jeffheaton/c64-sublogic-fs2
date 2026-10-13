import C64Kit
import CryptoKit

/// SubLogic's logical block filesystem: the disk is read as 164 blocks of 1 KB (4 consecutive used
/// sectors each). Used sectors run in track/sector order over tracks 1-35, skipping track 3 entirely
/// and using only sectors 6-18 of track 18 (sectors 0-5 hold the BAM and directory).
public struct SubLogicDisk: Sendable {
    public static let blockCount = 164
    public static let blockSize = 1024

    public static let usedSectors: [(track: Int, sector: Int)] = {
        var list: [(Int, Int)] = []
        for t in 1...35 where t != 3 {
            let sectors = t == 18 ? Array(6...18) : Array(0..<D64Image.sectorCount(track: t))
            list += sectors.map { (t, $0) }
        }
        return list
    }()

    public let blocks: [[UInt8]]

    public init(_ d64: D64Image) throws {
        var out: [[UInt8]] = []
        out.reserveCapacity(Self.blockCount)
        for n in 0..<Self.blockCount {
            var b: [UInt8] = []
            b.reserveCapacity(Self.blockSize)
            for (t, s) in Self.usedSectors[(n * 4)..<(n * 4 + 4)] {
                b += try d64.sector(track: t, sector: s)
            }
            out.append(b)
        }
        blocks = out
    }

    public func block(_ n: Int) -> [UInt8] { blocks[n] }

    /// The bytes a crack changes, as logical block and offsets in it, masked out of the block check
    /// (`mismatchedBlocks`): a modified copy of version 1.0 can have its title records overwritten,
    /// a tag on the editor's disk-error line and a patched protection check, so these bytes may
    /// differ between a clean copy and a modified one. Exactly these ranges, with the addresses they
    /// load at (`re/docs/excluded.md`):
    ///
    /// | Block | Offsets | Address | What |
    /// |---|---|---|---|
    /// | 1 (stage 2) | $135-$197 | $7835-$7897 | SubLogic's drive-status check (protection), masked whole. Stage 2's copy differs from the copy the boot's $77E0 load brings (block 26) only at $783B, query 3's expected status: probably the crack's patch. The compare at $7876 that `excluded.md` suspects is the same in both copies. Never run by the port. |
    /// | 2 (overlay 0) | $059-$09D | $A839-$A87D | The two title records the crack wrote (`ColdImage.crackRanges` blanks their text) |
    /// | 2 (overlay 0) | $317-$319 | $AAF7-$AAF9 | The protection stubs of the init chain (`CLC`/`RTS`, `RTS`); not ported, only their time |
    /// | 13 (the $0200 load) | $091-$093 | $0E91-$0E93 | The crack's tag before the editor's disk-error line |
    /// | 13 (the $0200 load) | $0AF-$0B1 | $0EAF-$0EB1 | The crack's tag after it |
    ///
    /// The crack's boot loader (track 18 sector 2) is outside the logical blocks and never read.
    /// Everything else, the rest of these five blocks included, must match.
    public static let crackModifiedBytes: [(block: Int, offsets: ClosedRange<Int>)] = [
        (1, 0x135...0x197),
        (2, 0x059...0x09D),
        (2, 0x317...0x319),
        (13, 0x091...0x093),
        (13, 0x0AF...0x0B1),
    ]

    /// Block numbers whose contents differ from Flight Simulator II v1.0, outside the bytes a crack
    /// changes (`crackModifiedBytes`). A clean copy and copies whose title records were overwritten
    /// both pass.
    public func mismatchedBlocks() -> [Int] {
        (0..<Self.blockCount).filter { n in Self.digest(ofBlock: n, blocks[n]) != Self.expectedBlockHashes[n] }
    }

    /// The first 8 bytes of the SHA-256 of block `n` with its crack-modified bytes zeroed, in hex.
    static func digest(ofBlock n: Int, _ block: [UInt8]) -> String {
        var masked = block
        for (b, offsets) in crackModifiedBytes where b == n {
            for i in offsets { masked[i] = 0 }
        }
        return SHA256.hash(data: masked).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// First 8 bytes of the SHA-256 of each logical block of version 1.0, with the bytes of
    /// `crackModifiedBytes` zeroed (blocks 1, 2 and 13; hashes only, no content).
    static let expectedBlockHashes: [String] = [
        "3405f19d06a3ddaa", "8f2cb2494cb4c457", "8a538bdd696406be", "964c37b9d8ed4b55",
        "e358331f16eff79e", "5f70bf18a0860070", "93589bc567b60eb6", "b1769f305488ff6e",
        "5ba1660089237650", "dc8c3fa52fe6d449", "316f5b41e6b024e2", "0962e571f2ec5a0b",
        "dac6b05ecbfa1bc1", "39c725ae063eeabf", "1a020a452f6adb08", "78f780e439b66f53",
        "efb6f43bae4cf6c9", "efd0d55613f2426d", "31dfb922e0294451", "8b95b299bb04a2de",
        "a4e560d67ee82e84", "7ef813c0d7e0e1ea", "961e9b814aa1e31c", "7034c263dc9611d6",
        "05d92a98d6e648e6", "4c68e0a939e5b16b", "1002932077892824", "c7ba2d1bb48e329c",
        "8555430a7d642fdf", "70f7efe8aeb9967e", "dee003e6ef21990a", "051f6bae75395a01",
        "a4e86774b025b0de", "c6b101ce32c82126", "24c98c279552a2ac", "ebb0c321b6415508",
        "f6ed4aada7b85da4", "8c304612871d1702", "92d237453be0e0f4", "eabce7835d45ecd1",
        "5f70bf18a0860070", "cd3fdac8568d35fe", "4c0c25e2635f2894", "5bca0eaacb772691",
        "e358331f16eff79e", "8d24e9666366c132", "e22ec5e9024f1b4a", "ab9578845deb6384",
        "c335d0ab4c527991", "4fb982661f3a8a00", "778bf821e776c615", "0c141c3e66920135",
        "e1e155efe6abdbfa", "d1f370366fcff388", "477526e74f70d830", "cf4071da9f52b760",
        "90998f64940cbb9c", "68905e5078852ecb", "7287b7911a5891ec", "7254940be59722ab",
        "f8fa02d6072e772f", "0330dd57fd0f12e5", "ea82512d74e3ffa1", "c39006022e2acf68",
        "f989830d4dad1e65", "04827ad0c3a1fe37", "395081af5c054637", "5f70bf18a0860070",
        "de9092d3c70439c6", "f7a16af81cd53402", "8d09c0b29f7a9038", "bb955e29ca8879bf",
        "d8817eeb509a549a", "68905e5078852ecb", "59c059d0031c5a8a", "16ddb599ce7a0a8a",
        "4d9503d6c3a09481", "16ddb599ce7a0a8a", "721f9f801d526d60", "16ddb599ce7a0a8a",
        "3132976e8b121632", "cc8e5bb1d4930da5", "6fb592855bb8cd73", "2dd4b2842942c30c",
        "cbf0b3f2bcec11e7", "68905e5078852ecb", "ad488609b5a84d85", "837fcd562032a994",
        "5f70bf18a0860070", "a5547d8a26302d9c", "47d39257723ebc34", "5f70bf18a0860070",
        "1b836904807c3e3b", "cf5727fbc546caaa", "e78bc095b588e065", "b7e91c96253298f6",
        "d40dff58d88cf720", "9c69cfdb91ecd355", "f3087fd84ecfa8ad", "cf5727fbc546caaa",
        "876ed4e7237ae8f0", "5f70bf18a0860070", "11d130136d9dd837", "2502d29151a4c396",
        "36782dd265203667", "437aa9b5ae6454f4", "1b18a7d18f573e09", "fd005cb7fa53f64d",
        "5f70bf18a0860070", "e78ad73058d6e678", "db1a1610c6e7236f", "5f70bf18a0860070",
        "791084726cde3556", "ac949d27e4989711", "8147121d69e58625", "a1808de8d2a20f47",
        "a24193e14373fa80", "29e3ba84dd0f10d9", "34ddc4fb79f8d73e", "37dde8f4a29101f9",
        "b53839f7dc577ffe", "f0a8a8a3d8ba1c84", "4221d8f56520543a", "3ca85991aa512516",
        "5294af85c26685d7", "4c1395b496fc9276", "69d75c2d9c1c1901", "bd0fc77c38d1aa4e",
        "c9a98c912102a0ac", "66e04a39cd773ff4", "5f70bf18a0860070", "5f70bf18a0860070",
        "5f70bf18a0860070", "5f70bf18a0860070", "5f70bf18a0860070", "5f70bf18a0860070",
        "5f70bf18a0860070", "5f70bf18a0860070", "5f70bf18a0860070", "5f70bf18a0860070",
        "5f70bf18a0860070", "5f70bf18a0860070", "5f70bf18a0860070", "5f70bf18a0860070",
        "5f70bf18a0860070", "5f70bf18a0860070", "5f70bf18a0860070", "5f70bf18a0860070",
        "5f70bf18a0860070", "5f70bf18a0860070", "5f70bf18a0860070", "c9b09b9d80df8d61",
        "5b5444193adf2597", "4092e557bc2a734d", "79770f8b0facda9d", "2e532095baf999e2",
        "91fa7e10e729ece3", "31689e59f8432efb", "71979e92fa8daa53", "2005abe66c7fd680",
        "9f659b8eb7ba1270", "5f70bf18a0860070", "5f70bf18a0860070", "5f70bf18a0860070",
    ]
}
