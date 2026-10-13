import C64Kit
import FS2Core
import FS2LabKit
import Foundation
import Testing

/// Differential tests of the command dispatcher and every in-flight key handler ($27D8-$2E91,
/// $2F40), the joystick actions ($2688-$26FE), the wait-for-key loop ($2250), the RESTORE handler
/// ($2700) and the ring/slot routines that read no I/O. Every call runs the original routine on
/// the flat bus and its port on a twin image (`InputRig`) from six recorded states (regular
/// flight, the demo's self-flying takeoff, radios tuned with the ADF on, Europe 1917 in the air,
/// slew, radar), with the handler inputs perturbed (the ground flag included), and compares memory, cycles, registers and SID
/// stores.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"), .serialized)
struct InputHandlerTests {
    typealias R = Input.RAM

    // MARK: Perturbations

    /// Randomizes the bytes the handlers read, within and at the edges of their ranges.
    static func perturb(_ rig: InputRig, _ rng: inout TestRandom) {
        func pick(_ values: [UInt8]) -> UInt8 { values[Int(rng.next() % UInt64(values.count))] }
        func coin() -> Bool { rng.next() & 1 == 0 }
        rig.poke(R.selectedItem, pick([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
                                       0x11, 0xFF, rng.byte()]))
        rig.poke(R.quickRepeatWindow, pick([0, 0, 1, 2, 3]))
        rig.poke(R.autoCoordination, pick([0, 0, 1]))
        if rng.next() % 8 == 0 { rig.poke(R.slewMode, pick([0, 1])) }
        if rng.next() % 8 == 0 { rig.poke(R.europe1917, pick([0, 1])) }
        rig.poke(R.elevator, rng.byte())
        rig.poke(R.elevator + 1, pick([0xB0, 0xB2, 0xB4, 0xB8, 0xBC, 0xC0, 0xF8, 0xFC, 0, 4, 8, 0x3C, 0x40, 0x44,
                                       0x48, 0x4C, 0x4E, 0x50, 0x7C, 0x80, rng.byte()]))
        rig.poke(R.ailerons, rng.byte())
        rig.poke(R.ailerons + 1, pick([0x80, 0x84, 0x88, 0xFC, 0, 4, 0x78, 0x7C, 0x7E, rng.byte()]))
        rig.poke(R.rudder, rng.byte())
        rig.poke(R.rudder + 1, pick([0x80, 0x84, 0x88, 0xFC, 0, 4, 0x78, 0x7C, 0x7E, rng.byte()]))
        rig.poke(R.elevatorTrim, pick([0xB0, 0xB4, 0xFC, 0, 4, 0x4C, 0x50, 0x52, rng.byte()]))
        rig.poke(R.flaps + 1, pick([0, 0x10, 0x20, 0x40, 0x60, 0x70, rng.byte()]))
        rig.poke(R.throttle, pick([0, 4, 8, 0x40, 0x70, 0x78, 0x7D, rng.byte()]))
        rig.poke(R.throttleJumpArmed, pick([0, 0, 1, 2, 3]))
        rig.poke(R.onGround, pick([0, 0xFF]))
        rig.poke(R.airspeed + 1, pick([0, 1, 2, 3, 0x20, rng.byte()]))
        rig.poke(R.ammo, pick([0, 1, rng.byte()]))
        rig.poke(R.ammo + 1, pick([0, 0, rng.byte()]))
        rig.poke(R.bombCount, pick([0x30, 0x31, 0x35]))
        rig.poke(R.radarMode, pick([0, 0, 1]))
        rig.poke(R.navSelect, pick([1, 2]))
        rig.poke(R.obsSelect, pick([1, 2]))
        rig.poke(R.fuelTankSelect, pick([0, 1, 2]))
        rig.poke(0x0A9A, pick([0, 1, 3, 6, 7]))             // mixture
        rig.poke(R.overControlLimiter, rng.byte())
        rig.poke(R.rollTerm, rng.byte())
        rig.poke(R.rollTerm + 1, rng.byte())
        rig.poke(R.maneuverTimer, pick([0, 0, 5]))
        rig.poke(R.carbHeat, pick([0, 0xFF]))
        rig.poke(R.lights, pick([0, 0xFF]))
        rig.poke(R.warDeclared, pick([0, 1, 3]))
        // Radios: COM 118.00-135.95, NAV 108.00-117.95, octal transponder, OBS 0-$B3, ADF digits.
        let com = 118 + Int(rng.next() % 18), nav = 108 + Int(rng.next() % 10)
        rig.poke(R.comDigits, UInt8(0x30 + (com / 10) % 10))
        rig.poke(R.comDigits + 1, UInt8(0x30 + com % 10))
        rig.poke(R.comDigits + 2, UInt8(0x30 + rng.next() % 10))
        rig.poke(R.comDigits + 3, coin() ? 0x30 : 0x35)
        for digits in [R.nav1Digits, R.nav2Digits] where rng.next() % 3 == 0 {
            rig.poke(digits, UInt8(0x30 + (nav / 10) % 10))
            rig.poke(digits + 1, UInt8(0x30 + nav % 10))
            rig.poke(digits + 2, UInt8(0x30 + rng.next() % 10))
            rig.poke(digits + 3, coin() ? 0x30 : 0x35)
        }
        for i in 0..<4 where coin() { rig.poke(R.transponderDigits + i, UInt8(0x30 + rng.next() % 8)) }
        rig.poke(R.obs1, pick([0, 1, 0x5A, 0xB2, 0xB3]))
        rig.poke(R.obs2, pick([0, 1, 0x5A, 0xB2, 0xB3]))
        for i in 0..<3 where coin() { rig.poke(Adf.digits + i, UInt8(0x30 + rng.next() % 10)) }
        rig.poke(0x0AC3, rng.byte())                        // slew rates
        rig.poke(0x0ABF, rng.byte())
        rig.poke(0x0AC1, rng.byte())
        rig.poke(0x0AC5, rng.byte())
    }

