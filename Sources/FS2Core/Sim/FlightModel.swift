/// The flight model and engine: a translation of the original's aerodynamics, integrators,
/// wind, failures, engine and ground handling. See `re/docs/flight-model.md`.
///
/// | Range | Port | File |
/// |---|---|---|
/// | $2E92-$2F3F | `controlCoefficients()`, `rebuildWingCoefficients()` | `ControlCoefficients.swift` |
/// | $2F45-$32DE | `aeroUpdate()` (5 Hz) | `Aerodynamics.swift` |
/// | $32DF-$365F | `mulQ15Times4`, `integrateFlight()`, `densityAndAutoLevel()`, `serviceAircraft()` | `Integrator.swift` |
/// | $3660-$3772 | `slewIntegrate()`, `slewAux()` | `Slew.swift` |
/// | $E716-$E7F1 | `windDrift()`, `windLayer()` | `Wind.swift` |
/// | $EA5C-$EB81 | `realityFailures(carry:)`, `trimCreep()` and the failure handlers | `Failures.swift` |
/// | $EE14-$F079 | `engineModel()` | `Engine.swift` |
/// | $F8AF-$F9F8 | `trackGroundElevation()`, `maneuverRegimeTimer()`, `crashMessage(code:)`, `splashDetect()`, `setAltitudeFromEditor()` | `Ground.swift` |
///
/// Conventions (the same as the math library's):
/// - Every routine reads and writes the bytes its original reads and writes, at the same
///   addresses, zero-page temporaries included (`$B8/$B9`, `$BA/$BB`, `$BC/$BD`, `$BE`,
///   `$C0/$C1`, `$C4-$CB`, `$A5-$A7`). Tables and constants are read from memory.
/// - Each routine charges the cycles of its own instructions, from its first instruction through
///   its return, progressively (before each call it makes); the caller charges its call. The costs
///   are exact, including taken branches, page crossings and the busy-wait of the starter.
/// - Calls into routines of other units go to their ports.
/// - None of the callers reads a register or flag these routines leave, so they return nothing.
///   The two inputs taken from registers are `crashMessage(code:)` (A) and
///   `realityFailures(carry:)` (the caller's carry reaches an addition).
public enum FlightModel {
    /// Variables at their original addresses (names from `re/symbols.json`).
    public enum RAM {
        // MARK: Zero page
        public static let mainLoopCounter = 0x22
        public static let jiffyCounter = 0x34
        /// `$5A-$5D` east position, signed 32-bit, 1/256 m.
        public static let eastPosition = 0x5A
        /// `$5E-$61` altitude above the local ground datum, 1/256 m (`$5F:$60` whole meters).
        public static let altitude = 0x5E
        /// `$62-$65` north position, signed 32-bit, 1/256 m.
        public static let northPosition = 0x62
        public static let viewPitch = 0x6C
        public static let viewBank = 0x6E
        public static let viewHeading = 0x70
        /// `$A5`/`$A6`/`$A7`: shared scratch bytes.
        public static let scratchA5 = 0xA5
        public static let scratchA6 = 0xA6
        public static let scratchA7 = 0xA7
        /// `$B8/$B9` `printValue`, used as scratch by several routines here.
        public static let printValue = 0xB8
        /// `$BA/$BB` table pointer of `interpBySpeed`; the crash message keeps its text pointer here.
        public static let tablePtr = 0xBA
        /// `$BC` windmilling RPM (engine scratch); `$BC/$BD` is also the failure dispatch pointer.
        public static let windmillRpm = 0xBC
        /// `$BE` scratch (the slew step's high byte).
        public static let scratchBE = 0xBE
        /// `$C0/$C1` record pointer (the wind layer record here).
        public static let recordPointer = 0xC0
        public static let mathResult = 0xC4
        public static let mathOperand = 0xC6
        public static let product32 = 0xC8

