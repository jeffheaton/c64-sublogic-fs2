import FS2Core

/// Machine ▸ Demo Mode: what answering A (the demo) at the operating-mode prompt does, from the menu.
///
/// The prompt's A does `INC $095B` (from 0 to 1, `modePromptScreen`). The main loop's demo check
/// ($2133, once every 8 passes) then sets `$08BB` = 3; the editor overlay loads built-in mode 2 (the
/// self-flying takeoff from Meigs) and exits, copying `$095B` to `$095A` (the demo is running) and
/// clearing `$095B` (`re/docs/modes-ui.md`). The menu stores `$095B` = 1, so the same check starts
/// the same demo. It is left the original way: any key clears `$095A` (the dispatcher, $27DD) and
/// the controls are the player's again; a crash then reloads mode 2 with `$095A` still 0.
///
/// The request is taken only in the state the prompt's answer leads to, flying in the main loop:
/// - the flight overlay is resident (`$A7E0` holds its end word $A800): not at the title and
///   prompts (answer A there), the editor or the database screen;
/// - not Europe 1917 (`$0E7C` = 0): loading mode 2 there would leave mode 7, which restarts the
///   program (the war-exit check);
/// - no editor visit, mode request or key wait under way (`$08BA` = `$08BB` = 0): the editor's exit
///   would clear `$095B` before the check saw it, and a key wait (the pause, the plotter menu) is
///   the player's to end first;
/// - the demo neither runs nor is requested (`$095A` = `$095B` = 0): the prompt's A is answered
///   once, from regular flight's state. Asking again while the demo runs would reload mode 2 and
///   start it over, which the original never does; the menu item stays checked (`running`) until a
///   key ends the demo.
enum DemoMode {
    /// `$A7E0`'s word while the flight overlay is resident (its end address).
    static let flightOverlay: UInt16 = 0xA800
    /// `$095A`: the demo is running (any key clears it).
    static let demoActive = 0x095A

    struct Status: Sendable, Equatable {
        /// The menu item may start the demo now.
        var available = false
        /// The demo runs (`$095A`) or is about to (`$095B`).
        var running = false

        var rawValue: UInt8 { (available ? 1 : 0) | (running ? 2 : 0) }
        init(available: Bool = false, running: Bool = false) {
            self.available = available
            self.running = running
        }
        init(rawValue: UInt8) {
            available = rawValue & 1 != 0
            running = rawValue & 2 != 0
        }
    }

    /// The demo's state in memory read through `peek`.
    static func status(peek: (Int) -> UInt8) -> Status {
        let overlay = UInt16(peek(0xA7E0)) | UInt16(peek(0xA7E1)) << 8
        let flying = overlay == flightOverlay && peek(MainLoop.RAM.warModeLatch) == 0
            && peek(MainLoop.RAM.editorRequest) == 0 && peek(MainLoop.RAM.modeRequest) == 0
        let running = peek(demoActive) != 0 || peek(MainLoop.RAM.demoRequest) != 0
        return Status(available: flying && !running, running: running)
    }

    /// The demo's state in `engine` (call it on the engine's thread, between runs). An engine
    /// without memory access (a test double) never offers the demo.
    static func status(of engine: any GameEngine) -> Status {
        guard let debug = engine as? EngineDebugging else { return Status() }
        return status(peek: debug.peek)
    }

    /// Starts the demo as the prompt's A does: `$095B` = 1, when the state allows it (`status`).
    /// Returns whether it did. Call it on the engine's thread, between runs.
    @discardableResult
    static func start(on engine: any GameEngine) -> Bool {
        guard let debug = engine as? EngineDebugging, status(peek: debug.peek).available else { return false }
        debug.poke(MainLoop.RAM.demoRequest, 1)
        return true
    }
}