    /// The state every dispatch needs: dispatching allowed, and for the pause handler a second
    /// key queued and a 10 Hz tick due, so `waitForKey` ends at its first poll.
    static func prepareDispatch(_ rig: InputRig, _ code: UInt8, follow: UInt8, _ rng: inout TestRandom) {
        rig.poke(R.keyDispatchInhibit, 0)
        rig.poke(0x0E6B, 6 + UInt8(rng.next() % 6))         // frameDivider
        rig.enqueue(code)
        rig.enqueue(follow)
    }

    /// The recorded states are what their names say.
    @Test func recordedStates() throws {
        let war = try InputStates.ram("in-war")
        #expect(war[R.europe1917] == 1 && war[R.onGround] == 0 && war[R.warDeclared] & 1 == 1, "war mode, airborne")
        #expect(try InputStates.ram("in-slew")[R.slewMode] == 1)
        #expect(try InputStates.ram("in-radar")[R.radarMode] == 1)
        #expect(try InputStates.ram("in-tuned")[0x09AA] == 1, "ADF enabled")
        #expect(try InputStates.ram("demo")[0x095A] == 1, "the demo flag is set")
        #expect(try InputStates.ram("regular")[R.onGround] != 0, "regular flight starts on the ground")
    }

    // MARK: Dispatch

    /// Every code $00-$FF (the letters, digits and their CTRL variants $00-$1F, the dead codes
    /// ≥ $60 and the CTRL-shifted digits ≥ $C0) through `dispatchKey` in flight, three times per
    /// state with the inputs perturbed; then all of them in text-input mode (`$08BA` = 1).
    @Test func dispatchEveryCode() throws {
        for name in InputStates.names {
            let rig = InputRig(try InputStates.ram(name))
            var rng = TestRandom(seed: name.utf8.reduce(UInt64(0x1000)) { $0 &* 31 &+ UInt64($1) })
            for round in 0..<3 {
                for code in 0...0xFF {
                    Self.perturb(rig, &rng)
                    rig.poke(R.editorRequest, 0)
                    rig.poke(R.pauseCount, 0)
                    Self.prepareDispatch(rig, UInt8(code), follow: rng.byte() & 0x7F, &rng)
                    // The pause ($10, $50) polls the ported $2330; its ticks' SID stores match too.
                    rig.run(0x27D8, "\(name) round \(round) code \(hex(UInt8(code)))") {
                        $0.dispatchKey(); return .init()
                    }
                    // Drain the follow-up key (the pause consumed it already).
                    rig.poke(R.keyQueueRead, rig.peek(R.keyQueueWrite))
                }
            }
            for code in 0...0xFF {
                rig.poke(R.editorRequest, UInt8(1 + code % 3))
                rig.enqueue(UInt8(code))
                rig.run(0x27D8, "\(name) text-input code \(hex(UInt8(code)))") { $0.dispatchKey(); return .init() }
            }
            // An empty ring: A is the read index.
            rig.poke(R.editorRequest, 1)
            rig.poke(R.keyQueueRead, rig.peek(R.keyQueueWrite))
            rig.run(0x27D8, "\(name) empty ring") { $0.dispatchKey(); return .init() }
            rig.expectClean("dispatch, \(name)")
        }
    }

