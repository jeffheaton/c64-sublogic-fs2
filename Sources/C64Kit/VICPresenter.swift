/// The VIC-II registers that decide what one raster line shows.
public struct VICState: Sendable, Equatable {
    public var cr1: UInt8 = 0x1B            // $D011: ECM, BMM, DEN, RSEL, YSCROLL
    public var cr2: UInt8 = 0xC8            // $D016: MCM, CSEL, XSCROLL
    public var memPtr: UInt8 = 0x14         // $D018: screen and bitmap/charset pointers
    public var bank: UInt16 = 0x0000        // VIC bank base, from CIA2 $DD00
    public var border: UInt8 = 14           // $D020
    public var background: [UInt8] = [6, 1, 2, 3]   // $D021-$D024
    public var spriteEnable: UInt8 = 0      // $D015
    public var spriteX: [UInt16] = Array(repeating: 0, count: 8)
    public var spriteY: [UInt8] = Array(repeating: 0, count: 8)
    public var spriteColor: [UInt8] = Array(repeating: 1, count: 8)  // $D027-$D02E
    public var spriteMC0: UInt8 = 0         // $D025
    public var spriteMC1: UInt8 = 0         // $D026
    public var spriteMulticolor: UInt8 = 0  // $D01C
    public var spriteExpandX: UInt8 = 0     // $D01D
    public var spriteExpandY: UInt8 = 0     // $D017
    public var spriteBehind: UInt8 = 0      // $D01B

    public init() {}

    /// Bank base for a CIA2 port A value (bits 0-1 inverted select the 16 KB bank).
    public static func bank(fromDD00 value: UInt8) -> UInt16 { UInt16(3 - (value & 3)) &* 0x4000 }
}

/// Composes a C64 frame (palette indices) from memory and per-line VIC register state.
/// Line-granular: register changes take effect from the start of a raster line, which is all
/// the raster splits used by Flight Simulator II need.
public enum VICPresenter {
    public static let width = 384
    public static let height = 248
    /// Raster line shown in frame row 0 (NTSC; 24 border lines above the 200-line display).
    public static let firstRasterLine = 27
    public static let rasterLines = 263
    /// Frame columns left of display pixel 0.
    public static let leftBorder = 32

    public static func rasterLine(forRow row: Int) -> Int { (firstRasterLine + row) % rasterLines }

    /// Renders a full frame. `ram` is the 64 KB the VIC sees, `colorRAM` the 1 KB of color nibbles,
    /// `charROM` the 4 KB character generator (visible at $1000-$1FFF of banks 0 and 2); without
    /// one (it is not on the game disk) the original `FallbackCharset` stands in for it.
    public static func render(into out: inout [UInt8], ram: UnsafeBufferPointer<UInt8>, colorRAM: [UInt8],
                              charROM: [UInt8]?, state: (Int) -> VICState) {
        let charROM = charROM ?? FallbackCharset.rom
        if out.count != width * height { out = [UInt8](repeating: 0, count: width * height) }
        var line = [UInt8](repeating: 0, count: 320)
        var fg = [Bool](repeating: false, count: 320)
        for row in 0..<height {
            let raster = rasterLine(forRow: row)
            let s = state(raster)
            let base = row * width
            let rsel = s.cr1 & 0x08 != 0
            let top = rsel ? 51 : 55, bottom = rsel ? 250 : 246
            let den = s.cr1 & 0x10 != 0
            let border = s.border & 0x0F
            guard den, raster >= top, raster <= bottom else {
                for x in 0..<width { out[base + x] = border }
                continue
            }
            let y = raster - 48 - Int(s.cr1 & 7)   // display row, 0 at the first line when YSCROLL = 3
            drawGraphics(&line, &fg, y: y, s: s, ram: ram, colorRAM: colorRAM, charROM: charROM)
            drawSprites(&line, fg: fg, raster: raster, s: s, ram: ram)
            let csel = s.cr2 & 0x08 != 0
            let left = csel ? 0 : 7, right = csel ? 319 : 311
            for x in 0..<width {
                let px = x - leftBorder
                out[base + x] = (px < left || px > right) ? border : line[px]
            }
        }
    }

    private static func fetch(_ addr: UInt16, _ s: VICState, _ ram: UnsafeBufferPointer<UInt8>,
                              _ charROM: [UInt8]?) -> UInt8 {
        let a = Int(s.bank) + Int(addr & 0x3FFF)
        if let rom = charROM, s.bank & 0x4000 == 0, (addr & 0x3FFF) >= 0x1000, (addr & 0x3FFF) < 0x2000 {
            return rom[Int(addr & 0x0FFF)]
        }
        return ram[a & 0xFFFF]
    }

