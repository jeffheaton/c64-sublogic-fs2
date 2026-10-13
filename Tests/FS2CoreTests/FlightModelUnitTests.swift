import FS2Core
import Foundation
import Testing

/// Unit tests of the flight model ports that need no disk image: the documented formulas,
/// thresholds, quirks and cycle costs, on synthetic memory. The differential tests
/// (DifferentialTests/FlightModelTests.swift) prove the ports against the original routines.
struct FlightModelUnitTests {
    typealias R = FlightModel.RAM

    /// All-zero memory with a computed cosine table (floor(32767·cos(i·1.40625°)); the real
    /// table, with its glitches, comes from the disk at run time).
    static func machine() -> Machine {
        let m = Machine(memory: [UInt8](repeating: 0, count: Machine.memorySize))
        for i in 0..<Machine.cosTableCount {
            let v = (32767 * cos(Double(i) * 1.40625 * .pi / 180)).rounded(.down)
            m.setS16(Machine.cosTableAddress + 2 * i, Int16(v))
        }
        return m
    }

    /// Records bridge calls (address, registers) without running anything.
    final class BridgeLog {
        var calls: [(UInt16, CPURegisters)] = []
        func install(on m: Machine) {
            m.originalBridge = { [unowned self] _, address, regs in
                self.calls.append((address, regs))
                return regs
            }
        }
    }

    static func cycles(_ m: Machine, _ body: () -> Void) -> UInt64 {
        let start = m.clock.cycles
        body()
        return m.clock.cycles - start
    }

    // MARK: Integrator

    @Test func dtFromJiffiesWithTheStaleLowByte() {
        let m = Self.machine()
        m[R.lastJiffy] = 0xF0
        m[R.jiffyCounter] = 0x2C              // 60 jiffies later, across the wrap
        m[R.mathResult] = 0                    // no stale term
        m.integrateFlight()
        #expect(m.u16(R.frameDt) == 60 * 0x0222)
        #expect(m[R.lastJiffy] == 0x2C && m[R.slewResetRequest] == 1)
        // The stale $C4 adds C4·$0222/256.
        m[R.jiffyCounter] = 0x2C &+ 30
        m[R.mathResult] = 0x80
        m.integrateFlight()
        #expect(m.u16(R.frameDt) == UInt16(((30 * 256 + 0x80) * 0x0222) >> 8))
        // Bit 15 set: the high byte becomes $7F.
        m[R.jiffyCounter] = 0x2C &+ 30 &+ 100
        m[R.mathResult] = 0
        m.integrateFlight()
        #expect(m[R.frameDt + 1] == 0x7F && m[R.frameDt] == UInt8((100 * 0x0222) & 0xFF))
        // The 16-bit dt wraps every 120 jiffies: 121 starts again from about one jiffy, and
        // 181 is past bit 15 again.
        for (gap, expected) in [(121, 0x0212), (180, 0x7FE8), (181, 0x7F0A), (241, 0x0202)] {
            m[R.jiffyCounter] = m[R.lastJiffy] &+ UInt8(gap)
            m[R.mathResult] = 0
            m.integrateFlight()
            #expect(m.u16(R.frameDt) == UInt16(expected), "gap \(gap)")
        }
    }

    @Test func positionStepFollowsTheQuantizedTrack() {
        let m = Self.machine()
        m.setU24(R.altitude, 0x01_0000)        // 256 m
        m.setS16(R.cosGamma, 32767)
        m.setU16(R.airspeed, 0x3000)           // 48 m/s
        m.setU16(R.heading, 0x4040)            // just past 90°: the track is the high byte $40
        m[R.lastJiffy] = 0; m[R.jiffyCounter] = 60; m[R.mathResult] = 0
        m.integrateFlight()
        let d = Int(m.u16(R.stepDistance))
        #expect(abs(d - 0x3000) <= 4)          // V × 1 s (two Q15 products)
        #expect(m.s16(R.sinTrack) == 32767 && m.s16(R.cosTrack) == 0)
        #expect(abs(Int(m.s32(R.eastPosition)) - d) <= 4 && m.s32(R.northPosition) == 0)
        #expect(m[R.onGround] == 0 && m.u16(R.verticalSpeed) == 0)
    }