    /// The keys that depend on the selected item `$FC` and the quick-repeat window, for every
    /// item value and window state, in each state.
    @Test func selectedItemSweep() throws {
        let codes: [UInt8] = [0x01, 0x03, 0x06, 0x0D, 0x0E, 0x14, 0x16, 0x18, 0x2C, 0x2E, 0x31, 0x32, 0x33, 0x34,
                              0x35, 0x41, 0x42, 0x54, 0x59, 0x48, 0x4E, 0x56, 0x46, 0x52, 0x47, 0x43, 0x4D]
        let items: [UInt8] = Array(0...0x12) + [0x7F, 0x80, 0xFF]
        for name in InputStates.names {
            let rig = InputRig(try InputStates.ram(name))
            var rng = TestRandom(seed: 0x5E1E_C7ED ^ UInt64(name.count))
            for code in codes {
                for item in items {
                    for window: UInt8 in [0, 2] {
                        Self.perturb(rig, &rng)
                        rig.poke(R.selectedItem, item)
                        rig.poke(R.quickRepeatWindow, window)
                        rig.poke(R.editorRequest, 0)
                        Self.prepareDispatch(rig, code, follow: 0x20, &rng)
                        rig.run(0x27D8, "\(name) code \(hex(code)) FC \(hex(item)) window \(window)") {
                            $0.dispatchKey(); return .init()
                        }
                        rig.poke(R.keyQueueRead, rig.peek(R.keyQueueWrite))
                    }
                }
            }
            rig.expectClean("selected item, \(name)")
        }
    }

    /// Repeated presses step through the sub-fields while the window is open: CTRL-C 4 → 5 →
    /// search + 4, CTRL-N 6 → 7, CTRL-X 8 → 9 → $0A → $0B → $0C → 8, A $0D → $0E → $0F → $10.
    @Test func quickRepeatSequences() throws {
        let rig = InputRig(try InputStates.ram("in-tuned"))
        var rng = TestRandom(seed: 0xC7_12)
        for (code, presses) in [(UInt8(0x03), 4), (0x0E, 3), (0x18, 7), (0x14, 7), (0x01, 6), (0x41, 4)] {
            rig.poke(R.selectedItem, 0)
            rig.poke(R.quickRepeatWindow, 0)
            for press in 0..<presses {
                Self.prepareDispatch(rig, code, follow: 0x20, &rng)
                rig.run(0x27D8, "code \(hex(code)) press \(press)") { $0.dispatchKey(); return .init() }
                rig.poke(R.keyQueueRead, rig.peek(R.keyQueueWrite))
            }
        }
        #expect(rig.peek(R.selectedItem) == 0x10)
        rig.expectClean("quick repeats")
    }

    // MARK: The elevator acceleration window

