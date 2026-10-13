@testable import C64Kit
import Foundation
import Testing

/// The fallback character set: the ROM's layout, distinct legible glyphs for every screen code a
/// text screen of the game uses, reverse video, and the presenter using it without a ROM.
struct FallbackCharsetTests {
    let rom = FallbackCharset.rom

    @Test func layoutLikeTheROM() {
        #expect(rom.count == 4096)
        for set in [0, 0x800] {
            for code in 0..<128 {
                for r in 0..<8 {
                    #expect(rom[set + 0x400 + code * 8 + r] == ~rom[set + code * 8 + r], "reverse of $\(code)")
                }
            }
        }
        // Capitals: set 1 $01-$1A and set 2 $41-$5A are the same glyphs; set 2 $01-$1A lowercase.
        for k in 0..<26 {
            #expect(FallbackCharset.glyph(UInt8(0x01 + k), set: 1) == FallbackCharset.glyph(UInt8(0x41 + k), set: 2))
            #expect(FallbackCharset.glyph(UInt8(0x01 + k), set: 2) != FallbackCharset.glyph(UInt8(0x41 + k), set: 2))
        }
        #expect(FallbackCharset.glyph(0x20, set: 2).allSatisfy { $0 == 0 }, "space is blank")
        #expect(FallbackCharset.glyph(0xA0, set: 2).allSatisfy { $0 == 0xFF }, "reverse space is solid")
    }

    /// Every glyph a text screen needs is drawn and differs from all the others.
    @Test func glyphsAreDistinct() {
        var seen: [[UInt8]: Int] = [:]
        let codes = Array(0x00...0x5A)
        for code in codes {
            let g = Array(FallbackCharset.glyph(UInt8(code), set: 2))
            if code != 0x20 { #expect(g.contains { $0 != 0 }, "$\(code) is drawn") }
            #expect(seen[g] == nil, "screen codes $\(String(code, radix: 16)) and $\(String(seen[g] ?? 0, radix: 16)) look the same")
            seen[g] = code
        }
    }

    /// The design: capitals and digits stand on rows 1-6 (rows 0 and 7 blank); the line
    /// character $40 runs across the whole cell, so runs of it join into a rule.
    @Test func design() {
        for code in Array(0x41...0x5A) + Array(0x30...0x39) {
            let g = FallbackCharset.glyph(UInt8(code), set: 2)
            #expect(g[g.startIndex] == 0 && g[g.startIndex + 7] == 0, "$\(String(code, radix: 16)) rows 0 and 7")
        }
        let line = FallbackCharset.glyph(0x40, set: 2)
        #expect(line.contains(0xFF))
        let arrow = FallbackCharset.glyph(0x3E, set: 2)
        #expect(arrow[arrow.startIndex + 4] != 0, "'>' points at the line's row")
    }

    /// The character ROM the user imported into the app (~/Library/Application Support/FS2/chargen.rom),
    /// if any. It is the user's own file; nothing of it is written here.
    static let importedROM: [UInt8]? = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FS2/chargen.rom")
        guard let data = FileManager.default.contents(atPath: url.path), data.count == 4096 else { return nil }
        return [UInt8](data)
    }()

    /// The glyphs are drawn, not copied: no letter, digit or punctuation mark of either set is the
    /// ROM's glyph for the same screen code. The space, the line $40 and the block graphics are
    /// plain geometry and may coincide.
    @Test(.enabled(if: importedROM != nil, "needs a character ROM imported into the app"))
    func glyphsAreNotTheROMs() throws {
        let chargen = try #require(Self.importedROM)
        var copies: [String] = []
        for (set, codes) in [(1, Array(0x00...0x3F)), (2, Array(0x00...0x3F) + Array(0x41...0x5A))] {
            for code in codes where code != 0x20 {
                let base = (set == 2 ? 0x800 : 0) + code * 8
                if Array(FallbackCharset.glyph(UInt8(code), set: set)) == Array(chargen[base..<base + 8]) {
                    copies.append("set \(set) $\(String(code, radix: 16))")
                }
            }
        }
        #expect(copies.isEmpty, "glyphs equal to the ROM's: \(copies)")
    }

    /// A text screen in bank 0 without a ROM shows the fallback glyphs; with a ROM, the ROM's.
    @Test func presenterUsesItWithoutROM() {
        var ram = [UInt8](repeating: 0x20, count: 0x10000)
        ram[0x0400] = 0x41                                  // 'A' in the upper/lowercase set
        ram[0x0401] = 0xB0                                  // reverse '0'
        var colors = [UInt8](repeating: 0, count: 1024)
        colors[0] = 0x0B; colors[1] = 0x0B
        var s = VICState()
        s.cr1 = 0x1B; s.cr2 = 0x08; s.memPtr = 0x16; s.bank = 0; s.border = 8
        s.background = [1, 0, 0, 0]
        let state = s
        func cell(_ out: [UInt8], _ column: Int) -> [UInt8] {
            (0..<8).map { ly in
                (0..<8).reduce(UInt8(0)) { acc, lx in
                    acc << 1 | (out[(24 + ly) * VICPresenter.width + VICPresenter.leftBorder + column * 8 + lx] == 0x0B ? 1 : 0)
                }
            }
        }
        var out: [UInt8] = []
        ram.withUnsafeBufferPointer { VICPresenter.render(into: &out, ram: $0, colorRAM: colors, charROM: nil) { _ in state } }
        #expect(cell(out, 0) == Array(FallbackCharset.glyph(0x41, set: 2)))
        #expect(cell(out, 1) == Array(FallbackCharset.glyph(0xB0, set: 2)))
        // With a ROM of all $81 every row is the ROM's.
        let fake = [UInt8](repeating: 0x81, count: 4096)
        ram.withUnsafeBufferPointer { VICPresenter.render(into: &out, ram: $0, colorRAM: colors, charROM: fake) { _ in state } }
        #expect(cell(out, 0) == [UInt8](repeating: 0x81, count: 8))
    }
}
