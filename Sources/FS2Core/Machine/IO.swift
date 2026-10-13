import C64Kit

/// The hardware the original code talks to, as seen by the port. Translated routines call these
/// instead of storing to $Dxxx (memory stays plain RAM).
public struct IO: Sendable {
    /// VIC-II registers ($D000-$D02E) as last written.
    public var vic = [UInt8](repeating: 0, count: 0x2F) {
        didSet { noteDMARegisters() }
    }

    /// The VIC registers the cycles it steals from the CPU depend on (`Machine.vicDMA`): display
    /// enable and YSCROLL (`$D011` bits 4 and 0-2: the badlines), the sprite enables `$D015`, their
    /// Y expansion `$D017` and the Y positions of the enabled sprites.
    public struct DMARegisters: Sendable, Equatable {
        /// `$D011` & $17.
        public var control: UInt8 = 0
        public var spriteEnable: UInt8 = 0
        public var spriteExpandY: UInt8 = 0
        /// The Y position of each enabled sprite (sprite n in byte n), 0 for the others.
        public var spriteY: UInt64 = 0

        public init() {}

        public init(vic: [UInt8]) {
            guard vic.count > 0x17 else { return }
            control = vic[0x11] & 0x17
            spriteEnable = vic[0x15]
            spriteExpandY = vic[0x17] & spriteEnable
            for n in 0..<8 where spriteEnable & UInt8(1 << n) != 0 {
                spriteY |= UInt64(vic[n * 2 + 1]) << (8 * n)
            }
        }

        /// The cycles the lab's VIC (`C64Machine.endLine`) takes from the CPU at the start of raster
        /// line `line`: 40 on a badline (display enabled, lines $30-$F7 whose low three bits are
        /// YSCROLL), and 2 for every enabled sprite displayed on the line (from its Y + 1, 21 lines
        /// or 42 expanded).
        public func stolenCycles(line: Int) -> Int {
            var cycles = 0
            if control & 0x10 != 0, line >= 0x30, line <= 0xF7, line & 7 == Int(control & 7) { cycles += 40 }
            if spriteEnable != 0 {
                for n in 0..<8 where spriteEnable & UInt8(1 << n) != 0 {
                    let y = Int((spriteY >> (8 * n)) & 0xFF) + 1
                    let height = spriteExpandY & UInt8(1 << n) != 0 ? 42 : 21
                    if line >= y && line < y + height { cycles += 2 }
                }
            }
            return cycles
        }
    }

    /// The DMA registers as `vic` holds them now, and a count of their changes (the clock's stall
    /// table follows it: `Machine.vicDMA`).
    public private(set) var dmaRegisters = DMARegisters()
    public private(set) var dmaGeneration: UInt64 = 0

    private mutating func noteDMARegisters() {
        let registers = DMARegisters(vic: vic)
        guard registers != dmaRegisters else { return }
        dmaRegisters = registers
        dmaGeneration &+= 1
    }

    /// VIC register state latched for the two display regions (the original's raster split).
    public var viewRegion = VICState()
    public var panelRegion = VICState()
    /// CIA2 port A as last written (VIC bank select, serial lines).
    public var cia2PortA: UInt8 = 0x97
    /// SID registers as last written, and the timestamped write stream for the audio engine.
    public var sid = [UInt8](repeating: 0, count: 0x19)
    public var sidWrites: [(cycle: UInt64, reg: UInt8, value: UInt8)] = []
    /// Keyboard matrix and joysticks (CIA1).
    public var keyboard = KeyMatrix()
    /// Color RAM ($D800-$DBFF nibbles).
    public var colorRAM = [UInt8](repeating: 0, count: 1024)

    public init() {}

    public mutating func writeVIC(_ reg: Int, _ value: UInt8) { vic[reg] = value }

    public mutating func writeSID(_ reg: Int, _ value: UInt8, at cycle: UInt64) {
        sid[reg] = value
        sidWrites.append((cycle, UInt8(reg), value))
    }

    // MARK: CIA registers, color RAM and I/O reads of the main program

