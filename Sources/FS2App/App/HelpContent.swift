import C64Kit
import FS2Host

/// The text of Help ▸ Flight Simulator II Help: a short guide to the game and the Mac app. Key
/// names that differ between the Mac and the C64 come from `KeyMapper` (through
/// `KeyReference.macName`), so the help always names the key that actually does the job; the
/// full table is the Keyboard Reference (⌘/). README.md has the long version.
enum HelpContent {
    static let title = "Flight Simulator II Help"

    struct Topic: Sendable, Equatable {
        var title: String
        /// Paragraphs; one that starts with "• " is a bullet.
        var paragraphs: [String]
    }

    static func topics() -> [Topic] {
        let colon = KeyReference.macName(for: .colon)        // '
        let plus = KeyReference.macName(for: .plus)          // =
        let runStop = KeyReference.macName(for: .runStop)    // Esc
        let home = KeyReference.macName(for: .clrHome)       // Home
        let delete = KeyReference.macName(for: .instDel)     // Delete
        return [
            Topic(title: "Getting started", paragraphs: [
                "This app is a native Mac port of SubLogic's Flight Simulator II for the Commodore 64 "
                    + "(version 1.0, NTSC, 1984), translated from the original program. It is an unofficial "
                    + "port, not affiliated with or endorsed by the rights holders. The game itself is not "
                    + "included: on first launch, choose your own disk image of it (a .d64 file). The app checks "
                    + "it and keeps a copy in ~/Library/Application Support/FS2/.",
                "At the title, answer WHAT DISPLAY ARE YOU USING? with A (color) or B (black and white), then "
                    + "SELECT OPERATING MODE with A (the demo, which flies itself until you press a key) or B "
                    + "(regular flight). Regular flight starts on runway 36 at Meigs Field, Chicago.",
                "Machine ▸ Demo Mode starts the demo while you fly, as A at that prompt does: the program "
                    + "picks it up at its next demo check and loads the demo's takeoff from Meigs, within about "
                    + "20 seconds. Press any key to take over.",
            ]),
            Topic(title: "Flying", paragraphs: [
                "Each key press moves a control one step. Hold a key to repeat it; as on the C64, only the "
                    + "first two keys held repeat.",
                "• Throttle: ; up, \(colon) down (also Page Up and Page Down). / first makes the next throttle "
                    + "key go straight to full or idle.",
                "• Elevator: T nose down, B nose up. Ailerons: F left, H right. Rudder: C left, M right. "
                    + "G centers the ailerons and rudder.",
                "• Flaps: N down, Y up. Trim: R nose down, V nose up. Space: brakes on the ground.",
                "• To take off: full throttle, let the airspeed build, then press B a few times.",
                "• P or \(runStop) pauses the game (the next key resumes); ⌘P pauses the whole machine, "
                    + "sound included.",
            ]),
            Topic(title: "Views and radar", paragraphs: [
                "Press 5, then a key around G to look that way: T ahead, Y front right, H right, N back right, "
                    + "B back, V back left, F left, R front left, G down.",
                "4 shows the radar, a map from above: , zooms out, . zooms in, and 5 goes back to the window.",
            ]),
            Topic(title: "Radios and switches", paragraphs: [
                "Select an item, then , and . lower or raise it. Press the select key again quickly for the "
                    + "next part (the kHz, the next digit).",
                "• Control-C: COM. Control-N: NAV (then 1 or 2 for NAV 1 or NAV 2). Control-V: OBS (then 1 "
                    + "or 2). Control-X: transponder. A: ADF (turn on ADF ENABLE in the editor first). "
                    + "Control-F: fuel tank.",
                "• Return, then 1 to 5: magnetos OFF, R, L, BOTH, START. Return, then , or .: mixture.",
                "• L: lights. Control-I: carburetor heat. Control-B: recalibrate the altimeter. Control-D: "
                    + "realign the heading indicator with the compass. Control-E: the scenery databases.",
                "Hold Control, then press the letter: the app gives CTRL the head start the C64 needs.",
            ]),
            Topic(title: "Modes and the editor", paragraphs: [
                "E (or \(home)) opens the editor: two pages of settings. Return goes to the next line, - to "
                    + "the previous one. Type a number to change a line; \(delete) removes the last digit; E "
                    + "leaves the editor.",
                "• USER MODE: 0 to 9 are the built-in modes, 10 to 24 your own. Typing 110 to 124 there "
                    + "saves the current situation as mode 10 to 24.",
                "• S saves the situation as a user mode; + (the \(plus) key) recalls the current mode, "
                    + "in flight and in the editor.",
                "• User modes live in memory, as on the C64. Control-Z in the editor saves them all to "
                    + "ModeLibrary.bin in ~/Library/Application Support/FS2/ (the previous file is kept as "
                    + "ModeLibrary.bak); Control-X in the editor loads them back. File ▸ Import Mode Library "
                    + "and Export Mode Library copy that file.",
                "• SLEW, REALITY MODE, EUROPE 1917, the time, the season, the clouds and the winds are set "
                    + "here too.",
            ]),
            Topic(title: "Slew mode", paragraphs: [
                "With SLEW set to 1 in the editor the aircraft moves freely: T and B north and south, H and F "
                    + "east and west, ; and \(colon) up and down, 9 and 8 pitch, R and Y bank, V and N heading. "
                    + "G stops all motion, Z zeroes the attitude, Control-T copies the view angles back.",
            ]),
            Topic(title: "Europe 1917", paragraphs: [
                "Set EUROPE 1917 to 1 in the editor for the World War I game. W declares war; Space fires the "
                    + "guns in the air; X drops a bomb; 5 then G shows the bombsight. Leaving mode 7 restarts "
                    + "the program.",
            ]),
            Topic(title: "Course plotter and database", paragraphs: [
                "Q opens the course plotter: A records your track, C records it more precisely, B shows the "
                    + "plot, D stops recording, E returns to flight. Control-E lists the scenery databases.",
            ]),
            Topic(title: "The Mac app", paragraphs: [
                "• View: zoom 2× to 6× (⌘2 to ⌘6) or Fit Window (⌘0), full screen (⌃⌘F), NTSC TV or "
                    + "square pixels, Authentic or Smooth pacing, color or black-and-white monitor.",
                "• Pacing: Authentic shows each new window picture when the C64 finished it, about once a "
                    + "second, as on the original. Smooth redraws the window every frame (about 60 a second) "
                    + "between the last two pictures. The simulation is the same in both.",
                "• Settings (⌘,): the keypad as joysticks, strict joystick, game controllers, sound and "
                    + "volume.",
                "• Machine: Pause (⌘P); Restart (⌘R) presses RUN/STOP + RESTORE, which reloads the program "
                    + "at the original disk speed (about 73 seconds) and returns to the title; Reset (⇧⌘R) is "
                    + "a cold start without that wait; Demo Mode starts the demo (in flight; any key takes "
                    + "over); Keyboard Reference (⌘/).",
                "• Help: this help (⌥⌘/) and the Keyboard Reference. ⌘? opens the Help menu's search, as in "
                    + "every Mac app.",
                "• File: import a disk image (⌘O), an optional C64 character ROM for the editor's text "
                    + "screens, and the mode library.",
            ]),
        ]
    }

    /// The whole help as plain text.
    static func plainText() -> String {
        ([title] + topics().map { t in ([t.title] + t.paragraphs).joined(separator: "\n") })
            .joined(separator: "\n\n")
    }
}
