import C64Kit
import FS2Data
import Foundation
import M6502

/// Boots Flight Simulator II in the lab machine the way SubLogic's stage 2 leaves things before
/// jumping to stage 3, without running any of the cracker's code or the drive-status check.
public enum Lab {
    public static func boot(_ data: GameData) -> C64Machine {
        let m = C64Machine(disk: data.d64.bytes)
        let bus = m.bus
        if ProcessInfo.processInfo.environment["FS2LAB_IECTRACE"] != nil {
            var n = 0
            bus.drive.trace = { line in n += 1; if n < 200_000 { print(line) } }
        }
        bus.charROM = data.charROM
        var mem = [UInt8](repeating: 0, count: 0x10000)
        ColdImage.load(FS2Layout.stage2, from: data.disk, into: &mem)
        ColdImage.load(FS2Layout.stage3, from: data.disk, into: &mem)
        ColdImage.scrubCrack(&mem)
        bus.ram = mem
        // Stage 2 ($78A2): interrupts and NMI point at an empty handler, KERNAL banked out, white
        // color RAM.
        for v in [0xFFFA, 0xFFFE] { bus.ram[v] = 0x0A; bus.ram[v + 1] = 0x79 }
        bus.portDDR = 0x2F
        bus.portData = 0x35
        bus.colorRAM = [UInt8](repeating: 1, count: 1024)
        bus.ram[0x731B] = 0          // drive number offset (device 8)
        bus.ram[0x7326] = 0          // drive-status check result: pass
        // Power-on VIC/CIA state as the KERNAL leaves it.
        bus.vicRegs[0x11] = 0x1B; bus.vicRegs[0x16] = 0xC8; bus.vicRegs[0x18] = 0x14
        bus.vicRegs[0x20] = 0x0E; bus.vicRegs[0x21] = 0x06
        bus.cia1.ddra = 0xFF; bus.cia1.pra = 0x7F; bus.cia1.ddrb = 0x00
        bus.cia2.ddra = 0x3F; bus.cia2.pra = 0x97
        m.cpu.pc = 0xA7E2
        m.cpu.interruptDisable = true
        m.cpu.sp = 0xFF
        // Once the boot loads are done ($A970), scrub the cracker's tag in the loaded editor line.
        m.cpu.traps[0xA970] = true
        m.cpu.trapHandler = { [unowned bus] pc in
            if pc == 0xA970 { ColdImage.scrubCrack(&bus.ram) }
            return false
        }
        return m
    }
}
