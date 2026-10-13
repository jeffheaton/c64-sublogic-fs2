import C64Kit
import FS2Core
import FS2LabKit
import Foundation
import Testing

/// The editor's text screen as the presenter shows it: with the fallback character set (no ROM
/// imported) every cell is its glyph and the page reads back as text; with a character ROM
/// provided the port's frame equals the lab's pixel for pixel (a synthetic 4 KB ROM stands in
/// for the real one, which is not on the game disk).
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"), .serialized)
struct EditorScreenTests {
    /// What the port shows at a key wait: the frame, the memory and the I/O state then.
    struct Shown {
        var frame: [UInt8] = []
        var ram: [UInt8] = []
        var io = IO()
        subscript(_ a: Int) -> UInt8 { ram[a] }
    }

    /// The port from the editor's entry, stopped at its first key wait after `keys` were typed:
    /// the frame `presentTextScreen` gives with `rom` (the editor then runs on to its exit).
    static func portFrame(keys: String = "", rom: [UInt8]?) throws -> (frame: [UInt8], machine: Shown) {
        let m = Machine(memory: try D2.state("d2-ed-entry"))
        m.diskBlocks = Original.diskBlocks
        let script = ScriptedKeys(keys)
        script.installPollHandler(on: m)
        var shown = Shown()
        let typed = keys.utf8.count
        let previous = m.pollHandler
        m.pollHandler = { mm in
            if shown.frame.isEmpty, script.delivered == typed {
                mm.presentTextScreen(into: &shown.frame, charROM: rom)
                shown.ram = mm.memoryImage
                shown.io = mm.io
            }
            previous?(mm)
        }
        m.editorEntry()
        return (shown.frame, shown)
    }

    /// Frame pixel of display pixel (x, y) (25 rows, 40 columns: the display starts at frame
    /// row 24, column 32).
    static func pixel(_ frame: [UInt8], _ x: Int, _ y: Int) -> UInt8 {
        frame[(24 + y) * VICPresenter.width + VICPresenter.leftBorder + x]
    }

    /// The 8 bytes a cell shows: set bits where the pixel is the cell's color-RAM color.
    static func cellBits(_ frame: [UInt8], column: Int, row: Int, foreground: UInt8) -> [UInt8] {
        (0..<8).map { ly in
            (0..<8).reduce(UInt8(0)) { acc, lx in
                acc << 1 | (pixel(frame, column * 8 + lx, row * 8 + ly) == foreground ? 1 : 0)
            }
        }
    }

    @Test func fallbackCharsetIsLegible() throws {
        let (frame, m) = try Self.portFrame(keys: "\r\r\r\r\r\r\r\r\r\r\r\r\r\r123", rom: nil)
        #expect(frame.count == VICPresenter.width * VICPresenter.height)
        let fg = m.io.colorRAM[0] & 0x0F, bg = m.io.vic[0x21] & 0x0F
        #expect(fg == 0x0B && bg == 0x01 && m.io.vic[0x20] == 0x08, "dark gray on white, orange border")
        #expect(frame[0] == 0x08, "the border")
        // Every cell is exactly its screen code's glyph (reverse video included).
        var wrong = 0
        // Readback: glyph bytes -> screen code, over the codes a text screen needs.
        var codeOf: [[UInt8]: UInt8] = [:]
        for code in Array(0x20...0x5A) + Array(0xA0...0xDA) {
            let g = Array(FallbackCharset.glyph(UInt8(code), set: 2))
            #expect(codeOf[g] == nil, "glyphs $\(hex16(code)) and $\(hex16(Int(codeOf[g] ?? 0))) are the same")
            codeOf[g] = UInt8(code)
        }
        var text: [String] = []
        for row in 0..<25 {
            var line = ""
            for column in 0..<40 {
                let code = m[0x0400 + row * 40 + column]
                let bits = Self.cellBits(frame, column: column, row: row, foreground: fg)
                if bits != Array(FallbackCharset.glyph(code, set: 2)) { wrong += 1 }
                let read = codeOf[bits]
                let c = read.map { $0 & 0x7F } ?? 0x3F
                line.append(c == 0x40 ? "-" : Character(UnicodeScalar(c)))
            }
            text.append(line)
        }
        #expect(wrong == 0, "\(wrong) cells differ from their glyphs")
        #expect(text[0].contains("SIMULATION"), "row 0: \(text[0])")
        #expect(text[24].hasSuffix("TO EXIT"), "row 24: \(text[24])")
        #expect(text[23] == String(repeating: "-", count: 40))
        // The cursor arrow and the reverse-video digits typed on line 15 (HEADING).
        #expect(text[15].contains("-->"), "row 15: \(text[15])")
        let typed = (31...33).map { m[0x0400 + 15 * 40 + $0] }
        #expect(typed == [0xB1, 0xB2, 0xB3], "the digits in reverse video")
        #expect(text[15].contains("123"))
        // A picture for the eye.
        let dir = Original.repoRoot.appendingPathComponent("build/testdata", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try ImageWriter.writePNG(indices: frame, width: VICPresenter.width, height: VICPresenter.height, scaleX: 2,
                                 scaleY: 2, to: dir.appendingPathComponent("d2-editor-fallback.png"))
    }

    /// The lab at the same point (E, then its first key wait), its frame rendered with a ROM, and
    /// the port's frame with the same ROM; also without a ROM (both show the fallback set).
    @Test func framesMatchTheLab() throws {
        let data = try #require(Original.data)
        let lab = Lab.boot(data)
        try lab.play(try Session.parse(C3Fixtures.prefix + "\nkey:E:6 pc:2250:1500 wait:10"), screenshots: nil)
        var rng = TestRandom(seed: 0xC0DE)
        let synthetic = (0..<4096).map { _ in rng.byte() }
        for rom in [synthetic, nil] as [[UInt8]?] {
            lab.bus.charROM = rom
            let labFrame = lab.renderLastFrame()
            let (frame, _) = try Self.portFrame(rom: rom)
            let differing = (0..<frame.count).filter { frame[$0] != labFrame[$0] }
            #expect(differing.isEmpty, "\(rom == nil ? "fallback" : "ROM"): \(differing.count) pixels differ, first at \(differing.first ?? -1)")
        }
        // The text screen itself (screen codes and colors) is the lab's.
        let (_, m) = try Self.portFrame(rom: nil)
        let screen = (0x0400..<0x07E8).filter { m[$0] != lab.bus.ram[$0] }
        #expect(screen.isEmpty, "\(screen.count) screen bytes differ")
        #expect((0..<1000).allSatisfy { m.io.colorRAM[$0] == lab.bus.colorRAM[$0] & 0x0F })
    }
}
