import C64Kit
import Foundation
import FS2Core
@testable import FS2Host
import Testing

/// What the web build adds to the shared host: the browser's key codes, the reference's web labels
/// and JSON, the input merge, and `SessionDriver`'s handling of the boot, the pause and a stopped engine.
struct WebHostTests {
    // MARK: Key codes

    @Test func everyKeyRoundTripsThroughItsWebCode() {
        var seen: Set<String> = []
        for key in MacKeyCode.allCases {
            #expect(MacKeyCode(webCode: key.webCode) == key, "\(key) → \(key.webCode)")
            #expect(seen.insert(key.webCode).inserted, "\(key.webCode) names two keys")
        }
        #expect(MacKeyCode(webCode: "KeyA") == .a && MacKeyCode(webCode: "Numpad5") == .keypad5)
        #expect(MacKeyCode(webCode: "Backspace") == .delete && MacKeyCode(webCode: "Delete") == .forwardDelete)
        #expect(MacKeyCode(webCode: "Insert") == .help && MacKeyCode(webCode: "NumLock") == .keypadClear)
        #expect(MacKeyCode(webCode: "AltLeft") == .option && MacKeyCode(webCode: "IntlBackslash") == .isoSection)
        #expect(MacKeyCode(webCode: "Lang1") == nil)
    }

    /// The table the page translates key events with covers every bound key, once.
    @Test func webCodeTableCoversEveryBinding() throws {
        var table: [String: UInt16] = [:]
        for line in MacKeyCode.webCodeTable.split(separator: "\n") {
            let parts = line.split(separator: "=")
            try #require(parts.count == 2, "line \(line)")
            #expect(table.updateValue(UInt16(parts[1])!, forKey: String(parts[0])) == nil, "\(parts[0]) twice")
        }
        for b in KeyMapper.bindings {
            #expect(table[b.mac.webCode] == b.mac.rawValue, "\(b.mac) is missing from the table")
        }
        #expect(table.count == Set(KeyMapper.bindings.map(\.mac)).count)
    }

    // MARK: The reference for the web

    @Test func webLabelsNameNoMacOnlyKeys() {
        let macOnly = ["Option", "Command", "Return", "fn ", "(fn", "Help", "Control-", "Clear", "Forward Delete"]
        for section in KeyReference.sections(style: .web) {
            for row in section.rows {
                for word in macOnly {
                    #expect(!row.mac.contains(word), "\(section.title): \(row.mac)")
                }
            }
        }
        #expect(!KeyReference.json(style: .web).contains("Mac"), "the web reference never says Mac")
        let titles = KeyReference.sections(style: .web).map(\.title)
        #expect(titles.contains(KeyReference.SectionTitle.page) && !titles.contains(KeyReference.SectionTitle.machine))
        #expect(!titles.contains(KeyReference.SectionTitle.gamepad), "the web build has no game controller yet")
        #expect(KeyReference.keyName(for: .runStop, style: .web) == "Esc")
        #expect(KeyReference.keyName(for: .instDel, style: .web) == "Backspace")
        #expect(KeyReference.controlSection(style: .web).rows.allSatisfy { $0.mac.hasPrefix("Ctrl+") })
    }

    /// The Mac's reference is what it was: the default style is `.mac`.
    @Test func macReferenceIsTheDefault() {
        #expect(KeyReference.sections() == KeyReference.sections(style: .mac))
        #expect(KeyReference.markdown() == KeyReference.markdown(style: .mac))
        #expect(KeyReference.macName(for: .clrHome) == "Home")
    }

    @Test func webMarkdownIsWellFormed() {
        let md = KeyReference.markdown(style: .web)
        #expect(md.hasPrefix(KeyReference.markdownBegin) && md.hasSuffix(KeyReference.markdownEnd))
        #expect(md.contains("| Key | Commodore 64 | In Flight Simulator II |"))
        #expect(!md.contains("| Mac |"))
        for line in md.split(separator: "\n") where line.hasPrefix("|") {
            // Three columns: four unescaped pipes.
            var pipes = 0, escaped = false
            for ch in line {
                if ch == "|" && !escaped { pipes += 1 }
                escaped = ch == "\\" && !escaped
            }
            #expect(pipes == 4, "\(line)")
        }
    }

    @Test func referenceJSONParses() throws {
        let data = Data(KeyReference.json(style: .web).utf8)
        let parsed = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let sections = KeyReference.sections(style: .web)
        #expect(parsed.count == sections.count)
        for (p, s) in zip(parsed, sections) {
            #expect(p["title"] as? String == s.title)
            let rows = try #require(p["rows"] as? [[String]])
            #expect(rows == s.rows.map { [$0.mac, $0.c64, $0.function] })
        }
        #expect(KeyReference.jsonString("a\"b\\c\n\u{1}") == #""a\"b\\c\n\u0001""#)
    }

    // MARK: Input

