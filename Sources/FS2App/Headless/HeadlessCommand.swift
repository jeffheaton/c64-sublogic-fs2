import C64Kit
import FS2Core
import FS2Data
import Foundation

/// `FS2 --headless`: runs the engine without a window, as fast as possible, plays a session and
/// writes screenshots. This is how the port is compared with the lab frame for frame.
///
///     FS2 --headless [--engine native|lab] --session <file|@file|steps> [--screenshot-dir <dir>]
///                    [--d64 <path>] [--charrom <path>] [--scale WxH] [--quick-boot]
///                    [--smooth] [--strict-joystick] [--mode-library <path>]
enum HeadlessCommand {
    struct Options: Equatable {
        var engine: String?
        var session: String?
        var screenshotDirectory: String?
        var d64: String?
        var charROM: String?
        var scaleX = 3
        var scaleY = 4
        /// Run through the boot's disk loading to the title prompt without delivering frames.
        var quickBoot = false
        /// Smooth pacing (native engine).
        var smooth = false
        /// The original's joystick arbitration (native engine; the lab always has it).
        var strictJoystick = false
        /// The mode library file CTRL-X / CTRL-Z use (native engine). Without it a headless run
        /// keeps its library in memory and never touches the app's `ModeLibrary.bin`.
        var modeLibrary: String?

        var engineOptions: EngineOptions {
            EngineOptions(pacing: smooth ? .smooth : .authentic, strictJoystick: strictJoystick)
        }
    }

    enum UsageError: Error, CustomStringConvertible {
        case missingValue(String)
        case unknownOption(String)
        case badScale(String)
        case missingSession
        case noDisk

        var description: String {
            switch self {
            case .missingValue(let o): return "option \(o) needs a value"
            case .unknownOption(let o): return "unknown option \(o)"
            case .badScale(let s): return "bad --scale '\(s)' (expected e.g. 3x4)"
            case .missingSession: return "--session is required"
            case .noDisk: return "no disk image: pass --d64, set FS2_D64 or import one in the app"
            }
        }
    }

    static let usage = """
        usage: FS2 --headless [--engine native|lab] --session <file|@file|steps> [--screenshot-dir <dir>]
                              [--d64 <path>] [--charrom <path>] [--scale WxH] [--quick-boot]
                              [--smooth] [--strict-joystick] [--mode-library <path>]
          Plays a session (re/sessions/*.txt syntax: wait:N key:NAME:N joy1:up+fire:N down:NAME
          up:NAME nmi shot:NAME poke:ADDR:VAL snap:NAME pc:ADDR:MAX until:ADDR:VAL:MAX
          peek:ADDR:N text; the native engine stops only at pc:2250, the key wait, and pc:204B,
          the top of the main loop; the lab's cov: and watch: steps are skipped) as fast as
          possible and writes each shot as <dir>/<NAME>.png (scaled 3x4 by default, like fs2lab
          run). The native engine is the default (FS2_ENGINE=lab for the lab, in development
          builds only).
          --quick-boot first runs to the title prompt without producing the loading frames.
          --smooth, --strict-joystick: the engine options (native engine).
          --mode-library: the file CTRL-X/CTRL-Z read and write (default: kept in memory).
        """

    static func parse(_ arguments: [String]) throws -> Options {
        var o = Options()
        var i = 0
        func value(_ name: String) throws -> String {
            i += 1
            guard i < arguments.count else { throw UsageError.missingValue(name) }
            return arguments[i]
        }
        while i < arguments.count {
            let a = arguments[i]
            switch a {
            case "--headless": break
            case "--quick-boot": o.quickBoot = true
            case "--smooth": o.smooth = true
            case "--strict-joystick": o.strictJoystick = true
            case "--engine": o.engine = try value(a)
            case "--session": o.session = try value(a)
            case "--screenshot-dir", "--screenshots": o.screenshotDirectory = try value(a)
            case "--d64": o.d64 = try value(a)
            case "--charrom": o.charROM = try value(a)
            case "--mode-library": o.modeLibrary = try value(a)
            case "--scale":
                let s = try value(a)
                let parts = s.lowercased().split(separator: "x").compactMap { Int($0) }
                guard parts.count == 2, (1...16).contains(parts[0]), (1...16).contains(parts[1]) else {
                    throw UsageError.badScale(s)
                }
                o.scaleX = parts[0]; o.scaleY = parts[1]
            default: throw UsageError.unknownOption(a)
            }
            i += 1
        }
        guard o.session != nil else { throw UsageError.missingSession }
        return o
    }

    /// Session text from an argument: `@path`, an existing file path, or the steps themselves.
    static func sessionText(_ argument: String) throws -> String {
        if argument.hasPrefix("@") {
            return try String(contentsOfFile: String(argument.dropFirst()), encoding: .utf8)
        }
        if FileManager.default.fileExists(atPath: argument) {
            return try String(contentsOfFile: argument, encoding: .utf8)
        }
        return argument
    }

    /// The mode library of a headless run: the given file, else a library kept in memory.
    static func modeLibrary(_ o: Options) -> ModeLibrary.IO {
        if let path = o.modeLibrary {
            return ModeLibraryFile(url: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)).io
        }
        return ModeLibrary.InMemoryStore().io
    }

    /// Runs a headless session; returns the runner (frames seen, screenshots written).
    @discardableResult
    static func run(_ o: Options, data: GameData? = nil) throws -> HeadlessRunner {
        let kind = try EngineFactory.resolve(requested: o.engine)
        let gameData: GameData
        if let data {
            gameData = data
        } else {
            guard let url = GameLibrary.locateDisk(explicit: o.d64) else { throw UsageError.noDisk }
            let rom = o.charROM.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? (GameLibrary.hasCharROM ? GameLibrary.charROMURL : nil)
            gameData = try GameData(d64URL: url, charROMURL: rom)
        }
        let session = try Session.parse(try sessionText(o.session ?? ""))
        var directory: URL?
        if let d = o.screenshotDirectory {
            let url = URL(fileURLWithPath: (d as NSString).expandingTildeInPath, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            directory = url
        }
        let engine = try EngineFactory.make(kind, data: gameData, options: o.engineOptions,
                                            modeLibrary: modeLibrary(o))
        let runner = HeadlessRunner(engine: engine)
        runner.scaleX = o.scaleX
        runner.scaleY = o.scaleY
        if o.quickBoot { try runner.quickBoot() }
        try runner.play(session, screenshots: directory)
        return runner
    }

    /// Entry point from main.swift; returns the process exit status.
    static func main(_ arguments: [String]) -> Int32 {
        let options: Options
        do {
            options = try parse(arguments)
        } catch {
            FileHandle.standardError.write(Data("FS2: \(error)\n\(usage)\n".utf8))
            return 2
        }
        let start = Date()
        do {
            let runner = try run(options)
            for url in runner.screenshots { print("wrote \(url.path)") }
            if runner.skippedSteps > 0 { print("skipped \(runner.skippedSteps) cov:/watch: steps (lab only)") }
            let frames = runner.engine.cycles / VirtualClock.cyclesPerFrame
            let engine = (try? EngineFactory.resolve(requested: options.engine).rawValue) ?? "?"
            print(String(format: "ran %llu frames (%.1f s emulated) in %.2f s", frames,
                         Double(frames) / VirtualClock.framesPerSecond, Date().timeIntervalSince(start))
                  + " with the \(engine) engine")
            return 0
        } catch {
            FileHandle.standardError.write(Data("FS2: \(error)\n".utf8))
            return 1
        }
    }
}
