import Foundation

/// The words of the first-run import flow and of its error alerts (`AppDelegate` shows them).
enum FirstRun {
    static let welcomeTitle = "Welcome to Flight Simulator II"

    static let welcomeText = """
        This is a native Mac port of SubLogic's Flight Simulator II for the Commodore 64. It is an \
        unofficial port, not affiliated with or endorsed by the rights holders. The game itself is \
        not included: to play, choose your own disk image of Flight Simulator II version 1.0 (NTSC, \
        1984). It is a .d64 file, usually 174,848 bytes.

        The app checks that the image is a complete copy of version 1.0, then keeps a copy in \
        ~/Library/Application Support/FS2/, so you only do this once. Nothing is sent anywhere.

        Optional: File ▸ Import Character ROM… adds the C64's own character set (a 4096-byte \
        “chargen” file) for the editor's text screens.
        """

    static let chooseButton = "Choose Disk Image…"
    static let quitButton = "Quit"

    static let panelTitle = "Choose Your Flight Simulator II Disk Image"
    static let panelMessage = "Choose the .d64 image of your Flight Simulator II disk: version 1.0 for the "
        + "Commodore 64 (NTSC)."
    static let panelPrompt = "Import"

    /// The alert title when a chosen image fails a check.
    static let importFailedTitle = "This disk image can't be used"
    /// The alert title when the imported copy fails its check at launch.
    static let importedCopyFailedTitle = "The imported copy of your disk image can no longer be used"
    static let importedCopyAdvice = "Choose your disk image again to import a fresh copy."

    /// The text under an error alert's title: what went wrong, the disk checks marked passed (✓),
    /// failed (✗) or not reached (–) for a disk error, and what to do next (`advice`, or the
    /// error's own suggestion).
    static func errorDetails(_ error: Error, advice: String? = nil) -> String {
        let e = error as? LocalizedError
        let checklist = (error as? GameLibrary.ImportError)?.checklist
        return [e?.errorDescription ?? String(describing: error), checklist, advice ?? e?.recoverySuggestion]
            .compactMap { $0 }.joined(separator: "\n\n")
    }
}
