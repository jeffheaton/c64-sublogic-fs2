import AppKit

/// The menu bar. Actions go to the app delegate; check marks and titles are set in its
/// `validateMenuItem`. Every shortcut uses ⌘, so none collides with the game (which uses CTRL).
/// None uses ⇧⌘/ (⌘?) either: macOS keeps that for its Help menu search ("Show Help menu"), so
/// the help window has ⌥⌘/ (`helpShortcut`).
@MainActor
enum MainMenu {
    static let appName = "Flight Simulator II"
    /// Help ▸ Flight Simulator II Help: ⌥⌘/, next to the Keyboard Reference's ⌘/.
    static let helpShortcut = (key: "/", modifiers: NSEvent.ModifierFlags([.command, .option]))

    static func build(target: AppDelegate) -> NSMenu {
        let main = NSMenu()

        func item(_ title: String, _ action: Selector?, _ key: String = "",
                  _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0, toTarget: Bool = true) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = modifiers
            i.tag = tag
            if toTarget { i.target = target }
            return i
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let m = NSMenu(title: title)
            for i in items { m.addItem(i) }
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = m
            return top
        }

        // Application menu.
        main.addItem(submenu(appName, [
            item("About \(appName)", #selector(AppDelegate.showAbout(_:))),
            .separator(),
            item("Settings…", #selector(AppDelegate.showSettings(_:)), ","),
            .separator(),
            item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h", toTarget: false),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option],
                 toTarget: false),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), "", [], toTarget: false),
            .separator(),
            item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q", toTarget: false),
        ]))

        main.addItem(submenu("File", [
            item("Import Disk Image…", #selector(AppDelegate.importDiskImage(_:)), "o"),
            item("Import Character ROM…", #selector(AppDelegate.importCharacterROM(_:))),
            .separator(),
            item("Import Mode Library…", #selector(AppDelegate.importModeLibrary(_:))),
            item("Export Mode Library…", #selector(AppDelegate.exportModeLibrary(_:))),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", toTarget: false),
        ]))

        var view: [NSMenuItem] = DisplayGeometry.zoomRange.map { z in
            item("Zoom \(z)×", #selector(AppDelegate.setZoom(_:)), "\(z)", tag: z)
        }
        view += [
            item("Fit Window", #selector(AppDelegate.toggleFitWindow(_:)), "0"),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control],
                 toTarget: false),
            .separator(),
            submenu("Aspect", [
                item("NTSC TV (0.75 Pixel Aspect)", #selector(AppDelegate.setAspect(_:)), tag: 0),
                item("Square Pixels", #selector(AppDelegate.setAspect(_:)), tag: 1),
            ]),
            submenu("Pacing", [
                item("Authentic", #selector(AppDelegate.setPacing(_:)), tag: 0),
                item("Smooth (60 fps)", #selector(AppDelegate.setPacing(_:)), tag: 1),
            ]),
            submenu("Display", [
                item("Color Monitor", #selector(AppDelegate.setMonitor(_:)), tag: 0),
                item("Black & White Monitor", #selector(AppDelegate.setMonitor(_:)), tag: 1),
            ]),
        ]
        main.addItem(submenu("View", view))

        main.addItem(submenu("Machine", [
            item("Pause", #selector(AppDelegate.togglePause(_:)), "p"),
            item("Restart (RUN/STOP + RESTORE)", #selector(AppDelegate.restartProgram(_:)), "r"),
            item("Reset (Cold Start)", #selector(AppDelegate.resetMachine(_:)), "r", [.command, .shift]),
            .separator(),
            item("Demo Mode", #selector(AppDelegate.startDemoMode(_:))),
            .separator(),
            item("Keyboard Reference…", #selector(AppDelegate.showKeyboardReference(_:)), "/"),
        ]))

        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", toTarget: false),
            item("Zoom", #selector(NSWindow.performZoom(_:)), "", [], toTarget: false),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), "", [], toTarget: false),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu

        let help = submenu("Help", [
            item(HelpContent.title, #selector(AppDelegate.showFlightSimulatorHelp(_:)), helpShortcut.key,
                 helpShortcut.modifiers),
            item("Keyboard Reference", #selector(AppDelegate.showKeyboardReference(_:))),
        ])
        main.addItem(help)
        NSApp.helpMenu = help.submenu
        return main
    }
}
