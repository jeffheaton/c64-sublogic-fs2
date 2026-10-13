import AppKit
import FS2Host
import Foundation

/// Entry point. `--headless` runs a session without any window (see `HeadlessCommand`);
/// `--key-reference` prints the controls tables of README.md (`KeyReference.markdown()`) and
/// `--version` the About text; otherwise this starts the Mac app. `--engine lab|native` (or
/// `FS2_ENGINE`) picks the engine (the lab only in development builds: see `EngineKind.lab`).
@MainActor
func runFS2() -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.contains("--headless") {
        return HeadlessCommand.main(arguments)
    }
    if arguments.contains("--key-reference") {
        print(KeyReference.markdown())
        return 0
    }
    if arguments.contains("--version") {
        print(AboutInfo.plainText())
        return 0
    }
    var engine: String?
    if let i = arguments.firstIndex(of: "--engine"), i + 1 < arguments.count { engine = arguments[i + 1] }
    let app = NSApplication.shared
    let delegate = AppDelegate(requestedEngine: engine)
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
    return 0
}

exit(runFS2())
