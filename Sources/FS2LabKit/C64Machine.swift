import C64Kit
import M6502

/// The lab's C64: RAM with $01 banking (no ROMs: ROM areas read as RAM, except the optional
/// character ROM), a line-timed VIC-II (raster counter, raster IRQ, badline/sprite stalls, per-line
/// register snapshots for rendering), two CIAs, a SID register log and a virtual 1541 on the bus.
public final class C64Bus: MemoryBus {
    public var ram = [UInt8](repeating: 0, count: 0x10000)
    public var colorRAM = [UInt8](repeating: 0, count: 1024)
    public var charROM: [UInt8]?
    public var portDDR: UInt8 = 0x2F
    public var portData: UInt8 = 0x37

    public var vicRegs = [UInt8](repeating: 0, count: 0x40)
    var vicIRQLatch: UInt8 = 0
    public var sidRegs = [UInt8](repeating: 0, count: 0x20)
    /// Every SID register write, with the CPU cycle at which it happened.
    public var sidWrites: [(cycle: UInt64, reg: UInt8, value: UInt8)] = []
    public var sidReadHook: ((Int) -> UInt8)?

    let cia1 = CIA()
    let cia2 = CIA()
    let drive: IECDrive
    public var keyboard = KeyMatrix()
    /// Set by the machine before each instruction so I/O can timestamp accesses.
    var now: UInt64 = 0
    /// Current raster line, maintained by the machine.
    var rasterLine = 0

    init(disk: [UInt8]) {
        drive = IECDrive(disk: disk)
        cia1.readPortA = { [unowned self] cia in
            self.keyboard.readPortA(portAOut: cia.pra | ~cia.ddra, portB: cia.prb | ~cia.ddrb)
        }
        cia1.readPortB = { [unowned self] cia in
            self.keyboard.readPortB(portA: cia.pra | ~cia.ddra, portBOut: cia.prb | ~cia.ddrb)
        }
        cia2.portAWritten = { [unowned self] cia in
            let out = cia.pra | ~cia.ddra
            self.drive.c64Lines(atn: out & 0x08 != 0, clk: out & 0x10 != 0, data: out & 0x20 != 0, at: self.now)
        }
        cia2.readPortA = { [unowned self] cia in
            let out = cia.pra | ~cia.ddra
            let d = self.drive.lines(at: self.now)
            let clkLow = d.clk || out & 0x10 != 0, dataLow = d.data || out & 0x20 != 0
            return (out & 0x3F) | (clkLow ? 0 : 0x40) | (dataLow ? 0 : 0x80)
        }
    }

    var ioVisible: Bool { (portData | ~portDDR) & 0x03 != 0 && (portData | ~portDDR) & 0x04 != 0 }
    var charROMVisible: Bool { (portData | ~portDDR) & 0x03 != 0 && (portData | ~portDDR) & 0x04 == 0 }

    /// The VIC bank selected through CIA2 port A.
    public var vicBank: UInt16 { VICState.bank(fromDD00: cia2.pra | ~cia2.ddra) }

    /// When set, every CPU read/write address is marked here (coverage of data accesses).
    public var accessMap: UnsafeMutablePointer<UInt8>?

    public func read(_ address: UInt16) -> UInt8 {
        let a = Int(address)
        accessMap?[a] |= 0x01
        if a < 2 { return a == 0 ? portDDR : portData }
        if a >= 0xD000 && a < 0xE000 {
            if ioVisible { return readIO(a) }
            if charROMVisible, let rom = charROM { return rom[a - 0xD000] }
        }
        return ram[a]
    }

    public func write(_ address: UInt16, _ value: UInt8) {
        let a = Int(address)
        accessMap?[a] |= 0x02
        if a < 2 {
            if a == 0 { portDDR = value } else { portData = value }
            ram[a] = value
            return
        }
        if a >= 0xD000 && a < 0xE000 && ioVisible {
            writeIO(a, value)
            return
        }
        ram[a] = value
    }

    /// Called with (address, value) for every I/O read (replay recording).
    public var ioReadHook: ((Int, UInt8) -> Void)?

    func readIO(_ a: Int) -> UInt8 {
        let v = readIOValue(a)
        ioReadHook?(a, v)
        return v
    }

