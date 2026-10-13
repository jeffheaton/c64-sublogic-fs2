import Foundation
import FS2Core
import FS2LabKit
import Testing

/// More replays (see `ReplayTests`): the main-loop paths the flight sessions do not reach. The
/// alternate-pass tasks that load an overlay or wait for keys (the database info screen, the
/// course plotter), the war-exit cold restart taken from the main loop, the editor taken from its
/// cache and swapped back out, the joysticks, reality-mode failures, and the time-of-day switches
/// of the window border operand `$22B5`. Each test also checks, at the checkpoints, that the
/// session really went through the path it is about.
///
/// War mode is replayed by `NativeEngineReplayTests.europe1917` (the editor opened by key, the war
/// overlay's passes and its enemies' polls) and by the replay matrix; `MainLoopTests` checks whole
/// war passes against the full lab machine.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"))
struct ReplayModesTests {
    typealias R = MainLoop.RAM

    /// The overlay resident at $A7E0 (its end word).
    static func overlay(_ m: Machine) -> UInt16 { m.u16(0xA7E0) }

    /// CTRL+E: the database info screen through slot $A7FA (overlay 4), SPACE, the flight overlay
    /// and the area back.
    @Test func databaseInfo() throws {
        var overlays: Set<UInt16> = []
        let m = try ReplayTests.run("database", frames: 2) { _, m in overlays.insert(Self.overlay(m)) }
        #expect(overlays.count >= 2, "overlay 4 was resident at a checkpoint: \(overlays.map { hex16(Int($0)) })")
        #expect(m.mem[R.databaseInfoRequest] == 0)
        #expect(Self.overlay(m) == 0xA800 && m.mem[0x0901] == 0x4E, "flight overlay, area and detail back")
    }

    /// Q: the course plotter menu ($F627 from the alternate-pass tasks, key waits): a normal
    /// recording during the take-off, the plot displayed, then off (D, which also marks the
    /// editor cache empty).
    @Test func coursePlotter() throws {
        var modes: Set<UInt8> = [], cache: Set<UInt8> = []
        let m = try ReplayTests.run("plotter", frames: 4) { _, m in
            modes.insert(m.mem[CoursePlotter.displayMode])
            cache.insert(m.mem[R.editorCacheState])
        }
        #expect(modes.isSuperset(of: [1, 2]), "recording and displaying: \(modes.sorted())")
        #expect(cache.contains(2), "the recording took $D000 from the editor cache: \(cache.sorted())")
        #expect(m.mem[CoursePlotter.displayMode] == 0 && m.mem[R.editorCacheState] == 0, "off again")
    }

    /// Leaving Europe 1917: `$0E7C` = 7 with mode 0 current. The 1-in-8 pass jumps to $A7E2 from
    /// the main loop (`runMainLoop`'s cold restart): overlay 0 reloaded, the init chain, the title
    /// and the prompts, then regular flight.
    @Test func leaveEurope1917() throws {
        var latches: [UInt8] = []
        let prefix = ReplaySessions.meigs + "\npc:204B:3000 poke:0E7C:07"
        let m = try ReplayTests.run("warexit", prefix: prefix, frames: 2, minCheckpoints: 4) { _, m in
            latches.append(m.mem[R.warModeLatch])
        }
        #expect(latches.first == 7, "the recording starts with the latch set")
        #expect(latches.last == 0, "the boot loads cleared it: the restart ran (\(latches))")
        #expect(m.mem[R.currentMode] == 0 && Self.overlay(m) == 0xA800 && m.mem[0x0901] == 0x4E)
    }

    /// The editor overlay's second entry: a second crash's mode reload takes it from the cache
    /// (`$08BC` = 1) and the main loop swaps it back out (the call to $E6DB).
    @Test func secondCrash() throws {
        let crash = try ReplaySessions.text("replay-crash").split(separator: "\n")
            .filter { !$0.hasPrefix("#") && !$0.hasPrefix("cov:") }.joined(separator: "\n")
        let prefix = ReplaySessions.meigs + "\n" + crash + "\npc:204B:3000"
        var cached: [UInt8] = []
        let m = try ReplayTests.run("recrash", prefix: prefix, frames: 4) { _, m in
            cached.append(m.mem[R.editorCacheState])
        }
        #expect(cached.allSatisfy { $0 == 1 }, "the editor stays cached: \(cached)")
        #expect(m.mem[R.crashCode] == 0 && m.mem[R.modeRequest] == 0, "the crash was handled")
        #expect(Self.overlay(m) == 0xA800 && m.mem[0x0901] == 0x4E, "flight overlay, area and detail back")
    }

    /// The joysticks: the IRQ's scan latches them, the 5 Hz tick acts (throttle, elevator,
    /// ailerons with the auto-centering, the fire button's view prefix).
    @Test func joysticks() throws {
        var throttles: Set<UInt8> = [], views: Set<UInt8> = []
        let m = try ReplayTests.run("joystick", frames: 4) { _, m in
            throttles.insert(m.mem[0x0AC9])
            views.insert(m.mem[0x0ACA])
        }
        #expect(throttles.count >= 3, "the throttle moved: \(throttles.sorted())")
        #expect(views.count >= 2 && m.mem[0x0ACA] == 0, "the right view, then the front view again: \(views.sorted())")
    }

    /// Reality mode with reliability 0: the phase-3 failure check fires (its carry from the
    /// oil-pressure gauge), the window message, the failure handlers, the drifts and the trim
    /// creep.
    @Test func realityFailures() throws {
        var first: [UInt8]?, last: [UInt8] = []
        let prefix = ReplaySessions.meigs + "\npc:204B:3000 poke:0967:01 poke:09A4:00 poke:08CD:00"
        let m = try ReplayTests.run("failures", prefix: prefix, frames: 4) { _, m in
            last = (0x0942...0x0944).map { m.mem[$0] } + [m.mem[0x09BF]]
            if first == nil { first = last }
        }
        #expect(first != last, "a failure struck: \(first ?? []) → \(last)")
        #expect(m.mem[0x0967] == 1)
    }

    /// Dusk, then night (19:29:40 by day, season 0): the phase-0 time of day rewrites the border
    /// operand the window-phase IRQ stores; L switches the panel lights off and on in the dark.
    @Test func duskAndNight() throws {
        var states: [UInt8] = [], borders: Set<UInt8> = []
        let prefix = ReplaySessions.meigs + "\npc:204B:3000 poke:0983:13 poke:0984:1D poke:091A:28"
        let m = try ReplayTests.run("dusk", prefix: prefix, frames: 2) { _, m in
            if states.last != m.mem[0x083C] { states.append(m.mem[0x083C]) }
            borders.insert(m.io.viewRegion.border)
        }
        #expect(states == [1, 2, 4], "day, dusk, night: \(states)")
        #expect(borders.isSuperset(of: [0x06, 0x00]), "the dusk and night borders were shown: \(borders.sorted())")
        #expect(m.mem[R.borderOperand] == 0x00)
    }
}
