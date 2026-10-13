import FS2Core
import Testing

/// The 10 Hz tick with I/O banked out. The course plot display ($F6F1) runs with `$01` = `$4B` =
/// $30 ($F7B0), and the poll banks I/O in only around the tick (`pollTick`: `$01` = $35, the tick,
/// `$01` = `$4B`). Every IRQ ends with `$01` = `$4B`, so an IRQ taken inside the tick leaves I/O
/// banked out for the rest of it: the tick's read of `$DC09` sees the RAM under I/O (the clock
/// then counts a second whenever that byte differs from `$0E6D`) and the SID stores land in the
/// RAM under the SID. In normal mode the lab shows the game clock running two to three times too
/// fast while a course plot is displayed; a replay cannot show it (the recording takes its IRQs
/// only at the poll points, outside the tick). `Machine.ioMappedIn` gives the port the same
/// memory map.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"))
struct BankedOutTickTests {
    typealias R = MainLoop.RAM

    /// The tick body $2348 with `$01` = $30 on random clock and TOD states: the flat bus of
    /// `Original.call` is exactly the C64's memory map with I/O banked out, so the whole image,
    /// $D000-$DFFF included, must match; the port reads no I/O and stores nothing to the SID.
    @Test func tickReadsAndStoresTheRAMUnderIO() throws {
        let base = try Original.regularFlight()
        var rng = TestRandom(seed: 0xDC09)
        var ticked = 0, sidStores = 0
        for i in 0..<48 {
            var ram = base
            ram[0x01] = 0x30
            ram[R.savedCpuPort] = 0x30
            ram[Input.RAM.keyQueueRead] = ram[Input.RAM.keyQueueWrite]       // no key to dispatch
            ram[R.pauseCount] = 0
            ram[R.tickCounter] = rng.byte()
            ram[Input.RAM.soundEnable] = 1
            let seconds = rng.byte() % 0x60
            ram[0xDC09] = seconds
            ram[R.lastTodSeconds] = rng.byte() < 160 ? seconds &+ 1 : seconds
            ram[R.clockSeconds] = rng.byte() % 60
            let original = Original.call(0x2348, ram: ram)
            let m = Machine(memory: ram)
            var hookCalls = 0
            m.ioReadHook = { _, live in hookCalls += 1; return live }
            m.tick10Hz()
            let d = Original.differences(m.memoryImage, original.ram)
            let first = d.prefix(8).map { "$\(hex16($0))=\(hex(m.mem[$0])) want \(hex(original.ram[$0]))" }
            #expect(d.isEmpty, "case \(i): \(d.count) bytes differ, first \(first.joined(separator: " "))")
            #expect(hookCalls == 0, "case \(i): the tick read I/O with I/O banked out")
            #expect(m.io.sidWrites.isEmpty, "case \(i): the tick stored to the SID with I/O banked out")
            if m.mem[R.lastTodSeconds] == seconds && ram[R.lastTodSeconds] != seconds { ticked += 1 }
            if (0xD400...0xD418).contains(where: { m.mem[$0] != ram[$0] }) { sidStores += 1 }
        }
        #expect(ticked > 0 && sidStores > 0,
                "cases that took a RAM second: \(ticked); that stored to the SID's RAM: \(sidStores)")
    }

    /// An IRQ taken inside the tick while the plot is displayed: the handler's exit (`$01` =
    /// `$4B` = $30) leaves I/O banked out, the tick reads `$DC09` from RAM and counts a second the
    /// CIA never ticked. Without the IRQ the same tick reads the CIA and counts nothing.
    @Test(arguments: [false, true])
    func irqInsideTheTickBanksIOOut(irq: Bool) throws {
        var ram = try Original.regularFlight()
        #expect(ram[0xFFFE] == 0x85 && ram[0xFFFF] == 0x22, "the raster IRQ $2285 is installed")
        ram[0x01] = 0x30                                    // $F7B0: the plot's bank switch
        ram[R.savedCpuPort] = 0x30
        ram[R.frameDivider] = 6                             // a tick is due at this poll
        ram[Input.RAM.keyQueueRead] = ram[Input.RAM.keyQueueWrite]
        ram[R.pauseCount] = 0
        ram[0xDC09] = 0x00                                  // the RAM under the TOD seconds
        ram[R.lastTodSeconds] = 0x17
        ram[R.clockSeconds] = 10
        let m = Machine(memory: ram)
        m.ioReadHook = { address, live in address == 0xDC09 ? 0x17 : live }   // the CIA: same second
        if irq {
            // Due at the poll's first charge after `$01` = $35, before the call to $2348.
            m.nextEventCycle = m.clock.cycles + 1
            m.eventHandler = { m in
                m.nextEventCycle = .max
                m.irq()
            }
        }
        m.pollTick()
        #expect(m.mem[0x01] == 0x30, "the poll restores $01 from $4B")
        if irq {
            #expect(m.mem[R.lastTodSeconds] == 0x00, "the tick read $DC09 from the RAM under I/O")
            #expect(m.mem[R.clockSeconds] == 11, "the clock counted a second the CIA never ticked")
        } else {
            #expect(m.mem[R.lastTodSeconds] == 0x17)
            #expect(m.mem[R.clockSeconds] == 10)
        }
    }
}