    @Test func groundContactCrashAndTouchdown() {
        let m = Self.machine()
        m[R.mathResult] = 0
        // Descending at 9 m/s onto the ground for the first time: crash, then the touchdown store.
        m.setU24(R.altitude, 0x00_0280)
        m[R.verticalSpeed + 1] = 0xF7
        m[R.airspeed + 1] = 0x20
        m[R.wasOnGround] = 0
        m.integrateFlight()
        #expect(m[R.onGround] == 0xFF && m[R.crashCode] == 4 && m[R.airspeed + 1] == 0)
        #expect(m[R.soundState] == 8 && m[R.wasOnGround] == 0xFF && m[R.viewPitchBump] == 0xF7)
        #expect(!m.io.sidWrites.isEmpty)       // sfxCrash
        // −8 m/s and level: a landing.
        let n = Self.machine()
        n.setU24(R.altitude, 0x00_0280)
        n[R.verticalSpeed + 1] = 0xF8
        n.integrateFlight()
        #expect(n[R.crashCode] == 0 && n[R.soundState] == 8)
        // Banked 15.5°: the view bank high byte is −11.
        let b = Self.machine()
        b.setU24(R.altitude, 0x00_0280)
        b[R.verticalSpeed + 1] = 0xFF
        b.setU16(R.bankAngle, 0x0B00)
        b.integrateFlight()
        #expect(b[R.crashCode] == 4 && b.u16(R.bankAngle) == 0)
    }

    @Test func altitudeBelowTheDatumBecomesThreeMeters() {
        let m = Self.machine()
        m.setU24(R.altitude, 0x00_0100)
        m.setS16(R.sinGamma, -32767)
        m.setU16(R.airspeed, 0x7000)
        m[R.jiffyCounter] = 60; m[R.mathResult] = 0
        m.integrateFlight()
        #expect(m.u24(R.altitude) == 0x00_0300 && m[R.onGround] == 0xFF)
    }

    // MARK: Density, auto-level, service

    @Test func densityIsTwoAndAHalfPerMeter() {
        let m = Self.machine()
        for meters in [0, 1, 2, 3, 100, 101, 1000, 4000, 13000] {
            m.setU16(R.mslAltitude, UInt16(meters))
            m.densityAndAutoLevel()
            #expect(Int(m.u16(R.airDensity)) == 0x7FFD - (2 * meters + (meters + 1) / 2), "\(meters) m")
        }
    }

    @Test func autoLevelMovesTheBankTowardZero() {
        let m = Self.machine()
        for (bank, expected) in [(1000, 921), (79, 0), (80, 1), (-1000, -919), (-81, 0), (-82, -1), (0, 0)] {
            m.setS16(R.bankAngle, Int16(bank))
            let c = Self.cycles(m) { m.densityAndAutoLevel() }
            #expect(Int(m.s16(R.bankAngle)) == expected, "bank \(bank)")
            #expect(c > 100 && c < 130)
        }
        // A deflected rudder holds the bank.
        m[R.rudder + 1] = 4
        m.setS16(R.bankAngle, 1000)
        m.densityAndAutoLevel()
        #expect(m.s16(R.bankAngle) == 1000)
        // Slew: nothing at all.
        m[R.slewMode] = 1
        m.setU16(R.mslAltitude, 500)
        let before = m.memoryImage
        #expect(Self.cycles(m) { m.densityAndAutoLevel() } == 13 && m.memoryImage == before)
    }

    @Test func serviceRefuelsRepairsAndRearms() {
        let m = Self.machine()
        m[R.serviceRequest] = 2
        m[R.failureMasks] = 0x12; m[R.engineFailureBits] = 0x0F; m[R.hitsTaken] = 3
        m.densityAndAutoLevel()
        #expect(m[R.leftFuel] == 0x20 && m[R.rightFuel] == 0x20 && m[R.failureMasks] == 0xFF)
        #expect(m[R.engineFailureBits] == 0 && m[R.hitsTaken] == 0 && m[R.serviceCount] == 1)
        #expect(m[R.fuelFlags] == 1 && m[R.fuelFlags + 1] == 1)
        #expect(m[R.ammo] == 100 && m[R.bombCount] == 0x35 && m[R.serviceRequest] == 0)
        // Moving: no service, but the request is dropped.
        m[R.serviceRequest] = 1; m[R.airspeed + 1] = 1; m[R.leftFuel] = 3
        m.densityAndAutoLevel()
        #expect(m[R.leftFuel] == 3 && m[R.serviceRequest] == 0)
        #expect(Self.cycles(m) { m.serviceAircraft() } == 60)
    }