    /// CIA1's time-of-day clock (`$DC08-$DC0B`), run from the virtual clock.
    public var timeOfDay = TimeOfDayClock()
    /// CIA1 control registers A/B (`$DC0E/$DC0F`) as last written. Bit 7 of A selects the 50 Hz
    /// TOD input (the original's calibration at $AB52 sets it only on PAL machines).
    public var cia1ControlA: UInt8 = 0
    public var cia1ControlB: UInt8 = 0
    /// The CIA interrupt masks (`$DC0D` / `$DD0D` writes): the game clears them all at $AB78.
    public var cia1InterruptMask: UInt8 = 0
    public var cia2InterruptMask: UInt8 = 0
    /// CIA2 data direction A (`$DD02`).
    public var cia2DataDirectionA: UInt8 = 0x3F

    /// A store to `$DC00-$DCFF` (the registers the game writes: the TOD, the controls, the ICR).
    public mutating func writeCIA1(_ register: Int, _ value: UInt8, at cycle: UInt64) {
        timeOfDay.advance(to: cycle)
        switch register & 0x0F {
        case 0x08: if cia1ControlB & 0x80 == 0 { timeOfDay.tenths = value & 0x0F; timeOfDay.halted = false }
        case 0x09: if cia1ControlB & 0x80 == 0 { timeOfDay.seconds = value & 0x7F }
        case 0x0A: if cia1ControlB & 0x80 == 0 { timeOfDay.minutes = value & 0x7F }
        case 0x0B: if cia1ControlB & 0x80 == 0 { timeOfDay.hours = value & 0x9F; timeOfDay.halted = true }
        case 0x0D:
            if value & 0x80 != 0 { cia1InterruptMask |= value & 0x1F } else { cia1InterruptMask &= ~(value & 0x1F) }
        case 0x0E: cia1ControlA = value & ~0x10; timeOfDay.fiftyHz = value & 0x80 != 0
        case 0x0F: cia1ControlB = value & ~0x10
        default: break
        }
    }

    /// A store to `$DD00-$DDFF`: port A (the VIC bank), its data direction, the ICR mask.
    public mutating func writeCIA2(_ register: Int, _ value: UInt8) {
        switch register & 0x0F {
        case 0x00: cia2PortA = value
        case 0x02: cia2DataDirectionA = value
        case 0x0D:
            if value & 0x80 != 0 { cia2InterruptMask |= value & 0x1F } else { cia2InterruptMask &= ~(value & 0x1F) }
        default: break
        }
    }

    /// A store to color RAM `$D800 + offset` (the low nibble is kept, as the hardware does).
    public mutating func writeColorRAM(_ offset: Int, _ value: UInt8) {
        colorRAM[offset & 0x3FF] = value & 0x0F
    }

    /// A store to `$D019` (acknowledging VIC interrupts). It clears latch bits and leaves the
    /// register shadow `vic` alone, as on the chip (a read of $D019 shows the latch, not the
    /// last value written).
    public mutating func acknowledgeVIC(_ value: UInt8) {
        vicInterruptLatch &= ~value
    }

    /// The VIC interrupt latch (`$D019` bits 0-3). Only the raster bit is modeled.
    public var vicInterruptLatch: UInt8 = 0

    /// The value the main program reads from I/O `address` at `cycle`: the CIA1 time of day and
    /// controls, the ICRs (no CIA interrupt sources run in the game: 0), the VIC registers as
    /// written, the keyboard ports. `Machine.readIO` passes it through the replay hook.
    public mutating func read(_ address: Int, at cycle: UInt64) -> UInt8 {
        switch address {
        case 0xD000..<0xD400:
            let r = address & 0x3F
            switch r {
            case 0x19: return vicInterruptLatch | 0x70
            case 0x1A: return vic[0x1A] | 0xF0
            case 0x2F...0x3F: return 0xFF
            default: return vic[r]
            }
        case 0xD800..<0xDC00:
            return colorRAM[address - 0xD800] | 0xF0
        case 0xDC00..<0xDD00:
            timeOfDay.advance(to: cycle)
            switch address & 0x0F {
            case 0x00: return keyboard.readPortA(portAOut: 0xFF)
            case 0x01: return keyboard.readPortB(portA: 0xFF)
            case 0x08: return timeOfDay.tenths
            case 0x09: return timeOfDay.seconds
            case 0x0A: return timeOfDay.minutes
            case 0x0B: return timeOfDay.hours
            case 0x0D: return 0
            case 0x0E: return cia1ControlA
            case 0x0F: return cia1ControlB
            default: return 0xFF
            }
        case 0xDD00..<0xDE00:
            switch address & 0x0F {
            case 0x00: return cia2PortA | ~cia2DataDirectionA
            case 0x02: return cia2DataDirectionA
            case 0x0D: return 0
            default: return 0xFF
            }
        default:
            return 0xFF
        }
    }

