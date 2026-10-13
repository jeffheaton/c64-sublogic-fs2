import C64Kit
import FS2Data
import Foundation

/// M1 check: present the cold image with the game's raster split (view rows multicolor from $4000,
/// panel hi-res) to confirm the data pipeline and the presenter before any code runs.
public enum ColdPanel {
    public static func render(_ data: GameData, to url: URL) throws {
        var mem = data.coldMemory
        for a in 0x4000..<0x5180 { mem[a] = 0 }          // view area is cleared by the game
        for a in 0x7C00..<0x7E30 { mem[a] = 0x65 }       // day colors: blue sky / green ground
        let colorRAM = [UInt8](repeating: 1, count: 1024)
        var view = VICState()
        view.cr1 = 0x3B; view.bank = 0x4000; view.memPtr = 0xF0; view.cr2 = 0xD8
        view.border = 0x0E; view.background[0] = 0x0B
        view.spriteEnable = 0x0F; view.spriteMulticolor = 0x0F
        view.spriteX = [88, 104, 88, 104, 0, 0, 0, 0]; view.spriteY = [170, 170, 181, 181, 0, 0, 0, 0]
        view.spriteColor = Array(repeating: 0x0B, count: 8); view.spriteMC0 = 0x0B; view.spriteMC1 = 0x01
        var panel = view
        panel.cr2 = 0xC8; panel.border = 0x0C
        for n in 0..<4 { mem[0x7FF8 + n] = UInt8(0xE8 + n) }
        var out: [UInt8] = []
        mem.withUnsafeBufferPointer { ram in
            VICPresenter.render(into: &out, ram: ram, colorRAM: colorRAM, charROM: nil) { raster in
                raster >= 0xA3 || raster < 0x20 ? panel : view
            }
        }
        try ImageWriter.writePNG(indices: out, width: VICPresenter.width, height: VICPresenter.height,
                                 scaleX: 3, scaleY: 4, to: url)
    }
}