    private static func drawGraphics(_ line: inout [UInt8], _ fg: inout [Bool], y: Int, s: VICState,
                                     ram: UnsafeBufferPointer<UInt8>, colorRAM: [UInt8], charROM: [UInt8]?) {
        let bg0 = s.background[0] & 0x0F
        guard y >= 0, y < 200 else {
            for x in 0..<320 { line[x] = bg0; fg[x] = false }
            return
        }
        let ecm = s.cr1 & 0x40 != 0, bmm = s.cr1 & 0x20 != 0, mcm = s.cr2 & 0x10 != 0
        let screenBase = UInt16(s.memPtr & 0xF0) << 6
        let charBase = UInt16(s.memPtr & 0x0E) << 10
        let bitmapBase = UInt16(s.memPtr & 0x08) << 10
        let xscroll = Int(s.cr2 & 7)
        let cy = y >> 3, ly = y & 7
        var pixels = [UInt8](repeating: bg0, count: 320 + 8)
        var front = [Bool](repeating: false, count: 320 + 8)
        for cx in 0..<40 {
            let cell = cy * 40 + cx
            let sc = fetch(screenBase &+ UInt16(cell), s, ram, charROM)
            let cc = colorRAM[cell] & 0x0F
            let x0 = cx * 8 + xscroll
            if bmm {
                let bits = fetch(bitmapBase &+ UInt16(cell * 8 + ly), s, ram, charROM)
                if ecm { continue }  // invalid mode: black
                if mcm {
                    for p in 0..<4 {
                        let v = (bits >> (6 - 2 * p)) & 3
                        let c: UInt8 = v == 0 ? bg0 : v == 1 ? sc >> 4 : v == 2 ? sc & 0x0F : cc
                        pixels[x0 + 2 * p] = c; pixels[x0 + 2 * p + 1] = c
                        front[x0 + 2 * p] = v >= 2; front[x0 + 2 * p + 1] = v >= 2
                    }
                } else {
                    for p in 0..<8 {
                        let on = (bits >> (7 - p)) & 1 != 0
                        pixels[x0 + p] = on ? sc >> 4 : sc & 0x0F
                        front[x0 + p] = on
                    }
                }
            } else {
                let code = ecm ? sc & 0x3F : sc
                let bits = fetch(charBase &+ UInt16(Int(code) * 8 + ly), s, ram, charROM)
                if mcm && !ecm && cc & 0x08 != 0 {
                    for p in 0..<4 {
                        let v = (bits >> (6 - 2 * p)) & 3
                        let c: UInt8 = v == 0 ? bg0 : v == 1 ? s.background[1] & 0x0F
                            : v == 2 ? s.background[2] & 0x0F : cc & 0x07
                        pixels[x0 + 2 * p] = c; pixels[x0 + 2 * p + 1] = c
                        front[x0 + 2 * p] = v >= 2; front[x0 + 2 * p + 1] = v >= 2
                    }
                } else {
                    let back = ecm ? s.background[Int(sc >> 6)] & 0x0F : bg0
                    for p in 0..<8 {
                        let on = (bits >> (7 - p)) & 1 != 0
                        pixels[x0 + p] = on ? cc : back
                        front[x0 + p] = on
                    }
                }
            }
        }
        for x in 0..<320 { line[x] = pixels[x]; fg[x] = front[x] }
    }

    private static func drawSprites(_ line: inout [UInt8], fg: [Bool], raster: Int, s: VICState,
                                    ram: UnsafeBufferPointer<UInt8>) {
        guard s.spriteEnable != 0 else { return }
        let screenBase = UInt16(s.memPtr & 0xF0) << 6
        // Sprite 0 has the highest priority, so draw 7 down to 0.
        for n in stride(from: 7, through: 0, by: -1) {
            let bit = UInt8(1 << n)
            guard s.spriteEnable & bit != 0 else { continue }
            let expandY = s.spriteExpandY & bit != 0
            let dy = raster - (Int(s.spriteY[n]) + 1)
            let sl = expandY ? dy >> 1 : dy
            guard dy >= 0, sl < 21 else { continue }
            let ptr = ram[(Int(s.bank) + Int(screenBase) + 0x3F8 + n) & 0xFFFF]
            let data = Int(s.bank) + Int(ptr) * 64 + sl * 3
            let bits = (UInt32(ram[data & 0xFFFF]) << 16) | (UInt32(ram[(data + 1) & 0xFFFF]) << 8)
                | UInt32(ram[(data + 2) & 0xFFFF])
            let expandX = s.spriteExpandX & bit != 0
            let mc = s.spriteMulticolor & bit != 0
            let behind = s.spriteBehind & bit != 0
            let x0 = Int(s.spriteX[n]) - 24
            let w = expandX ? 2 : 1
            for i in 0..<24 {
                var color: UInt8?
                if mc {
                    let pair = (bits >> UInt32(22 - (i & ~1))) & 3
                    switch pair {
                    case 1: color = s.spriteMC0 & 0x0F
                    case 2: color = s.spriteColor[n] & 0x0F
                    case 3: color = s.spriteMC1 & 0x0F
                    default: color = nil
                    }
                } else if (bits >> UInt32(23 - i)) & 1 != 0 {
                    color = s.spriteColor[n] & 0x0F
                }
                guard let c = color else { continue }
                for k in 0..<w {
                    let px = x0 + i * w + k
                    guard px >= 0, px < 320 else { continue }
                    if behind && fg[px] { continue }
                    line[px] = c
                }
            }
        }
    }
}