    /// Current VIC register state, shaped for the presenter.
    public func vicState() -> VICState {
        var s = VICState()
        s.cr1 = vic[0x11]; s.cr2 = vic[0x16]; s.memPtr = vic[0x18]
        s.bank = VICState.bank(fromDD00: cia2PortA)
        s.border = vic[0x20] & 0x0F
        s.background = [vic[0x21], vic[0x22], vic[0x23], vic[0x24]].map { $0 & 0x0F }
        s.spriteEnable = vic[0x15]
        for n in 0..<8 {
            s.spriteX[n] = UInt16(vic[n * 2]) | (vic[0x10] & UInt8(1 << n) != 0 ? 0x100 : 0)
            s.spriteY[n] = vic[n * 2 + 1]
            s.spriteColor[n] = vic[0x27 + n] & 0x0F
        }
        s.spriteMC0 = vic[0x25] & 0x0F; s.spriteMC1 = vic[0x26] & 0x0F
        s.spriteMulticolor = vic[0x1C]; s.spriteExpandX = vic[0x1D]
        s.spriteExpandY = vic[0x17]; s.spriteBehind = vic[0x1B]
        return s
    }
}

/// CIA1's time-of-day clock as the port runs it: BCD tenths, seconds, minutes and hours (12-hour,
/// bit 7 = PM) counted from 60 Hz mains ticks derived from the virtual clock, one tenth per 6
/// ticks (5 when control register A bit 7 selects the 50 Hz input), as the lab's CIA model does.
/// A write to the hours halts it and a write to the tenths restarts it; the read latch of the
/// real chip is not modeled (the game reads only the tenths, at $AB28-$AB41, and the seconds).
public struct TimeOfDayClock: Sendable, Equatable {
    public var tenths: UInt8 = 0
    public var seconds: UInt8 = 0
    public var minutes: UInt8 = 0
    public var hours: UInt8 = 0x01
    public var halted = false
    public var fiftyHz = false
    /// Virtual-clock cycles per mains tick (60 Hz, NTSC).
    public static let cyclesPerMainsTick = VirtualClock.hz / 60
    /// The cycle of the next mains tick (0 = not started), and the ticks toward the next tenth.
    public var nextTick: Double = 0
    public var ticks = 0

    public init() {}

    /// Runs the clock up to `cycle`.
    public mutating func advance(to cycle: UInt64) {
        let now = Double(cycle)
        if nextTick == 0 { nextTick = now + Self.cyclesPerMainsTick }
        while now >= nextTick {
            nextTick += Self.cyclesPerMainsTick
            guard !halted else { continue }
            ticks += 1
            if ticks >= (fiftyHz ? 5 : 6) {
                ticks = 0
                advanceTenth()
            }
        }
    }

    /// The cycle at which the tenths register next changes (for timed waits on it).
    public func nextTenthCycle() -> UInt64 {
        let remaining = (fiftyHz ? 5 : 6) - ticks
        return UInt64((nextTick + Double(remaining - 1) * Self.cyclesPerMainsTick).rounded(.up))
    }

    private static func bcdIncrement(_ v: UInt8) -> UInt8 {
        var lo = (v & 0x0F) + 1, hi = v >> 4
        if lo > 9 { lo = 0; hi += 1 }
        return hi << 4 | lo
    }

    private mutating func advanceTenth() {
        tenths += 1
        guard tenths > 9 else { return }
        tenths = 0
        seconds = Self.bcdIncrement(seconds)
        guard seconds == 0x60 else { return }
        seconds = 0
        minutes = Self.bcdIncrement(minutes)
        guard minutes == 0x60 else { return }
        minutes = 0
        let pm = hours & 0x80
        var h = Self.bcdIncrement(hours & 0x1F)
        if h == 0x12 { h |= pm ^ 0x80 } else if h == 0x13 { h = 0x01 | pm } else { h |= pm }
        hours = h
    }
}