    func readIOValue(_ a: Int) -> UInt8 {
        switch a {
        case 0xD000..<0xD400:
            let r = a & 0x3F
            switch r {
            case 0x11: return vicRegs[0x11] & 0x7F | (rasterLine > 0xFF ? 0x80 : 0)
            case 0x12: return UInt8(rasterLine & 0xFF)
            case 0x19: return vicIRQLatch | 0x70 | (vicIRQLatch & vicRegs[0x1A] & 0x0F != 0 ? 0x80 : 0)
            case 0x1A: return vicRegs[0x1A] | 0xF0
            case 0x1E, 0x1F: return 0
            case 0x2F...0x3F: return 0xFF
            default: return vicRegs[r]
            }
        case 0xD400..<0xD800:
            let r = a & 0x1F
            if r >= 0x19 { return sidReadHook?(r) ?? 0 }
            return 0
        case 0xD800..<0xDC00:
            return colorRAM[a - 0xD800] | 0xF0
        case 0xDC00..<0xDD00:
            return cia1.read(a, now: now)
        case 0xDD00..<0xDE00:
            return cia2.read(a, now: now)
        default:
            return 0xFF
        }
    }

    func writeIO(_ a: Int, _ v: UInt8) {
        switch a {
        case 0xD000..<0xD400:
            let r = a & 0x3F
            if r == 0x19 { vicIRQLatch &= ~v; return }
            vicRegs[r] = v
        case 0xD400..<0xD800:
            let r = a & 0x1F
            sidRegs[r] = v
            sidWrites.append((now, UInt8(r), v))
        case 0xD800..<0xDC00:
            colorRAM[a - 0xD800] = v & 0x0F
        case 0xDC00..<0xDD00:
            cia1.write(a, v, now: now)
        case 0xDD00..<0xDE00:
            cia2.write(a, v, now: now)
        default:
            break
        }
    }

    var rasterCompare: Int { Int(vicRegs[0x12]) | Int(vicRegs[0x11] & 0x80) << 1 }

    /// Snapshot of the registers that matter for drawing a line.
    func vicState() -> VICState {
        var s = VICState()
        s.cr1 = vicRegs[0x11]; s.cr2 = vicRegs[0x16]; s.memPtr = vicRegs[0x18]
        s.bank = vicBank
        s.border = vicRegs[0x20] & 0x0F
        s.background = [vicRegs[0x21], vicRegs[0x22], vicRegs[0x23], vicRegs[0x24]].map { $0 & 0x0F }
        s.spriteEnable = vicRegs[0x15]
        for n in 0..<8 {
            s.spriteX[n] = UInt16(vicRegs[n * 2]) | (vicRegs[0x10] & UInt8(1 << n) != 0 ? 0x100 : 0)
            s.spriteY[n] = vicRegs[n * 2 + 1]
            s.spriteColor[n] = vicRegs[0x27 + n] & 0x0F
        }
        s.spriteMC0 = vicRegs[0x25] & 0x0F; s.spriteMC1 = vicRegs[0x26] & 0x0F
        s.spriteMulticolor = vicRegs[0x1C]; s.spriteExpandX = vicRegs[0x1D]
        s.spriteExpandY = vicRegs[0x17]; s.spriteBehind = vicRegs[0x1B]
        return s
    }
}

/// The lab machine: CPU + bus + video timing. Runs the original code and captures frames.
public final class C64Machine {
    public static let cyclesPerLine: UInt64 = 65
    public static let linesPerFrame = 263
    public static let cyclesPerFrame: UInt64 = cyclesPerLine * UInt64(linesPerFrame)

    public let bus: C64Bus
    public let cpu: CPU6502<C64Bus>

    /// Cycle at which the current raster line started.
    public private(set) var lineStart: UInt64 = 0
    /// Register state at the end of each line of the frame in progress / the last complete frame.
    private var lineStates = [VICState](repeating: VICState(), count: 263)
    public private(set) var lastFrameStates = [VICState](repeating: VICState(), count: 263)
    /// RAM and color RAM captured at the end of the last complete frame.
    public private(set) var lastFrameRAM: [UInt8] = []
    public private(set) var lastFrameColorRAM: [UInt8] = []
    public private(set) var frameCount = 0
    /// Called after each completed frame.
    public var onFrame: ((C64Machine) -> Void)?
    public var captureFrames = true