    @Test func inputMergesKeysPadAndGamepad() {
        let keyboard = KeyboardState(held: [.a, .keypad8, .keypad4, .keypad6, .command])
        #expect(keyboard.held == [.a, .keypad8, .keypad4, .keypad6], "unbound keys are left out")
        let joystick = InputState(keyboard: keyboard, keypadJoystick: true)
        #expect(joystick.keys.isPressed(.a))
        #expect(joystick.keys.joystick1 == [.up], "left and right cancel")
        let keypad = InputState(keyboard: keyboard, keypadJoystick: false)
        #expect(keypad.keys.joystick1 == [] && keypad.keys.isPressed(.digit8))
        let pad = InputState(keyboard: KeyboardState(), keypadJoystick: true, gamepad: ([.down, .fire], [.up]))
        #expect(pad.keys.joystick1 == [.down, .fire] && pad.keys.joystick2 == [.up])
    }

    // MARK: The session driver

    /// Keeps time only: a frame every 17,095 cycles.
    final class ClockEngine: GameEngine {
        var cycles: UInt64 = 0
        var input = InputState()
        var onFrame: ((FrameOutput) -> Void)?
        var options = EngineOptions()
        var stuck = false
        var skips = 0

        func run(untilCycle cycle: UInt64) {
            guard !stuck else { return }
            let cpf = VirtualClock.cyclesPerFrame
            while cycles < cycle {
                cycles = min(cycle, (cycles / cpf + 1) * cpf)
                if cycles % cpf == 0 {
                    onFrame?(FrameOutput(pixels: [], frame: cycles / cpf, sidWrites: [], monochrome: false))
                }
            }
        }
    }

    final class Controls {
        var clock: UInt64 = 0
        var requests = HostRequests()
        var reads = 0
        var stopAfter = 1000
        var waits: [UInt64] = []
        var errors: [String] = []
        /// Called with the read's number before the controls are handed over.
        var onRead: (Int) -> Void = { _ in }
        var io: SessionDriver.IO {
            var io = SessionDriver.IO(now: { [unowned self] in clock },
                                      wait: { [unowned self] in waits.append($0); clock += $0 },
                                      readRequests: { [unowned self] in
                                          reads += 1
                                          onRead(reads)
                                          return reads > stopAfter ? nil : requests
                                      })
            io.error = { [unowned self] in errors.append($0) }
            return io
        }
    }

    static func drive(_ engine: ClockEngine, _ driver: SessionDriver, after first: InlineRequest? = nil,
                      calls: Int) -> [InlineRequest] {
        var previous = first, made: [InlineRequest] = []
        for _ in 0..<calls {
            guard let request = driver.next(after: previous) else { break }
            switch request {
            case .run(let cycle): engine.run(untilCycle: cycle)
            case .skipDiskLoading: engine.skips += 1
            case .runToKeyWait: break
            }
            made.append(request)
            previous = request
        }
        return made
    }

    @Test func driverBootsThenRunsFrameByFrame() {
        let engine = ClockEngine(), controls = Controls()
        var frames = 0
        let driver = SessionDriver(engine: engine, audio: nil, options: EngineOptions(pacing: .smooth),
                                   io: controls.io) { _ in frames += 1 }
        #expect(driver.next(after: nil) == .skipDiskLoading)
        #expect(engine.options.pacing == .smooth, "the boot runs with the options given")
        var made: [InlineRequest] = [.skipDiskLoading]
        made += Self.drive(engine, driver, after: .skipDiskLoading, calls: 4)
        #expect(engine.options.pacing == .authentic, "then the controls' options")
        let cpf = VirtualClock.cyclesPerFrame
        #expect(Array(made.dropFirst()) == (1...4).map { .run(untilCycle: UInt64($0) * cpf) })
        #expect(frames == 4)
        #expect(controls.waits.allSatisfy { $0 > 0 }, "it slept until each frame was due")
    }

    @Test func driverWaitsWhilePausedAndStops() {
        let engine = ClockEngine(), controls = Controls()
        controls.requests.paused = true
        controls.stopAfter = 5
        let driver = SessionDriver(engine: engine, audio: nil, quickBoot: false, options: EngineOptions(),
                                   io: controls.io) { _ in }
        #expect(driver.next(after: nil) == nil, "stopped while paused")
        #expect(controls.waits == Array(repeating: SessionDriver.pausedWait, count: 5))
        #expect(engine.cycles == 0)
    }

    /// An engine that makes no progress is reported, and the driver holds it paused until the
    /// controls show the pause (the page acknowledged it); when the player resumes, it runs again.
    @Test func driverPausesAStoppedEngine() {
        let engine = ClockEngine(), controls = Controls()
        let driver = SessionDriver(engine: engine, audio: nil, quickBoot: false, options: EngineOptions(),
                                   io: controls.io) { _ in }
        let frame = VirtualClock.cyclesPerFrame
        let first = driver.next(after: nil)
        #expect(first == .run(untilCycle: frame))
        engine.stuck = true
        engine.run(untilCycle: frame)
        engine.stuck = false
        let start = controls.reads, waitsBefore = controls.waits.count
        controls.onRead = { n in
            if n == start + 3 { controls.requests.paused = true }    // the page shows the pause
            if n == start + 5 { controls.requests.paused = false }   // the player resumes
        }
        let next = driver.next(after: first)
        #expect(controls.errors.count == 1 && controls.errors[0].contains("stopped at cycle 0"))
        #expect(next == .run(untilCycle: frame), "running again after the resume")
        #expect(controls.reads >= start + 5)
        #expect(controls.waits[waitsBefore..<(waitsBefore + 4)].allSatisfy { $0 == SessionDriver.pausedWait },
                "held paused, then paused by the page")
    }
}