    /// B and T step 4, or 16 while the window `$091C` (3 after each elevator key, decremented at
    /// 5 Hz) is open and not slewing; the joystick clears the window first, so it always steps 4.
    @Test func elevatorAccelerationWindow() throws {
        let rig = InputRig(try Original.regularFlight())
        var rng = TestRandom(seed: 0xE1E7)
        func press(_ code: UInt8, _ label: String) {
            Self.prepareDispatch(rig, code, follow: 0x20, &rng)
            rig.run(0x27D8, label) { $0.dispatchKey(); return .init() }
            rig.poke(R.keyQueueRead, rig.peek(R.keyQueueWrite))
        }
        func tick5Hz() {
            let w = rig.peek(R.quickRepeatWindow)
            if w != 0 { rig.poke(R.quickRepeatWindow, w - 1) }
        }
        for slew: UInt8 in [0, 1] {
            rig.poke(R.slewMode, slew)
            rig.poke(R.selectedItem, 0)
            rig.poke(R.quickRepeatWindow, 0)
            rig.poke(R.elevator + 1, 0)
            var expected = 0
            for (i, gap) in [0, 0, 1, 2, 3, 4, 0, 2].enumerated() {
                for _ in 0..<gap { tick5Hz() }
                let open = rig.peek(R.quickRepeatWindow) != 0 && slew == 0
                press(0x42, "slew \(slew) B \(i) after \(gap) ticks")
                expected = min(0x50, expected + (open ? 16 : 4))
                #expect(Int(rig.peek(R.elevator + 1)) == expected, "slew \(slew) B \(i)")
                #expect(rig.peek(R.quickRepeatWindow) == 3)
            }
            for (i, gap) in [0, 0, 3, 0, 1].enumerated() {
                for _ in 0..<gap { tick5Hz() }
                press(0x54, "slew \(slew) T \(i) after \(gap) ticks")
            }
            // The joystick: port 1 down/up with the window open still steps 4.
            for latch: UInt8 in [0x02, 0x01, 0x02] {
                rig.poke(R.elevator + 1, 0x10)
                let before = rig.peek(R.elevator + 1)
                rig.poke(R.quickRepeatWindow, 3)
                rig.poke(R.joyPort1, latch)
                rig.poke(R.joyPort2, 0)
                rig.run(0x2688, "slew \(slew) joystick \(hex(latch))") { $0.joystickAction(); return .init() }
                let step = latch == 0x02 ? 4 : -4
                #expect(Int(Int8(bitPattern: rig.peek(R.elevator + 1))) == Int(Int8(bitPattern: before)) + step)
            }
        }
        // The clamps: B stops at $50 from $4C with the window (+16 → $5C), T at $B0.
        rig.poke(R.slewMode, 0)
        for (start, code, window) in [(UInt8(0x4C), UInt8(0x42), UInt8(3)), (0x48, 0x42, 0), (0x7C, 0x42, 0),
                                      (0xB4, 0x54, 3), (0xB8, 0x54, 0), (0x84, 0x54, 0), (0xB0, 0x54, 0)] {
            rig.poke(R.elevator + 1, start)
            rig.poke(R.quickRepeatWindow, window)
            press(code, "clamp from \(hex(start)) code \(hex(code)) window \(window)")
        }
        rig.expectClean("elevator window")
    }

    // MARK: Joystick

    /// Every combination of the two latched ports (5 bits each), from several states and
    /// selected items (view prefix 1, magnetos 3, radar), including port 2 down + fire, where the
    /// guns depend on the A the throttle marker leaves.
    @Test func joystickActionAllLatches() throws {
        for name in ["regular", "demo", "in-war", "in-slew"] {
            let rig = InputRig(try InputStates.ram(name))
            var rng = TestRandom(seed: 0x10F0 ^ UInt64(name.count))
            for port1 in 0..<32 {
                for port2 in 0..<32 {
                    Self.perturb(rig, &rng)
                    rig.poke(R.selectedItem, [0, 1, 3, 2][Int(rng.next() % 4)])
                    rig.poke(R.joyPort1, UInt8(port1))
                    rig.poke(R.joyPort2, UInt8(port2))
                    rig.run(0x2688, "\(name) port 1 \(hex(UInt8(port1))) port 2 \(hex(UInt8(port2)))") {
                        $0.joystickAction(); return .init()
                    }
                }
            }
            rig.expectClean("joystick, \(name)")
        }
    }

