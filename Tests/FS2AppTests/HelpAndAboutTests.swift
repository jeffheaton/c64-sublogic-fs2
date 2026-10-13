import AppKit
import C64Kit
@testable import FS2App
@testable import FS2Host
import FS2LabKit
import Foundation
import Testing

/// The About box, the help window's text and the bundle's Info.plist.
@Suite struct HelpAndAboutTests {
    private static var root: URL { KeyReferenceTests.repositoryRoot }

    private static func infoPlist() throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent("Packaging/Info.plist"))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    // MARK: About

    @Test func aboutBox() {
        #expect(AboutInfo.name == "Flight Simulator II (C64 port)")
        #expect(AboutInfo.copyright == "Original by Bruce Artwick, published by SubLogic (1984). Unofficial port; "
                + "not affiliated with or endorsed by the rights holders.")
        #expect(!AboutInfo.summary.contains("\n") && AboutInfo.summary.count < 200)   // one line
        #expect(!AboutInfo.summary.contains("by hand"))
        #expect(AboutInfo.versionLine([:]) == "Version \(AboutInfo.fallbackShortVersion) (\(AboutInfo.fallbackBuild))")
        let bundled: [String: Any] = ["CFBundleShortVersionString": "2.5", "CFBundleVersion": "42"]
        #expect(AboutInfo.versionLine(bundled) == "Version 2.5 (42)")
        #expect(AboutInfo.plainText([:]).split(separator: "\n").count == 4)
    }

    /// The About box, the help and the bundle say the port is unofficial, and the credit line names
    /// the original's author and publisher without claiming a rights holder for anyone.
    @Test func unofficialNotice() throws {
        let notice = "not affiliated with or endorsed by the rights holders"
        #expect(AboutInfo.copyright.contains("Unofficial port") && AboutInfo.copyright.contains(notice))
        #expect(AboutInfo.plainText([:]).contains(notice))
        let first = try #require(HelpContent.topics().first?.paragraphs.first)
        #expect(first.contains("unofficial port, " + notice))
        let bundled = try #require(try Self.infoPlist()["NSHumanReadableCopyright"] as? String)
        for text in [AboutInfo.copyright, bundled] {
            #expect(!text.contains("©") && !text.contains("Corp") && !text.contains("Microsoft"), "\(text)")
        }
    }

    /// The version shown outside the bundle is the bundle's; the copyright line is the About box's.
    @Test func infoPlistAgreesWithTheAboutBox() throws {
        let info = try Self.infoPlist()
        #expect(info["CFBundleShortVersionString"] as? String == AboutInfo.fallbackShortVersion)
        #expect(info["CFBundleVersion"] as? String == AboutInfo.fallbackBuild)
        #expect(info["NSHumanReadableCopyright"] as? String == AboutInfo.copyright)
        #expect(AboutInfo.versionLine(info) == AboutInfo.versionLine([:]))
    }

    /// The keys `make app` relies on: the executable SwiftPM builds, the icon `make icon` makes, the
    /// macOS 15 floor of Package.swift.
    @Test func infoPlistKeys() throws {
        let info = try Self.infoPlist()
        #expect(info["CFBundleExecutable"] as? String == "FS2")
        #expect(info["CFBundleIconFile"] as? String == "FS2")
        #expect(info["CFBundlePackageType"] as? String == "APPL")
        #expect(info["LSMinimumSystemVersion"] as? String == "15.0")
        #expect(info["NSPrincipalClass"] as? String == "NSApplication")
        #expect(info["NSHighResolutionCapable"] as? Bool == true)
        #expect((info["CFBundleIdentifier"] as? String)?.isEmpty == false)
        #expect(info["CFBundleName"] as? String == "Flight Simulator II")
        #expect(info["LSApplicationCategoryType"] as? String == "public.app-category.simulation-games")
        let makefile = try String(contentsOf: Self.root.appendingPathComponent("Makefile"), encoding: .utf8)
        #expect(makefile.contains("Packaging/Info.plist") && makefile.contains("--product FS2"))
        #expect(makefile.contains("build/FS2.icns") && makefile.contains("codesign --force --sign -"))
        let checker = Self.root.appendingPathComponent("Packaging/check-app.sh")
        #expect(FileManager.default.isExecutableFile(atPath: checker.path))
    }

    // MARK: README

    /// The README's headless example uses only steps the native engine runs: every step but the
    /// lab's instrumentation (`cov:` and `watch:`, which headless runs skip), and `pc:` only at the
    /// two addresses the native engine can stop at (the key wait $2250 and the main loop's top
    /// $204B).
    @Test func readmeHeadlessExampleRunsOnTheNativeEngine() throws {
        let readme = try String(contentsOf: Self.root.appendingPathComponent("README.md"), encoding: .utf8)
        let example = try #require(readme.firstMatch(of: try Regex("--headless --engine native[^`]*?--session \"([^\"]+)\"")))
        let text = try #require(example.output[1].substring)
        let session = try Session.parse(String(text))
        #expect(session.steps.contains { if case .screenshot = $0 { true } else { false } })
        for step in session.steps {
            switch step {
            case .wait, .press, .joystick, .screenshot, .poke, .snapshot, .keysDown, .keysUp, .nmi, .peek, .waitByte,
                 .textScreen:
                break
            case .waitPC(let address, _):
                #expect([waitForKeyAddress, mainLoopTopAddress].contains(UInt16(truncatingIfNeeded: address)),
                        "the native engine stops only at the key wait and the main loop's top: \(step)")
            case .coverage, .watch:
                Issue.record("lab-only step (skipped by headless runs) in the README's headless example: \(step)")
            }
        }
        _ = try HeadlessRunner.plan(session.steps)              // the key and joystick names
    }

    /// The README says the files in re/sessions/ run headless, all but the one it names also on
    /// the native engine: every file parses, its key and joystick names are valid, and the files
    /// with a `pc:` stop the native engine cannot make are exactly the ones the README names.
    @Test func readmeSessionFilesRunOnTheNativeEngine() throws {
        let readme = try String(contentsOf: Self.root.appendingPathComponent("README.md"), encoding: .utf8)
        let claim = try #require(readme.firstMatch(of: try Regex("all but\\s+`([a-z0-9-]+\\.txt)`")))
        let named = try #require(claim.output[1].substring.map(String.init))
        let directory = Self.root.appendingPathComponent("re/sessions")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "txt" }
        #expect(files.count > 40, "\(files.count) session files")
        let native: Set<UInt16> = [waitForKeyAddress, mainLoopTopAddress]
        var labOnly: [String] = []
        for url in files {
            let session = try Session.parse(String(contentsOf: url, encoding: .utf8))
            _ = try HeadlessRunner.plan(session.steps)
            let stops = session.steps.compactMap { step -> UInt16? in
                if case .waitPC(let address, _) = step { UInt16(truncatingIfNeeded: address) } else { nil }
            }
            if stops.contains(where: { !native.contains($0) }) { labOnly.append(url.lastPathComponent) }
        }
        #expect(labOnly == [named], "sessions with a pc: stop the native engine cannot make: \(labOnly)")
    }

    // MARK: Help

    @Test func helpCoversTheGame() {
        let topics = HelpContent.topics()
        #expect(topics.count >= 6)
        for t in topics { #expect(!t.paragraphs.isEmpty, "\(t.title)") }
        let text = HelpContent.plainText()
        for words in [".d64", "WHAT DISPLAY ARE YOU USING?", "SELECT OPERATING MODE", "Meigs", "radar", "editor",
                      "ModeLibrary.bin", "EUROPE 1917", "Authentic", "Smooth", "⌘/", "Course plotter"] {
            #expect(text.contains(words), "\(words)")
        }
    }

    /// ⇧⌘/ (⌘?) is macOS's "Show Help menu" (the Help menu's search field), so the help window uses
    /// ⌥⌘/; the keyboard reference and the help say so, and Machine ▸ Demo Mode is in the help.
    @MainActor @Test func helpShortcutAvoidsTheHelpMenuSearch() {
        let shortcut = MainMenu.helpShortcut
        #expect(shortcut.key == "/" && shortcut.modifiers == [.command, .option])
        #expect(shortcut.key != "?" && !shortcut.modifiers.contains(.shift))
        let rows = KeyReference.machineSection().rows
        #expect(rows.contains { $0.mac == "⌥⌘/" && $0.function == HelpContent.title })
        #expect(rows.contains { $0.mac == "⌘/" }, "the keyboard reference keeps ⌘/")
        #expect(!rows.contains { $0.mac.contains("?") })
        let text = HelpContent.plainText()
        #expect(text.contains("this help (⌥⌘/)"))
        #expect(text.contains("Machine ▸ Demo Mode") && text.contains("Demo Mode starts the demo"))
    }

    /// The menu bar as built: the help item has ⌥⌘/ and nothing has ⇧⌘/ (typed as ⌘?), no two items
    /// share a shortcut, and Machine ▸ Demo Mode is there, disabled and unchecked with no game.
    @MainActor @Test func menuBarShortcuts() throws {
        _ = NSApplication.shared                    // the build sets the app's Window and Help menus
        let delegate = AppDelegate()
        let bar = MainMenu.build(target: delegate)
        var items: [(menu: String, item: NSMenuItem)] = []
        func collect(_ menu: NSMenu) {
            for item in menu.items {
                items.append((menu.title, item))
                if let sub = item.submenu { collect(sub) }
            }
        }
        collect(bar)
        let shortcuts = items.map(\.item).filter { !$0.keyEquivalent.isEmpty }
        #expect(shortcuts.count > 10)
        let keys = shortcuts.map { item in
            "\(item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask).rawValue) \(item.keyEquivalent)"
        }
        #expect(Set(keys).count == keys.count, "a shortcut is used twice: \(keys)")
        for item in shortcuts {
            #expect(item.keyEquivalentModifierMask.contains(.command), "\(item.title)")
            let helpSearch = item.keyEquivalent == "?"
                || item.keyEquivalent == "/" && item.keyEquivalentModifierMask.contains(.shift)
            #expect(!helpSearch, "\(item.title) takes ⇧⌘/, the Help menu search")
        }
        let help = try #require(items.first { $0.menu == "Help" && $0.item.title == HelpContent.title }?.item)
        #expect(help.keyEquivalent == MainMenu.helpShortcut.key)
        #expect(help.keyEquivalentModifierMask == MainMenu.helpShortcut.modifiers)
        let demo = try #require(items.first { $0.menu == "Machine" && $0.item.title == "Demo Mode" }?.item)
        #expect(demo.action == #selector(AppDelegate.startDemoMode(_:)) && demo.target === delegate)
        #expect(!delegate.validateMenuItem(demo) && demo.state == .off, "no game, no demo")
    }

    /// The help names the Mac keys the mapper really uses, and every Control combination it names is
    /// in the keyboard reference with the same purpose.
    @Test func helpKeysMatchTheMapper() throws {
        let text = HelpContent.plainText()
        #expect(text.contains("; up, \(KeyReference.macName(for: .colon)) down"))
        #expect(text.contains("the \(KeyReference.macName(for: .plus)) key"))
        #expect(text.contains("P or \(KeyReference.macName(for: .runStop)) pauses"))
        #expect(text.contains("E (or \(KeyReference.macName(for: .clrHome)))"))
        let control = KeyReference.controlSection().rows
        let named = try Regex("Control-([A-Z])")
        let letters = Set(text.matches(of: named).map { String(text[$0.range].suffix(1)) })
        #expect(letters.count >= 8)
        for letter in letters {
            #expect(control.contains { $0.mac == "Control-" + letter }, "Control-\(letter) is not in the reference")
        }
        // Single keys the help assigns a job to do that job in the reference.
        func does(_ key: C64Key, _ words: String) {
            #expect(KeyReference.function(of: key).localizedCaseInsensitiveContains(words), "\(key.label): \(words)")
        }
        does(.semicolon, "throttle up"); does(.colon, "throttle down"); does(.t, "nose down"); does(.b, "nose up")
        does(.f, "left"); does(.h, "right"); does(.c, "rudder left"); does(.m, "rudder right")
        does(.n, "flaps down"); does(.y, "flaps up"); does(.r, "trim nose down"); does(.v, "trim nose up")
        does(.g, "center"); does(.space, "brakes"); does(.digit4, "radar"); does(.digit5, "view")
        does(.l, "lights"); does(.q, "course plotter"); does(.s, "user mode"); does(.plus, "recall")
        does(.w, "war"); does(.x, "bomb"); does(.e, "editor"); does(.p, "pause"); does(.slash, "full or idle")
    }

    @MainActor
    @Test func helpWindowText() {
        let shown = HelpWindowController.attributedHelp().string
        #expect(shown.hasPrefix(HelpContent.title))
        for t in HelpContent.topics() {
            #expect(shown.contains(t.title + "\n"))
            for p in t.paragraphs {
                let expected = p.hasPrefix("• ") ? "•\t" + String(p.dropFirst(2)) : p
                #expect(shown.contains(expected), "\(p.prefix(30))")
            }
        }
    }
}