        // MARK: Game state
        public static let mslAltitude = 0x0830
        public static let crashCode = 0x0834
        public static let radarMode = 0x0836
        public static let serviceRequest = 0x0838
        public static let terrainElevationTarget = 0x0843
        /// `$0846/$0847` per-area heading offset (the wind uses the high byte).
        public static let headingOffsetA = 0x0846
        /// `$0848/$0849` second per-area heading offset (surface wind layer only).
        public static let headingOffsetB = 0x0848
        public static let hitsTaken = 0x08B7
        public static let serviceCount = 0x08B8
        public static let modeRequest = 0x08BB
        public static let dgOffset = 0x08C0
        public static let lastJiffy = 0x08CA
        /// `$08CD` countdown of reality-mode passes between failure checks (reloaded with 10).
        public static let failureCountdown = 0x08CD
        public static let damageLevel = 0x08D4
        public static let lightsColorSet = 0x08DC
        public static let bombCount = 0x08E8
        public static let failureMasks = 0x0942
        public static let slewMode = 0x0966
        public static let realityMode = 0x0967
        public static let europe1917 = 0x0969
        public static let settingNorth = 0x096B
        public static let settingEast = 0x096D
        public static let settingAltitude = 0x096F
        public static let shear1 = 0x098E
        public static let shear2 = 0x0990
        public static let shear3 = 0x0992
        public static let reliability = 0x09A4
        public static let engineFailureBits = 0x09BF
        /// `$09C0/$09C1` low 16 bits of the left tank; `leftFuel` is the high byte.
        public static let leftFuelFraction = 0x09C0
        public static let leftFuel = 0x09C2
        /// `$09C3/$09C4` low 16 bits of the right tank; `rightFuel` is the high byte.
        public static let rightFuelFraction = 0x09C3
        public static let rightFuel = 0x09C5
        public static let fuelTankSelect = 0x09C6
        public static let fuelFlags = 0x09C7
        public static let engineRunning = 0x09C9
        public static let oilTemperature = 0x09CA
        public static let oilPressure = 0x09CC
        public static let altimeterOffset = 0x09CE
        public static let altimeterDrift = 0x09D0
        public static let windDriftEast = 0x09D3
        public static let windDriftNorth = 0x09D5
        /// `$09D7` surface-layer flag: incremented by the surface layer, shifted out right after.
        public static let windSurfaceFlag = 0x09D7
        public static let verticalDelta = 0x09D8
        public static let airDensity = 0x09DA
        public static let aoaProxy = 0x09DC
        public static let flightPathAngle = 0x09DE
        public static let bankAngle = 0x09E0
        public static let liftCoefficient0 = 0x09E2
        public static let dragCoefficient0 = 0x09E4
        public static let inducedDragFactor = 0x09E6
        public static let cosGamma = 0x09E8
        /// `$09EA` cos γ · d, the horizontal part of the step.
        public static let horizontalStep = 0x09EA
        public static let cosPhi = 0x09EC
        public static let cosTrack = 0x09EE
        /// `$09F0` W · cos γ.
        public static let weightCosGamma = 0x09F0
        public static let slip = 0x09F2
        public static let slipYaw = 0x09F4
        public static let slipRoll = 0x09F6
        public static let cosPhiSquaredSigned = 0x09F8
        public static let gammaRate = 0x09FA
        public static let rollTerm = 0x09FC
        public static let turnRate = 0x09FE
        public static let drag = 0x0A00
        public static let acceleration = 0x0A02
        public static let rudderGainResult = 0x0A04
        public static let eastDelta = 0x0A06
        /// `$0A08` thrust − drag.
        public static let netForce = 0x0A08
        public static let flapDrag = 0x0A0A
        public static let viewPitchOffset = 0x0A0B
        public static let frameDt = 0x0A0D
        public static let stepDistance = 0x0A0F
        public static let wasOnGround = 0x0A11
        public static let onGround = 0x0A12
        public static let heading = 0x0A13
        public static let slipDrag = 0x0A15
        public static let aileronCoefficient = 0x0A1D
        public static let wingLift = 0x0A1F
        public static let liftCoefficientLeft = 0x0A21
        public static let liftCoefficientRight = 0x0A23
        public static let flapLift = 0x0A25
        public static let liftScale = 0x0A27
        public static let liftTotal = 0x0A29
        public static let liftLeft = 0x0A2B
        public static let liftRight = 0x0A2D
        public static let viewPitchBump = 0x0A2F
        public static let inverseMass = 0x0A30
        public static let rollScale = 0x0A32
        /// `$0A34` 4 · (liftLeft − liftRight).
        public static let liftDifference = 0x0A34
        public static let northDelta = 0x0A36
        /// `$0A3E` sin γ (Q15).
        public static let sinGamma = 0x0A3E
        /// `$0A40` sin φ (Q15).
        public static let sinPhi = 0x0A40
        public static let sinTrack = 0x0A42
        /// `$0A44` W · sin γ.
        public static let weightSinGamma = 0x0A44
        public static let slipTrackOffset = 0x0A46
        public static let thrust = 0x0A48
        public static let normalForce = 0x0A4A
        public static let airspeed = 0x0A4C
        public static let dynamicPressure = 0x0A4E
        public static let verticalSpeed = 0x0A50
        public static let weight = 0x0A52
        /// `$0A56` left wing coefficient total: wingLift + CL_L (0 when `damageLevel` is set).
        public static let liftCoefficientLeftTotal = 0x0A56
        /// `$0A58` right wing coefficient total: wingLift + CL_R.
        public static let liftCoefficientRightTotal = 0x0A58
        /// `$0A5A` CL_L² (induced drag term).
        public static let liftLeftSquared = 0x0A5A
        /// `$0A5C` CL_R².
        public static let liftRightSquared = 0x0A5C
        public static let aoaToPitch = 0x0A64
        public static let slipRollFactor = 0x0A66
        public static let slipYawFactor = 0x0A68
        public static let slipTrackFactor = 0x0A6A
        public static let slipDragFactor = 0x0A70
        public static let parasiteDragBias = 0x0A74
        public static let constant0A78 = 0x0A78
        /// `$0A80` set to 1 by every `integrateFlight` pass; the first slew pass sees it and
        /// zeroes the controls and the slew rates.
        public static let slewResetRequest = 0x0A80
        public static let repositionCounter = 0x0A83
        public static let fieldElevation = 0x0A87
        public static let mixture = 0x0A9A
        public static let ailerons = 0x0AA3
        public static let ammo = 0x0AA5
        public static let carbHeat = 0x0AA9
        public static let elevator = 0x0AAB
        public static let elevatorTrim = 0x0AAE
        public static let magnetoLabel = 0x0AB6
        public static let rudder = 0x0ABC
        public static let slewBankRate = 0x0ABF
        public static let slewHeadingRate = 0x0AC1
        public static let slewPitchRate = 0x0AC3
        public static let slewAltitudeRate = 0x0AC5
        public static let throttle = 0x0AC9
        public static let viewDirection = 0x0ACA
        public static let engineTargetRpm = 0x0E58
        public static let soundState = 0x0E59
        public static let maneuverTimer = 0x0E75
        /// `$0E76/$0E77` roll cancel, subtracted from the roll term once, then cleared.
        public static let rollCancel = 0x0E76
        public static let skipFlip = 0x0E79
        public static let stallTimer = 0x0E7B
        /// `$0E7F` splash confirmation countdown (3 consecutive checks).
        public static let splashCounter = 0x0E7F
        /// `$50DE` the window bitmap byte the splash detector samples (y 110, x 152-159).
        public static let splashProbe = 0x50DE
        public static let stallLampCells = 0x7E3D