    /// Instruction-level hook (coverage, tracing); called with the PC before each instruction.
    public var onInstruction: ((UInt16) -> Void)?

    public init(disk: [UInt8]) {
        bus = C64Bus(disk: disk)
        cpu = CPU6502(bus: bus)
    }

    public var keyboard: KeyMatrix {
        get { bus.keyboard }
        set { bus.keyboard = newValue }
    }

    /// Executes one instruction and advances video timing. Returns false when the CPU stopped.
    /// When set (replay recording), raster IRQs are not taken asynchronously; `ReplayRecorder`
    /// delivers them at the program's own poll points instead.
    public var quantizedIRQs = false
    /// The replay recorder attached to this machine (it sets itself): a session's `nmi` step
    /// presses RESTORE through it, so the NMI is taken at a poll point and logged.
    public internal(set) weak var replayRecorder: ReplayRecorder?

    @discardableResult
    public func step() -> Bool {
        bus.now = cpu.cycles
        cpu.irqLine = !quantizedIRQs && (bus.vicIRQLatch & bus.vicRegs[0x1A] & 0x0F != 0) || bus.cia1.interruptLine
        onInstruction?(cpu.pc)
        if cpu.step() == 0, cpu.illegalOpcode != nil { return false }
        bus.now = cpu.cycles
        while cpu.cycles >= lineStart + Self.cyclesPerLine { endLine() }
        if bus.cia2.interruptLine { cpu.nmiPending = true; _ = bus.cia2.read(0x0D, now: cpu.cycles) }
        return true
    }

    private func endLine() {
        lineStates[bus.rasterLine] = bus.vicState()
        lineStart += Self.cyclesPerLine
        bus.rasterLine += 1
        if bus.rasterLine == Self.linesPerFrame {
            bus.rasterLine = 0
            frameCount += 1
            lastFrameStates = lineStates
            if captureFrames {
                lastFrameRAM = bus.ram
                lastFrameColorRAM = bus.colorRAM
            }
            onFrame?(self)
        }
        if bus.rasterLine == bus.rasterCompare { bus.vicIRQLatch |= 0x01 }
        // DMA stalls: badlines (40 cycles) and visible sprites (2 cycles each).
        let cr1 = bus.vicRegs[0x11]
        let line = bus.rasterLine
        if cr1 & 0x10 != 0, line >= 0x30, line <= 0xF7, line & 7 == Int(cr1 & 7) { cpu.cycles += 40 }
        let enabled = bus.vicRegs[0x15]
        if enabled != 0 {
            var stall: UInt64 = 0
            for n in 0..<8 where enabled & UInt8(1 << n) != 0 {
                let y = Int(bus.vicRegs[n * 2 + 1]) + 1
                let h = bus.vicRegs[0x17] & UInt8(1 << n) != 0 ? 42 : 21
                if line >= y && line < y + h { stall += 2 }
            }
            cpu.cycles += stall
        }
    }

    /// Runs until `condition` is true or `maxCycles` elapse. Returns true if the condition was met.
    @discardableResult
    public func run(maxCycles: UInt64, until condition: (C64Machine) -> Bool = { _ in false }) -> Bool {
        let end = cpu.cycles.addingReportingOverflow(maxCycles).overflow ? UInt64.max : cpu.cycles + maxCycles
        while cpu.cycles < end {
            if condition(self) { return true }
            if !step() { return false }
        }
        return condition(self)
    }

    public func runFrames(_ n: Int) {
        let target = frameCount + n
        while frameCount < target { if !step() { return } }
    }

    /// Renders the last complete frame (palette indices, VICPresenter geometry).
    public func renderLastFrame() -> [UInt8] {
        var out: [UInt8] = []
        let ram = lastFrameRAM.isEmpty ? bus.ram : lastFrameRAM
        let color = lastFrameColorRAM.isEmpty ? bus.colorRAM : lastFrameColorRAM
        let states = lastFrameStates
        ram.withUnsafeBufferPointer { buf in
            VICPresenter.render(into: &out, ram: buf, colorRAM: color, charROM: bus.charROM) { states[$0] }
        }
        return out
    }

    public func pressNMI() { cpu.nmiPending = true }
}
