import C64Kit
import FS2Core
import FS2LabKit
import M6502
import Testing

/// The port's model of the VIC's DMA (`Machine.vicDMA`) against the lab's VIC (`C64Machine.endLine`,
/// which the lab's cycle counts include): the same instruction stream, run on the lab's CPU and
/// charged on the port's clock, must reach the same instruction at the same cycle, over several
/// frames, for the register states the game uses (flight, the text screen and the loads, the
/// display off) and others (YSCROLL 0, eight sprites, Y-expanded ones down to the frame's last
/// lines, sprites switched on and off by the program as it runs). No disk image needed.
@Suite struct VICDMATests {
    struct Case: Sendable, CustomStringConvertible {
        var name: String
        var control: UInt8
        var sprites: UInt8 = 0
        var spriteY: [UInt8] = [0xAA, 0xAA, 0xB5, 0xB5, 0, 0, 0, 0]
        var expandY: UInt8 = 0
        /// The program flips these bits of a VIC register every pass (read, exclusive-or, write
        /// back): register and bits, or nil.
        var toggles: (register: UInt8, bits: UInt8)?
        var description: String { name }
    }

    static let cases: [Case] = [
        Case(name: "flight", control: 0x3B, sprites: 0x0F),
        Case(name: "text screen and loads", control: 0x1B),
        Case(name: "display off", control: 0x0B, sprites: 0x0F),
        Case(name: "YSCROLL 0", control: 0x38, sprites: 0x0F),
        Case(name: "eight sprites, two expanded at the bottom", control: 0x3B, sprites: 0xFF,
             spriteY: [0x10, 0x30, 0x55, 0x80, 0xAA, 0xD0, 0xF0, 0xFF], expandY: 0xC1),
        Case(name: "sprites toggled", control: 0x3B, sprites: 0x0F, toggles: (0x15, 0x0F)),
        // `$D011` as the program writes it: YSCROLL moving the badlines (3 <-> 4), the display
        // switched off and on (DEN, as the loads and the editor's swaps do).
        Case(name: "YSCROLL toggled", control: 0x3B, sprites: 0x0F, toggles: (0x11, 0x07)),
        Case(name: "display toggled", control: 0x3B, toggles: (0x11, 0x10)),
    ]

    /// The loop: 200 two-cycle no-ops, the register toggle (or three instructions of the same
    /// lengths that touch nothing: a read of $1000, an exclusive-or, a write to $2000), and a jump
    /// back to $1000.
    static func program(_ c: Case) -> [UInt8] {
        var p = [UInt8](repeating: 0xEA, count: 200)
        if let t = c.toggles {
            p += [0xAD, t.register, 0xD0, 0x49, t.bits, 0x8D, t.register, 0xD0]
        } else {
            p += [0xAD, 0x00, 0x10, 0x49, 0x0F, 0x8D, 0x00, 0x20]
        }
        p += [0x4C, 0x00, 0x10]
        return p
    }

    @Test(arguments: Self.cases)
    func sameInstructionAtTheSameCycle(_ c: Case) {
        let frames: UInt64 = 6
        let end = frames * VirtualClock.cyclesPerFrame + 1_234

        // The lab: no raster IRQs, the CPU with the interrupt flag set, running the loop at $1000.
        let lab = C64Machine(disk: [])
        lab.captureFrames = false
        for (k, b) in Self.program(c).enumerated() { lab.bus.ram[0x1000 + k] = b }
        lab.bus.vicRegs[0x11] = c.control
        lab.bus.vicRegs[0x15] = c.sprites
        lab.bus.vicRegs[0x17] = c.expandY
        for n in 0..<8 { lab.bus.vicRegs[n * 2 + 1] = c.spriteY[n] }
        lab.bus.vicRegs[0x1A] = 0
        lab.cpu.pc = 0x1000
        var labInstructions = 0
        while lab.cpu.cycles < end {
            lab.step()
            labInstructions += 1
        }

        // The port: the same instructions as charges.
        let m = Machine(memory: [UInt8](repeating: 0, count: Machine.memorySize))
        m.io.writeVIC(0x11, c.control)
        m.io.writeVIC(0x15, c.sprites)
        m.io.writeVIC(0x17, c.expandY)
        for n in 0..<8 { m.io.writeVIC(n * 2 + 1, c.spriteY[n]) }
        m.vicDMA = true
        var portInstructions = 0
        func instruction(_ cycles: Int, _ effect: () -> Void = {}) {
            guard m.clock.cycles < end else { return }
            effect()
            m.charge(cycles)
            portInstructions += 1
        }
        while m.clock.cycles < end {
            for _ in 0..<200 { instruction(2) }
            instruction(4)                                  // the read
            instruction(2)                                  // the exclusive-or
            instruction(4) {                                // the write
                if let t = c.toggles { m.io.writeVIC(Int(t.register), m.io.vic[Int(t.register)] ^ t.bits) }
            }
            instruction(3)                                  // the jump back
        }

        #expect(portInstructions == labInstructions, "\(c.name): port \(portInstructions) instructions, lab \(labInstructions)")
        #expect(m.clock.cycles == lab.cpu.cycles, "\(c.name): port at cycle \(m.clock.cycles), lab \(lab.cpu.cycles)")
        if let t = c.toggles { #expect(m.io.vic[Int(t.register)] == lab.bus.vicRegs[Int(t.register)]) }
    }
}
