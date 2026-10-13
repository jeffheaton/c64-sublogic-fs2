import Foundation

/// What Flight Simulator II ▸ About shows: the name, the version, a one-line description and the
/// credit line (who wrote and published the original, and that this port is unofficial). Nothing
/// else (no intro or banner text).
enum AboutInfo {
    static let name = "Flight Simulator II (C64 port)"
    static let summary = "A native Mac port of SubLogic's Flight Simulator II for the Commodore 64 (1984), "
        + "translated from the original program. It runs from your own copy of the disk."
    /// The About panel's copyright line and the bundle's `NSHumanReadableCopyright`: names no rights
    /// holder, only the original's author and publisher.
    static let copyright = "Original by Bruce Artwick, published by SubLogic (1984). Unofficial port; "
        + "not affiliated with or endorsed by the rights holders."

    /// The version when the app runs outside its bundle (`swift run`, tests). Equal to
    /// `CFBundleShortVersionString` / `CFBundleVersion` in Packaging/Info.plist (tested).
    static let fallbackShortVersion = "1.0"
    static let fallbackBuild = "1"

    /// The marketing version: the bundle's, else the fallback.
    static func shortVersion(_ info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        (info?["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackShortVersion
    }

    /// The build number: the bundle's, else the fallback.
    static func build(_ info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        (info?["CFBundleVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackBuild
    }

    /// "Version 1.0 (1)", as the About panel shows it.
    static func versionLine(_ info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        "Version \(shortVersion(info)) (\(build(info)))"
    }

    /// The text `FS2 --version` prints.
    static func plainText(_ info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        [name, versionLine(info), summary, copyright].joined(separator: "\n")
    }
}