        // MARK: Tables and text in the unit's ranges (read from memory)
        /// `$EA5C` eight failure handler addresses.
        public static let failureHandlers = 0xEA5C
        /// `$EA6C`: the text record of the aircraft-problem message, at (50, 20).
        public static let aircraftProblemRecord: UInt16 = 0xEA6C
        /// `$EE14/$EE15` magneto state (switch & 1, switch >> 1).
        public static let magnetoState = 0xEE14
        public static let carbHeatCountdown = 0xEE16
        /// `$EE17` RPM/50 target by throttle >> 2 (32 bytes).
        public static let rpmTargetTable = 0xEE17
        /// `$EE37` windmilling RPM/50 by min(31, V_hi >> 2) (32 bytes).
        public static let windmillRpmTable = 0xEE37
        /// `$F944` 'CRASH !!!' and `$F950` 'SPLASH !!!' records.
        public static let crashRecord = 0xF944
        public static let splashRecord = 0xF950
    }

    // MARK: 6502 arithmetic helpers (binary mode)

    /// Add with carry: a + b + carry. Updates `carry`.
    @inline(__always)
    static func adc(_ a: UInt8, _ b: UInt8, _ carry: inout Bool) -> UInt8 {
        let sum = UInt16(a) + UInt16(b) + (carry ? 1 : 0)
        carry = sum > 0xFF
        return UInt8(truncatingIfNeeded: sum)
    }

    /// Add with carry, also returning the signed overflow flag V.
    @inline(__always)
    static func adcV(_ a: UInt8, _ b: UInt8, _ carry: inout Bool) -> (UInt8, overflow: Bool) {
        let r = adc(a, b, &carry)
        return (r, (a ^ r) & (b ^ r) & 0x80 != 0)
    }

    /// Subtract with borrow: a − b − (1 − carry). Updates `carry` (set = no borrow).
    @inline(__always)
    static func sbc(_ a: UInt8, _ b: UInt8, _ carry: inout Bool) -> UInt8 {
        let difference = Int(a) - Int(b) - (carry ? 0 : 1)
        carry = difference >= 0
        return UInt8(truncatingIfNeeded: difference)
    }

    /// Subtract with borrow, also returning the signed overflow flag V.
    @inline(__always)
    static func sbcV(_ a: UInt8, _ b: UInt8, _ carry: inout Bool) -> (UInt8, overflow: Bool) {
        let r = sbc(a, b, &carry)
        return (r, (a ^ b) & (a ^ r) & 0x80 != 0)
    }

    /// True when bit 7 is set (the N flag of a value).
    @inline(__always)
    static func negative(_ v: UInt8) -> Bool { v & 0x80 != 0 }
}