    /// The auto-centering countdown and the over-control limiter of `centerControls`.
    @Test func autoCentering() throws {
        let rig = InputRig(try Original.demoFlight())
        var rng = TestRandom(seed: 0xA0C0)
        for counter: UInt8 in [0, 1, 2, 3, 4, 7, 0x80, 0xFF] {
            for used: UInt8 in [0, 1, 3] {
                for _ in 0..<6 {
                    Self.perturb(rig, &rng)
                    rig.poke(R.autoCenterCounter, counter)
                    rig.poke(R.joystickUsed, used)
                    rig.run(0x26EC, "autoCenter counter \(hex(counter)) used \(used)") { $0.autoCenter(); return .init() }
                }
            }
        }
        // The limiter branch: half the limiter + roll term high byte reaching the limiter.
        for (limiter, roll): (UInt8, UInt8) in [(0, 0), (0x20, 0x10), (0x20, 0x0F), (0x40, 0x30), (0xFF, 0x80),
                                                (0xFF, 0x7F), (0x10, 0xF8)] {
            Self.perturb(rig, &rng)
            rig.poke(R.overControlLimiter, limiter)
            rig.poke(R.rollTerm + 1, roll)
            rig.run(0x2D9D, "centerControls limiter \(hex(limiter)) roll \(hex(roll))", regs: RoutineHarness.Registers(a: 0)) {
                $0.centerControls(); return .init()
            }
        }
        rig.expectClean("auto-centering")
    }

    // MARK: Entry points of other units and the $2000 vectors

    @Test func entryPoints() throws {
        for name in InputStates.names {
            let rig = InputRig(try InputStates.ram(name))
            var rng = TestRandom(seed: 0xE7E7 ^ UInt64(name.count))
            for i in 0..<40 {
                Self.perturb(rig, &rng)
                let l = "\(name) \(i)"
                rig.run(0x2D58, "$2D58 \(l)") { $0.updateElevatorIndicator(); return .init() }
                let throttle = rig.run(0x2C46, "$2C46 \(l)") { .init(a: $0.updateThrottleIndicator()) }
                _ = throttle
                rig.run(0x2E4C, "$2E4C \(l)") { $0.updateRudderIndicator(); return .init() }
                rig.run(0x2DE6, "$2DE6 \(l)") { $0.updateAileronIndicator(); return .init() }
                let flaps = rig.peek(R.flaps + 1)
                rig.run(0x2CD7, "$2CD7 \(l)", regs: RoutineHarness.Registers(a: flaps)) { $0.updateFlaps(flaps); return .init() }
                let code = [UInt8(0), 1, 3][i % 3], label = UInt8(i % 5)
                rig.run(0x2829, "$2829 \(l)", regs: RoutineHarness.Registers(a: code, x: label)) {
                    $0.setMagnetos(code, label: label); return .init()
                }
                rig.run(0x2837, "$2837 \(l)", regs: RoutineHarness.Registers(x: 3)) { $0.setMagnetoLabel(3); return .init() }
                let item = rng.byte()
                rig.run(0x2BBC, "$2BBC \(l)", regs: RoutineHarness.Registers(a: item)) { $0.storeSelected(item); return .init() }
                rig.run(0x2BC9, "$2BC9 \(l)") { $0.keySpace(); return .init() }
                rig.run(0x2DD2, "$2DD2 \(l)") { $0.coordinateRudder(); return .init() }
                rig.run(0x2C31, "$2C31 \(l)") { .init(a: $0.throttleDown()) }
                rig.run(0xE9A7, "$E9A7 \(l)") { $0.selectAdfDigit(); return .init() }
            }
            rig.expectClean("entry points, \(name)")
        }
    }

    // MARK: Ring and slots (no I/O)

