import FS2Core
import FS2Data
import Foundation
#if Lab
import FS2LabKit
#endif

/// Which implementation of `GameEngine` drives the app.
enum EngineKind: String, CaseIterable, Sendable {
    /// The native port (FS2Core).
    case native
    /// The development lab running SubLogic's original program (FS2LabKit). Only development
    /// builds have it: the package trait `Lab` (on by default, so `swift build`, `swift test` and
    /// `swift run` include it) links the lab into the app; `make app` builds the shipped app
    /// without it.
    case lab

    /// Whether this build of the app contains the engine.
    var isAvailable: Bool {
        switch self {
        case .native: return true
        case .lab:
            #if Lab
            return true
            #else
            return false
            #endif
        }
    }
}

/// Picks and builds the engine: the native port by default. `FS2_ENGINE=lab` (or `--engine lab`)
/// selects the lab in development builds, for side-by-side comparison with the port.
enum EngineFactory {
    enum Error: Swift.Error, CustomStringConvertible {
        case unknownEngine(String)
        /// The engine exists but is not part of this build (the lab in the shipped app).
        case unavailable(EngineKind)

        var description: String {
            switch self {
            case .unknownEngine(let s):
                let names = EngineKind.allCases.filter(\.isAvailable).map(\.rawValue)
                return "unknown engine '\(s)' (expected one of: \(names.joined(separator: ", ")))"
            case .unavailable(let kind):
                return "the \(kind.rawValue) engine is a development tool and is not part of this build "
                    + "(build with the package's default traits, e.g. `swift build`, to include it)"
            }
        }
    }

    /// Resolves the engine from an explicit request (command line), then `FS2_ENGINE`, then the default.
    static func resolve(requested: String?, environment: [String: String] = ProcessInfo.processInfo.environment)
        throws -> EngineKind {
        if let name = requested ?? environment["FS2_ENGINE"], !name.isEmpty {
            guard let kind = EngineKind(rawValue: name.lowercased()) else { throw Error.unknownEngine(name) }
            guard kind.isAvailable else { throw Error.unavailable(kind) }
            return kind
        }
        return .native
    }

    /// Builds an engine of `kind` for `data`. Call this on the thread that will run it. The native
    /// engine keeps the mode library in `modeLibrary` (default: `ModeLibrary.bin` in Application
    /// Support; nil: no library disk).
    static func make(_ kind: EngineKind, data: GameData, options: EngineOptions = EngineOptions(),
                     modeLibrary: ModeLibrary.IO? = ModeLibraryFile.standard.io) throws -> any GameEngine {
        switch kind {
        case .native:
            return NativeEngine(data: data, options: options, modeLibrary: modeLibrary)
        case .lab:
            #if Lab
            let engine = LabEngine(data: data)
            engine.options = options
            return engine
            #else
            throw Error.unavailable(kind)
            #endif
        }
    }
}
