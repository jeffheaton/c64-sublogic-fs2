import Foundation
import FS2Core
import FS2LabKit
import Testing

/// Deterministic replays: sessions recorded in the lab (`ReplayRecorder`), replayed in the port
/// from the same start state through the main loop, the interrupt equivalents and the 10 Hz tick.
/// Every top of the main loop ($204B) must have identical memory (stack page aside), the VIC/SID
/// registers, color RAM and the split states must match, and the golden frames must be identical.
/// The session scripts are `re/sessions/replay-*.txt`; each test also checks that the session did
/// what it is about (the port's state after its last checkpoint).
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"))
struct ReplayTests {
    @discardableResult
    static func run(_ name: String, prefix: String? = ReplaySessions.meigs, frames: Int = 1,
                    minCheckpoints: Int = 5, sourceLocation: SourceLocation = #_sourceLocation,
                    observe: ((Int, Machine) -> Void)? = nil) throws -> Machine {
        let session = try ReplaySessions.text("replay-\(name)")
        let recording = try ReplayLab.record(name, prefix: prefix, session: session)
        let machine = ReplayLab.portMachine(recording)
        let report = ReplayLab.replay(recording, on: machine, from: .mainLoop, frames: frames, observe: observe)
        ReplayLab.expectClean(recording, report, minCheckpoints: minCheckpoints, sourceLocation: sourceLocation)
        return machine
    }

    /// Regular flight sitting at Meigs for two minutes: the clock, the engine, the 1 Hz sound
    /// ticks, the instrument phases.
    @Test func idleAtMeigs() throws {
        let m = try Self.run("idle", frames: 4, minCheckpoints: 60)
        #expect(m.mem[0x0A12] != 0, "still on the ground")
    }

    /// Full throttle, rotation, climb, trim, the '/' throttle jump, a turn with the ailerons.
    @Test func takeoffAndClimb() throws {
        let m = try Self.run("takeoff", frames: 4)
        #expect(m.mem[0x0A12] == 0, "airborne")
        #expect(m.mem[0x0AC9] >= 0x70, "full throttle again after the '/' jumps")
    }

    /// The demo: the 1-in-8 demo check asks the editor overlay for mode 2 (the ported editor
    /// loads it), which flies itself.
    @Test func demoMode() throws {
        let m = try Self.run("demo", prefix: "pc:2250:9000 key:A:12 pc:2250:600 key:A:12", frames: 4)
        #expect(m.mem[MainLoop.RAM.currentMode] == 2, "mode 2 loaded")
        #expect(m.mem[0x095A] == 1, "the demo is running")
    }

    /// All nine views and the radar view with its zoom.
    @Test func viewsAndRadar() throws {
        let m = try Self.run("views", frames: 2)
        #expect(m.mem[0x0836] == 0, "radar off again")
    }

    /// COM tuned to the Meigs ATIS (the teletype types the broadcast), NAV1/NAV2, OBS, the
    /// transponder and the ADF.
    @Test func radiosAndAtis() throws {
        let m = try Self.run("radios", frames: 4)
        let com = String(format: "1%02X.%02X", m.mem[0x08B4], m.mem[0x08B3])
        #expect(m.u16(0x08B3) == 0x2130, "COM 121.30, not \(com)")
        #expect(m.mem[0x0941] == 1, "the ATIS was typed")
    }

    /// A dive into the ground: the crash, the message and its delay, the mode reload through the
    /// editor overlay (ported), the flight overlay and the area streamed in again.
    @Test func crash() throws {
        let m = try Self.run("crash", frames: 4)
        #expect(m.mem[MainLoop.RAM.crashCode] == 0 && m.mem[MainLoop.RAM.modeRequest] == 0, "the crash was handled")
        #expect(m.mem[MainLoop.RAM.editorCacheState] == 1, "the editor overlay was loaded and cached")
        #expect(m.u16(0xA7E0) == 0xA800 && m.mem[0x0901] == 0x4E, "flight overlay, area and detail back")
    }

    /// Slewing from Chicago into the Champaign area: the root list's box test and the area's
    /// blocks streamed in (the loader's memory effects).
    @Test func sceneryAreaCrossing() throws {
        // After the Meigs prefix: slew mode, the eye just north of the Chicago / Champaign
        // boundary (north high word $0235), settled, at the top of the main loop.
        let prefix = ReplaySessions.meigs + "\npoke:0966:01 poke:62:00 poke:63:40 poke:64:35 poke:65:02 wait:300 pc:204B:3000"
        let m = try Self.run("crossing", prefix: prefix, frames: 4)
        #expect(m.mem[0x0900] == 0x34, "the Champaign area (block 52) is in slot 0")
    }

    /// P pauses (the 5 Hz and 1 Hz work stop, the key wait polls), any key resumes; RUN/STOP
    /// pauses the same way.
    @Test func pause() throws {
        let m = try Self.run("pause", frames: 4)
        #expect(m.mem[MainLoop.RAM.pauseCount] == 0, "resumed")
    }
}
