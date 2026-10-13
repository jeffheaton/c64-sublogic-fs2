import C64Kit

/// The disk image the web build is deployed with (`fs2disk`, `make web-disk`): only what the port
/// reads, with nothing a modified copy added.
///
/// - Only the 656 sectors behind SubLogic's 164 logical blocks are copied. Everything else is zero:
///   the BAM and the directory (track 18 sectors 0-5), the crack's boot loader and banner
///   (track 18 sector 2), track 3 and any error bytes. The result is a 35-track image that is of no
///   use outside the port.
/// - The text a crack wrote into the blocks (two title records, the 3-letter tag) is blanked with
///   the same rule the port applies at every cold start (`ColdImage.scrubCrack`), so the cold
///   image and the overlays are exactly what the port builds from the original.
///
/// The block check (`SubLogicDisk.mismatchedBlocks`) masks those bytes, so the image validates.
public enum DeployDisk {
    /// A standard 35-track image without error bytes.
    public static let size = 174_848

    /// The deploy image of `d64`.
    public static func image(from d64: D64Image) throws -> [UInt8] {
        var blocks = try SubLogicDisk(d64).blocks
        scrubCrack(&blocks)
        var out = [UInt8](repeating: 0, count: size)
        for n in 0..<SubLogicDisk.blockCount {
            for i in 0..<4 {
                let (track, sector) = SubLogicDisk.usedSectors[n * 4 + i]
                let at = D64Image.offset(track: track, sector: sector)
                let from = i * 256
                out.replaceSubrange(at..<(at + 256), with: blocks[n][from..<(from + 256)])
            }
        }
        return out
    }

    /// The loads that put blocks where the crack's text sits in memory.
    static let loads: [FS2Layout.Load] = [FS2Layout.stage2, FS2Layout.stage3] + FS2Layout.bootLoads

    /// Blanks the crack's text in the blocks: the blocks are loaded as the boot loads them, the cold
    /// start's scrub runs on that memory, and the scrub's ranges go back into their blocks.
    static func scrubCrack(_ blocks: inout [[UInt8]]) {
        var mem = [UInt8](repeating: 0, count: 0x10000)
        for load in loads { place(load, blocks, into: &mem) }
        ColdImage.scrubCrack(&mem)
        for range in ColdImage.crackRanges {
            for address in range {
                guard let (block, offset) = location(of: address) else {
                    preconditionFailure("crack range address $\(hex(address, width: 4)) is in no load")
                }
                blocks[block][offset] = mem[address]
            }
        }
    }

    static func place(_ load: FS2Layout.Load, _ blocks: [[UInt8]], into mem: inout [UInt8]) {
        for i in 0..<load.count {
            let a = load.address + i * SubLogicDisk.blockSize
            for j in 0..<SubLogicDisk.blockSize where a + j < 0x10000 { mem[a + j] = blocks[load.block + i][j] }
        }
    }

    /// The block and offset that `address` was loaded from (the last load covering it wins, as in
    /// memory).
    static func location(of address: Int) -> (block: Int, offset: Int)? {
        for load in loads.reversed() {
            let start = load.address, end = load.address + load.count * SubLogicDisk.blockSize
            guard (start..<end).contains(address) else { continue }
            let delta = address - start
            return (load.block + delta / SubLogicDisk.blockSize, delta % SubLogicDisk.blockSize)
        }
        return nil
    }
}