    @Test func ringAndSlots() throws {
        let rig = InputRig(try Original.regularFlight())
        var rng = TestRandom(seed: 0x8_1146)
        for i in 0..<600 {
            for slot in 0..<4 {
                rig.poke(R.heldKeySlots + slot, [0x80, 0x80, rng.byte() & 0x3F, rng.byte() & 0x7F, rng.byte()][Int(rng.next() % 5)])
                rig.poke(R.repeatCounters + slot, rng.byte() & 7)
            }
            rig.poke(R.ctrlHeld, [0, 0, 1][Int(rng.next() % 3)])
            rig.poke(R.keyQueueWrite, rng.byte())
            rig.poke(R.keyQueueRead, rng.next() % 4 == 0 ? rig.peek(R.keyQueueWrite) : rng.byte())
            let index = [rng.byte() & 0x3F, rng.byte() & 0x7F, 0x3A, 0x0F, rig.peek(R.heldKeySlots + 2)][Int(rng.next() % 5)]
            rig.run(0x24C2, "keyPress \(i) index \(hex(index))", regs: RoutineHarness.Registers(a: index)) {
                $0.keyPress(index); return .init()
            }
            let y = [rng.byte() & 0x3F, rng.byte() & 0x7F, 0x3A][Int(rng.next() % 3)]
            rig.run(0x24EB, "requeueKey \(i) index \(hex(y))", regs: RoutineHarness.Registers(y: y)) {
                $0.requeueKey(y); return .init()
            }
            let code = rng.byte()
            rig.run(0x25DC, "enqueueKey \(i)", regs: RoutineHarness.Registers(a: code)) { $0.enqueueKey(code); return .init() }
            for k in 0..<3 {
                rig.run(0x25C4, "dequeueKey \(i).\(k)") { m in
                    let r = m.dequeueKey(); return .init(a: r.code, carry: r.carry)
                }
            }
        }
        rig.expectClean("ring and slots")
    }

    // MARK: waitForKey ($2250)

    /// The wait loop: one poll that delivers a queued key; several polls while a held key's
    /// repeat delay runs out (slot 3, then the re-queued key is dispatched); and the restore of
    /// `$08BA`, `$08D3` and `$08CC`. The port's poll is its own `pollTick` ($2330); the SID stores
    /// of the ticks it runs are compared exactly.
    @Test func waitForKeyLoop() throws {
        for name in ["regular", "demo", "in-war"] {
            let rig = InputRig(try InputStates.ram(name))
            var rng = TestRandom(seed: 0x2250 ^ UInt64(name.count))
            for i in 0..<60 {
                rig.poke(R.keyDispatchInhibit, 0)
                rig.poke(R.editorRequest, [0, 0, 1][i % 3])
                rig.poke(R.soundEnable, [0, 1, 1, 0xFF][i % 4])
                rig.poke(R.pauseCount, [0, 0, 1, 2][i % 4])
                rig.poke(R.promptKey, rng.byte() & 0x7F)
                for slot in 0..<4 { rig.poke(R.heldKeySlots + slot, 0x80) }
                rig.poke(R.keyQueueRead, rig.peek(R.keyQueueWrite))
                if i % 2 == 0 {
                    // One poll: a key is waiting and a tick is due.
                    rig.poke(0x0E6B, 6 + UInt8(rng.next() % 6))
                    rig.enqueue(rng.byte())
                } else {
                    // Several polls: RUN/STOP-like hold in slot 3 with its repeat delay.
                    let delay = UInt8(rng.next() % 6)
                    rig.poke(R.heldKeySlots + 3, [0x22, 0x1C, 0x3E, 0x10][Int(rng.next() % 4)])
                    rig.poke(R.repeatCounters + 3, delay)
                    rig.poke(R.ctrlHeld, 0)
                    rig.poke(0x0E6B, 6 * (delay + 3) + UInt8(rng.next() % 6))
                }
                rig.run(0x2250, "\(name) \(i)") { .init(a: $0.waitForKey()) }
            }
            rig.expectClean("waitForKey, \(name)")
        }
    }

    // MARK: restoreNmi ($2700)

    @Test func restoreNmi() throws {
        let rig = InputRig(try Original.regularFlight())
        var restarts = 0
        for slot3: UInt8 in [0x3F, 0x80, 0x3E, 0x07, 0xBF] {
            for oneShot: UInt8 in [0, 1, 2, 0xFF] {
                rig.poke(R.heldKeySlots + 3, slot3)
                rig.poke(R.restoreOneShot, oneShot)
                var restart = false
                // Stop at the handler's return ($2714, 6 cycles) or at the restart's target $A7E2.
                rig.run(0x2700, "slot 3 \(hex(slot3)) one-shot \(hex(oneShot))", stopAt: [0x2714, 0xA7E2],
                        extraOriginalCycles: { $0 == 0x2714 ? 6 : 0 }) { m in
                    restart = m.restoreNmi(); return .init()
                }
                #expect(restart == (slot3 == 0x3F && oneShot == 0))
                if restart { restarts += 1 }
            }
        }
        #expect(restarts == 1)
        rig.expectClean("restoreNmi")
    }
}
