import C64Kit
import Foundation
import FS2Core
@testable import FS2Data
import Testing

/// The disk the web build is deployed with (`DeployDisk`, `fs2disk`): the port builds exactly the
/// same machine from it, it holds nothing but the logical blocks, and nothing a modified copy added.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"))
struct DeployDiskTests {
    /// The disk a web deploy carries (`make web-audit` sets it).
    static let auditedDisk: URL? = ProcessInfo.processInfo.environment["FS2_AUDIT_DISK"]
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }

    @Test func deployImageBuildsTheSameMachine() throws {
        let data = try #require(Original.data)
        let image = try DeployDisk.image(from: data.d64)
        #expect(image.count == DeployDisk.size)
        let deployed = try GameData(d64: D64Image(data: image))
        #expect(deployed.coldMemory == data.coldMemory)
        for overlay in FS2Layout.Overlay.allCases {
            #expect(deployed.overlay(overlay) == data.overlay(overlay), "overlay \(overlay)")
        }
        #expect(Machine.bootMemory(blocks: deployed.disk.blocks) == Machine.bootMemory(blocks: data.disk.blocks))

        // The blocks are the original's but for the crack's text.
        let scrubbed = Set(ColdImage.crackRanges.flatMap { $0.compactMap(DeployDisk.location(of:)) }
            .map { $0.block * 1024 + $0.offset })
        for n in 0..<SubLogicDisk.blockCount {
            for i in 0..<SubLogicDisk.blockSize where deployed.disk.blocks[n][i] != data.disk.blocks[n][i] {
                #expect(scrubbed.contains(n * 1024 + i), "block \(n) offset \(i) differs")
            }
        }
        // Nothing outside them: no BAM, no directory, no crack loader at 18/2, no track 3.
        let d64 = try D64Image(data: image)
        let used = Set(SubLogicDisk.usedSectors.map { $0.track * 100 + $0.sector })
        for track in 1...35 {
            for sector in 0..<D64Image.sectorCount(track: track) where !used.contains(track * 100 + sector) {
                #expect(try d64.sector(track: track, sector: sector).allSatisfy { $0 == 0 }, "track \(track) sector \(sector)")
            }
        }
    }

    /// No title record, no word of six letters or more from them, no word of four letters or more
    /// of the boot banner: neither as screen codes nor as ASCII, in any letter case.
    @Test(.enabled(if: Original.isModifiedCopy, "needs a modified copy: the check reads its additions from the image"))
    func deployImageNamesNothingOfTheCrack() throws {
        let data = try #require(Original.data)
        let names = try CrackExclusionTests.crackNames(data)
        let image = try DeployDisk.image(from: data.d64)
        let text = CrackExclusionTests.text(image).lowercased()
        for needle in names.records + names.words.sorted() + names.banner.sorted() {
            #expect(!text.contains(needle), "the deploy image names the crack")
        }
    }

    /// The disk deployed with the site is `fs2disk`'s image of the user's disk, byte for byte.
    @Test(.enabled(if: auditedDisk != nil, "set FS2_AUDIT_DISK (make web-audit)"))
    func auditedDiskIsTheDeployImage() throws {
        let data = try #require(Original.data)
        let file = try [UInt8](Data(contentsOf: try #require(Self.auditedDisk)))
        #expect(file == (try DeployDisk.image(from: data.d64)), "\(Self.auditedDisk!.path) is not fs2disk's image")
    }
}