    // MARK: Slew

    @Test func slewStepIsExponential() {
        for rate in [0, 3, 4, 8, 20, 0x7F] {
            let m = Self.machine()
            m[R.ailerons + 1] = UInt8(rate)
            m.slewIntegrate()
            #expect(m.u32(R.eastPosition) == UInt32(min((1 << (rate / 4)) - 1, 0xFF_FFFF)) << 8, "rate \(rate)")
        }
        for rate in [-1, -4, -5, -8, -40] {
            let m = Self.machine()
            m[R.ailerons + 1] = UInt8(bitPattern: Int8(rate))
            m.slewIntegrate()
            let n = (-rate + 3) / 4
            let step = n >= 24 ? 0 : Int32(truncatingIfNeeded: 0xFFFF_FFFF << n) & 0xFF_FFFF
            #expect(m.u32(R.eastPosition) == UInt32(step) << 8, "rate \(rate)")
        }
    }

    @Test func slewResetAndDisplayPosition() {
        let m = Self.machine()
        m[R.slewResetRequest] = 1
        m[R.elevator + 1] = 0x10; m[R.rudder + 1] = 0x20; m[R.slewAltitudeRate] = 5
        m.setU32(R.northPosition, 0x0324_0000); m.setU32(R.eastPosition, 0x011F_0000)
        m.slewIntegrate()
        #expect(m[R.slewResetRequest] == 0 && m[R.elevator + 1] == 0 && m[R.rudder + 1] == 0)
        #expect(m[R.slewAltitudeRate] == 0)
        #expect(m.u16(R.settingNorth) == 0x4324 && m.u16(R.settingEast) == 0x411F)
        // Altitude never goes below 0.
        m[R.slewAltitudeRate] = 0x80
        m.slewIntegrate()
        #expect(m.u24(R.altitude + 1) == 0)
    }

    // MARK: Wind

    @Test func windDriftOnlyWhenAirborne() {
        let m = Self.machine()
        m.setS16(R.windDriftEast, 0x0100)
        m.setS16(R.windDriftNorth, -0x0200)
        m.setS32(R.eastPosition, 1000); m.setS32(R.northPosition, 1000)
        m.windDrift()
        #expect(m.s32(R.eastPosition) == 1000 - 256 && m.s32(R.northPosition) == 1000 + 512)
        #expect(m[FlightModel.RAM.scratchA5] == 0xFF)
        m[R.onGround] = 0xFF
        #expect(Self.cycles(m) { m.windDrift() } == 13 && m.s32(R.eastPosition) == 1000 - 256)
    }

    @Test func windLayerByShearBounds() {
        let m = Self.machine()
        m.setS16(R.shear1, 100); m.setS16(R.shear2, 200); m.setS16(R.shear3, 300)
        // Surface layer: speed 10 from the east (direction $40), dt high byte $7F.
        m[0x09A0] = 10; m[0x09A3] = 0x40
        m[R.frameDt + 1] = 0x7F
        m.setU24(R.altitude, 50 << 8)
        m.windLayer()
        #expect(m.u16(R.recordPointer) == 0x09A0 && m[FlightModel.RAM.windSurfaceFlag] == 0)
        #expect(m.s16(R.windDriftEast) > 0 && abs(Int(m.s16(R.windDriftNorth))) < 64)
        // Above shear 3: wind3 at $0994.
        m.setU24(R.altitude, 300 << 8)
        m.windLayer()
        #expect(m.u16(R.recordPointer) == 0x0994)
    }

    // MARK: Engine

    @Test func starterBusyWaitAndBridge() throws {
        #expect(Machine.starterBusyWaitCycles == 586_756)
        let m = Self.machine()
        let log = BridgeLog()
        log.install(on: m)
        m[R.realityMode] = 1
        m[R.magnetoState] = 1; m[R.fuelFlags] = 1
        m[R.leftFuel] = 0x20
        m[R.magnetoLabel] = 4
        let c = Self.cycles(m) { m.engineModel() }
        #expect(m[R.engineRunning] == 1)
        // $2837 (`setMagnetoLabel`, the input unit's port) stores label 3 (BOTH) and redraws.
        #expect(log.calls.isEmpty && m[R.magnetoLabel] == 3)
        #expect(c > UInt64(Machine.starterBusyWaitCycles) && c < UInt64(Machine.starterBusyWaitCycles) + 3000)
    }

    @Test func engineStopsAndRunsOnTheTargetTable() {
        let m = Self.machine()
        for i in 0..<32 { m[FlightModel.RAM.rpmTargetTable + i] = UInt8(0x0D + i) }
        m[R.leftFuel] = 0x20
        m[R.throttle] = 0x78
        m[R.magnetoState] = 1; m[R.magnetoState + 1] = 1; m[R.fuelFlags] = 1; m[R.fuelFlags + 1] = 1
        m.engineModel()                        // not reality mode: the engine just runs
        #expect(m[R.engineRunning] == 1 && m[R.engineTargetRpm] == UInt8(0x0D + 0x78 / 4))
        // An empty selected tank stops it; outside reality mode the shown RPM stays ≥ $0D.
        m[R.leftFuel] = 0
        m.engineModel()
        #expect(m[R.engineRunning] == 0 && m[R.engineTargetRpm] == 0x0D && m.u16(R.thrust) == 0)
    }

    @Test func oilRampsTowardItsTargets() {
        let m = Self.machine()
        m[R.leftFuel] = 0x20
        m.engineModel()
        #expect(m.u16(R.oilTemperature) == 0x19 && m.u16(R.oilPressure) == 0xFA)
        m.setU16(R.oilTemperature, 0x0905)
        m.engineModel()
        #expect(m.u16(R.oilTemperature) == 0x0905)   // at the target high byte: no change
    }

    // MARK: Failures

    @Test func trimCreepMovesTwoTowardTheTrim() {
        let m = Self.machine()
        let log = BridgeLog()
        log.install(on: m)
        m[R.elevator + 1] = 0x10; m[R.elevatorTrim] = 0x00
        m.trimCreep()
        #expect(m[R.elevator + 1] == 0x10 && log.calls.isEmpty)       // not in reality mode
        m[R.realityMode] = 1
        m.trimCreep()
        // $2D58 (`updateElevatorIndicator`, the input unit's port): marker ($50 - elevator) >> 3.
        let marker = 0x2715
        #expect(m[R.elevator + 1] == 0x0E && m[marker] == 0x08)
        m[R.elevator + 1] = 0xF0
        m.trimCreep()
        #expect(m[R.elevator + 1] == 0xF2 && m[marker] == 0x0B)
        m[R.elevator + 1] = 0x00
        m.trimCreep()
        #expect(m[R.elevator + 1] == 0x00 && m[marker] == 0x0A && log.calls.isEmpty)
    }

    @Test func realityDriftsTheGyroAndAltimeter() {
        let m = Self.machine()
        m[R.realityMode] = 1
        m[R.failureCountdown] = 5
        m.setS16(R.altimeterDrift, 0x0003)
        m.realityFailures(carry: false)
        #expect(m[R.failureCountdown] == 4 && m.u16(R.dgOffset) == 2)
        // altimeterOffset_hi (0) − drift_lo (3) < 0: +2.
        #expect(m.s16(R.altimeterOffset) == 2)
        m[R.realityMode] = 0
        #expect(Self.cycles(m) { m.realityFailures(carry: true) } == 33)
        #expect(m.u16(R.dgOffset) == 0 && m.u16(R.altimeterOffset) == 0)
    }

    // MARK: Ground, timers, altitude

    @Test func groundElevationTracksTheTarget() {
        let m = Self.machine()
        m[R.airspeed + 1] = 0x20
        m.setU16(R.terrainElevationTarget, 10)
        m.setU24(R.altitude, 100 << 8)
        m.trackGroundElevation()
        #expect(m.u16(R.fieldElevation) == 2 && m.u24(R.altitude) == 98 << 8)
        // Slow: the field jumps; the steps then find nothing to do.
        m[R.airspeed + 1] = 0x09
        m.trackGroundElevation()
        #expect(m.u16(R.fieldElevation) == 10 && m.u24(R.altitude) == 98 << 8)
        // Down 2 m, with the 3 m floor.
        m[R.airspeed + 1] = 0x20
        m.setU16(R.terrainElevationTarget, 0)
        m.setU24(R.altitude, 2 << 8)
        m.trackGroundElevation()
        #expect(m.u16(R.fieldElevation) == 8 && m.u24(R.altitude) == 4 << 8)
        m.setU16(R.terrainElevationTarget, 20)
        m.trackGroundElevation()
        #expect(m.u16(R.fieldElevation) == 10 && m.u24(R.altitude) == 3 << 8)
    }

    @Test func regimeTimerThresholds() {
        let m = Self.machine()
        func reloads(gamma: UInt8 = 0, bank: UInt8 = 0, speed: UInt8 = 0) -> Bool {
            m[R.maneuverTimer] = 0
            m[R.flightPathAngle + 1] = gamma; m[R.bankAngle + 1] = bank; m[R.airspeed + 1] = speed
            m.maneuverRegimeTimer()
            return m[R.maneuverTimer] == 6
        }
        #expect(!reloads() && !reloads(gamma: 0x0E) && reloads(gamma: 0x0F))
        #expect(!reloads(gamma: 0xF1) && reloads(gamma: 0xF0))       // −15 does not, −16 does
        #expect(!reloads(bank: 0x15) && reloads(bank: 0x16) && !reloads(bank: 0xEA) && reloads(bank: 0xE9))
        #expect(!reloads(speed: 0x48) && reloads(speed: 0x49))
        m[R.maneuverTimer] = 3
        m.maneuverRegimeTimer()
        #expect(m[R.maneuverTimer] == 2)
    }

    @Test func splashNeedsThreeChecks() {
        let m = Self.machine()
        m[R.onGround] = 0xFF
        m[FlightModel.RAM.splashProbe] = 0x55
        m[FlightModel.RAM.splashCounter] = 3
        m.splashDetect(); m.splashDetect()
        #expect(m[R.crashCode] == 0 && m[FlightModel.RAM.splashCounter] == 1)
        m.splashDetect()
        #expect(m[R.crashCode] == 8 && m[FlightModel.RAM.splashCounter] == 3)
        m[R.crashCode] = 0
        m[R.viewDirection] = 2
        m.splashDetect(); m.splashDetect(); m.splashDetect()
        #expect(m[R.crashCode] == 0)
    }

    @Test func editorAltitudeFromFeet() {
        let m = Self.machine()
        m.setU16(R.settingAltitude, 1000)
        m.setU16(R.fieldElevation, 180)
        m[R.altitude] = 0x55; m[R.altitude + 3] = 0x55
        m.setAltitudeFromEditor()
        #expect(Int(m.u16(R.altitude + 1)) == ((1009 * 0x4E0C) >> 16) - 180)
        #expect(m[R.altitude] == 0 && m[R.altitude + 3] == 0)
        m.setU16(R.settingAltitude, 0)
        m.setAltitudeFromEditor()
        #expect(m.u16(R.altitude + 1) == 3)
    }

    @Test func crashMessageTextSoundAndReload() throws {
        let m = Self.machine()
        let log = BridgeLog()
        log.install(on: m)
        m[R.crashCode] = 8
        let cycles = Self.cycles(m) { m.crashMessage(code: 8) }
        #expect(m.u16(R.tablePtr) == 0xF950 && m[R.crashCode] == 0 && m[R.modeRequest] == 1)
        // The ported busyDelay (Y = 5, 2,283,560 cycles) runs in place of the former bridge call.
        #expect(log.calls.isEmpty && cycles > 2_283_560)
        #expect(!m.io.sidWrites.isEmpty)
        m.crashMessage(code: 4)
        #expect(m.u16(R.tablePtr) == 0xF944)
    }
}
