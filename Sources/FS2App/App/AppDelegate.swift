import AppKit
import C64Kit
import FS2Core
import FS2Data
import FS2Host
import UniformTypeIdentifiers

/// The app: one window showing the C64 frame, the menus, settings, the first-run import and the
/// wiring between the UI, the engine thread (`EngineHost`) and the audio output.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation,
    FramebufferKeyHandler, NSAlertDelegate {
    private let defaults = UserDefaults.standard
    private var settings = AppSettings()
    /// Engine requested on the command line (`--engine lab`); `FS2_ENGINE` is read by the factory.
    private let requestedEngine: String?

    private var window: NSWindow!
    private var view: FramebufferView!
    private let frames = FrameExchange()
    private let audioFeed = AudioFeed()
    private var audio: AudioOutput?
    private var host: EngineHost?
    private var engineKind = EngineKind.native

    private var keyboard = KeyboardState()
    private var gamepad: Gamepad?
    private var gamepadJoysticks: (JoystickState, JoystickState) = ([], [])
    private var postedInput = InputState()
    private var userPaused = false

    /// Keeps App Nap from throttling the engine thread while a game runs.
    private var activity: NSObjectProtocol?
    /// Sees the key-ups AppKit does not send to the view (see `applicationDidFinishLaunching`).
    private var keyUpMonitor: Any?
    private var keyReference: KeyboardReferenceWindowController?
    private var helpWindow: HelpWindowController?
    private var settingsWindow: SettingsWindowController?
    private var welcomeVisible = false

    init(requestedEngine: String? = nil) {
        self.requestedEngine = requestedEngine
        super.init()
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = AppSettings.load(from: defaults)
        if !AppSettings.hasStoredZoom(in: defaults), let screen = NSScreen.main {
            let room = CGSize(width: screen.visibleFrame.width * 0.9, height: screen.visibleFrame.height * 0.9 - 40)
            settings.zoom = DisplayGeometry.largestZoom(fitting: room, aspect: settings.aspect)
        }
        NSApp.mainMenu = MainMenu.build(target: self)
        buildWindow()
        // AppKit does not deliver a key-up to the view while ⌘ is held (say T is let go during ⌘P),
        // which would leave the C64 key held forever; catch those here. Releasing is idempotent.
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            if event.modifierFlags.contains(.command) {
                MainActor.assumeIsolated { self?.commandKeyUp(event) }
            }
            return event
        }
        startAudio()
        gamepad = Gamepad()
        do {
            engineKind = try EngineFactory.resolve(requested: requestedEngine)
        } catch {
            engineKind = .native
            NSLog("FS2: \(error); using the native engine")
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        startGame()
    }

    func applicationWillTerminate(_ notification: Notification) {
        host?.stop()
        audio?.stop()
        settings.save(to: defaults)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidResignActive(_ notification: Notification) { releaseKeys() }

    private func buildWindow() {
        let size = DisplayGeometry.contentSize(zoom: settings.zoom, aspect: settings.aspect)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = MainMenu.appName
        w.collectionBehavior = [.fullScreenPrimary]
        w.contentMinSize = DisplayGeometry.contentSize(zoom: 1, aspect: settings.aspect)
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        w.delegate = self
        let v = FramebufferView(frame: NSRect(origin: .zero, size: size))
        v.frames = frames
        v.keyHandler = self
        v.onRefresh = { [unowned self] in self.pollGamepad() }
        w.contentView = v
        w.initialFirstResponder = v
        window = w
        view = v
        applyPresentation()
        if !w.setFrameUsingName("FS2 Main Window") { w.center() }
        w.setFrameAutosaveName("FS2 Main Window")
        if !settings.fitWindow { resizeWindowForZoom() }
    }

    // MARK: Game data and engine

    private func startGame() {
        guard GameLibrary.hasImportedDisk else {
            showWelcome()
            return
        }
        do {
            startEngine(try GameLibrary.load())
        } catch {
            showError(error, message: FirstRun.importedCopyFailedTitle,
                      advice: FirstRun.importedCopyAdvice) { [weak self] in
                self?.showWelcome()
            }
        }
    }

    private func startEngine(_ data: GameData) {
        host?.stop()
        let kind = engineKind
        let h = EngineHost(frames: frames, audio: audioFeed, onError: { message in
            Task { @MainActor in self.engineFailed(message) }
        }, factory: { try EngineFactory.make(kind, data: data) })
        host = h
        userPaused = false
        h.setOptions(engineOptions)
        h.setInput(postedInput)
        h.start()
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                             reason: "Running the flight simulation")
        }
        updateMute()
        window.title = kind == .lab ? "\(MainMenu.appName) (lab engine)" : MainMenu.appName
    }

    private func engineFailed(_ message: String) {
        userPaused = true
        updateMute()
        let alert = NSAlert()
        alert.messageText = "The simulation stopped"
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }

    private func startAudio() {
        let a = AudioOutput(feed: audioFeed)
        do {
            try a.start()
        } catch {
            NSLog("FS2: no audio output (\(error))")
        }
        a.setVolume(Float(settings.volume))
        audio = a
        updateMute()
    }

    private func updateMute() {
        audio?.setMuted(userPaused || !settings.soundEnabled)
        host?.setPaused(userPaused)
    }

    // MARK: First run and imports

    private func showWelcome() {
        guard !welcomeVisible, window.attachedSheet == nil else { return }
        welcomeVisible = true
        let alert = NSAlert()
        alert.messageText = FirstRun.welcomeTitle
        alert.informativeText = FirstRun.welcomeText
        alert.addButton(withTitle: FirstRun.chooseButton)
        alert.addButton(withTitle: FirstRun.quitButton)
        alert.showsHelp = true
        alert.delegate = self
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.welcomeVisible = false
            if response == .alertFirstButtonReturn {
                self.chooseDiskImage(firstRun: true)
            } else {
                NSApp.terminate(nil)
            }
        }
    }

    /// The welcome sheet's help button.
    func alertShowHelp(_ alert: NSAlert) -> Bool {
        showFlightSimulatorHelp(nil)
        return true
    }

    private func chooseDiskImage(firstRun: Bool) {
        let panel = NSOpenPanel()
        panel.title = FirstRun.panelTitle
        panel.message = FirstRun.panelMessage
        panel.prompt = FirstRun.panelPrompt
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // Any file can be chosen: the checks then say in plain words why it is not usable.
        panel.allowedContentTypes = [UTType(filenameExtension: "d64") ?? .data, .data]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else {
                if firstRun && !GameLibrary.hasImportedDisk { self.showWelcome() }
                return
            }
            self.importDisk(at: url, firstRun: firstRun)
        }
    }

    private func importDisk(at url: URL, firstRun: Bool) {
        do {
            try GameLibrary.importDisk(from: url)
            startEngine(try GameLibrary.load())
        } catch {
            showError(error, message: FirstRun.importFailedTitle) { [weak self] in
                guard let self else { return }
                if firstRun || !GameLibrary.hasImportedDisk { self.showWelcome() }
            }
        }
    }

    /// An error alert: `message` as the title, then `FirstRun.errorDetails` (what went wrong, the
    /// disk checks for a disk error, what to do next).
    private func showError(_ error: Error, message: String, advice: String? = nil,
                           then: (@MainActor () -> Void)? = nil) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = FirstRun.errorDetails(error, advice: advice)
        alert.beginSheetModal(for: window) { _ in then?() }
    }

    @objc func importDiskImage(_ sender: Any?) { chooseDiskImage(firstRun: false) }

    @objc func importCharacterROM(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Choose a Commodore 64 Character ROM"
        panel.message = "Optional: a dump of the character ROM from your own C64 (4096 bytes, often named "
            + "“chargen”). Only the editor's text screens use it; without it they use a look-alike font."
        panel.prompt = "Import"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try GameLibrary.importCharROM(from: url)
                let alert = NSAlert()
                alert.messageText = "Character ROM imported"
                alert.informativeText = "It is used from the next cold start (Machine ▸ Reset)."
                alert.beginSheetModal(for: self.window)
            } catch {
                self.showError(error, message: "The character ROM could not be imported.")
            }
        }
    }

    @objc func importModeLibrary(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Import a Mode Library"
        panel.message = "Choose a ModeLibrary.bin with user modes 10-24. The current library is kept as a backup."
        panel.prompt = "Import"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try GameLibrary.importModeLibrary(from: url)
            } catch {
                self.showError(error, message: "The mode library could not be imported.")
            }
        }
    }

    @objc func exportModeLibrary(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.title = "Export the Mode Library"
        panel.nameFieldStringValue = "ModeLibrary.bin"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try GameLibrary.exportModeLibrary(to: url)
            } catch {
                self.showError(error, message: "The mode library could not be exported.")
            }
        }
    }

    // MARK: Menu actions

    /// The standard About panel with `AboutInfo`: name, version, the description, the copyright.
    @objc func showAbout(_ sender: Any?) {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let credits = NSAttributedString(
            string: AboutInfo.summary,
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.labelColor, .paragraphStyle: centered])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AboutInfo.name,
            .applicationVersion: AboutInfo.shortVersion(),
            .version: AboutInfo.build(),
            .credits: credits,
            // The panel's copyright line (otherwise NSHumanReadableCopyright, the same text).
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): AboutInfo.copyright,
        ])
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(settings: settings) { [weak self] s in self?.settingsChanged(s) }
        }
        settingsWindow?.update(settings)
        settingsWindow?.showWindow(nil)
    }

    @objc func showKeyboardReference(_ sender: Any?) {
        if keyReference == nil { keyReference = KeyboardReferenceWindowController() }
        keyReference?.showWindow(nil)
    }

    /// Help ▸ Flight Simulator II Help (⌥⌘/), and the welcome sheet's help button.
    @objc func showFlightSimulatorHelp(_ sender: Any?) {
        if helpWindow == nil {
            helpWindow = HelpWindowController { [weak self] in self?.showKeyboardReference(nil) }
        }
        helpWindow?.showWindow(nil)
    }

    @objc func setZoom(_ sender: NSMenuItem) {
        guard DisplayGeometry.zoomRange.contains(sender.tag) else { return }
        settings.zoom = sender.tag
        settings.fitWindow = false
        settingsDidChange()
        resizeWindowForZoom()
    }

    @objc func toggleFitWindow(_ sender: Any?) {
        settings.fitWindow.toggle()
        settingsDidChange()
        if !settings.fitWindow { resizeWindowForZoom() }
    }

    @objc func setAspect(_ sender: NSMenuItem) {
        settings.aspect = sender.tag == 0 ? .ntsc : .square
        window.contentMinSize = DisplayGeometry.contentSize(zoom: 1, aspect: settings.aspect)
        settingsDidChange()
        if !settings.fitWindow { resizeWindowForZoom() }
    }

    @objc func setPacing(_ sender: NSMenuItem) {
        settings.pacing = sender.tag == 0 ? .authentic : .smooth
        settingsDidChange()
    }

    @objc func setMonitor(_ sender: NSMenuItem) {
        settings.monitor = sender.tag == 0 ? .color : .blackAndWhite
        settingsDidChange()
    }

    @objc func togglePause(_ sender: Any?) {
        guard host != nil else { return }
        userPaused.toggle()
        updateMute()
    }

    @objc func restartProgram(_ sender: Any?) {
        host?.requestRestart()
    }

    /// Machine ▸ Demo Mode: the mode prompt's demo answer (A) from the menu (`DemoMode`); any key
    /// takes over, as in the original. Enabled in regular flight; checked (and disabled) while the
    /// demo runs or is about to.
    @objc func startDemoMode(_ sender: Any?) {
        host?.requestDemo()
    }

    @objc func resetMachine(_ sender: Any?) {
        guard host != nil else { return }
        do {
            startEngine(try GameLibrary.load())
        } catch {
            showError(error, message: "The machine could not be reset.")
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(setZoom(_:)):
            item.state = !settings.fitWindow && settings.zoom == item.tag ? .on : .off
            return !isFullScreen
        case #selector(toggleFitWindow(_:)):
            item.state = settings.fitWindow ? .on : .off
            return !isFullScreen
        case #selector(setAspect(_:)):
            item.state = (item.tag == 0) == (settings.aspect == .ntsc) ? .on : .off
        case #selector(setPacing(_:)):
            item.state = (item.tag == 0) == (settings.pacing == .authentic) ? .on : .off
        case #selector(setMonitor(_:)):
            item.state = (item.tag == 0) == (settings.monitor == .color) ? .on : .off
        case #selector(togglePause(_:)):
            item.title = userPaused ? "Resume" : "Pause"
            return host != nil
        case #selector(restartProgram(_:)), #selector(resetMachine(_:)):
            return host != nil
        case #selector(startDemoMode(_:)):
            let demo = host?.demoStatus ?? DemoMode.Status()
            item.state = demo.running ? .on : .off
            return demo.available
        case #selector(exportModeLibrary(_:)):
            return FileManager.default.fileExists(atPath: GameLibrary.modeLibraryURL.path)
        default:
            break
        }
        return true
    }

    // MARK: Settings

    private func settingsChanged(_ s: AppSettings) {
        settings = s
        settingsDidChange()
    }

    private func settingsDidChange() {
        settings.save(to: defaults)
        applyPresentation()
        host?.setOptions(engineOptions)
        audio?.setVolume(Float(settings.volume))
        updateMute()
        postInput()
        settingsWindow?.update(settings)
    }

    private var engineOptions: EngineOptions {
        EngineOptions(pacing: settings.pacing, strictJoystick: settings.strictJoystick)
    }

    private func applyPresentation() {
        view.aspect = settings.aspect
        view.zoomMode = isFullScreen ? .fit : settings.zoomMode
        view.forceMonochrome = settings.monitor == .blackAndWhite
    }

    private var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    /// Sizes the window to the zoom (kept on screen; the frame is fitted if the screen is too small).
    private func resizeWindowForZoom() {
        guard !isFullScreen, let window else { return }
        let size = DisplayGeometry.contentSize(zoom: settings.zoom, aspect: settings.aspect)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        let old = window.frame
        frame.origin = NSPoint(x: old.minX, y: old.maxY - frame.height)   // keep the top-left corner
        if let screen = window.screen ?? NSScreen.main {
            frame = window.constrainFrameRect(frame, to: screen)
        }
        window.setFrame(frame, display: true, animate: false)
    }

    // MARK: Window delegate

    func windowDidResignKey(_ notification: Notification) { releaseKeys() }

    /// The main window is the game: closing it quits, even while Settings or the keyboard
    /// reference stay open (otherwise the simulation would run on, and sound, with no window).
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }

    func windowDidEndLiveResize(_ notification: Notification) {
        // A manual resize means the user wants the frame to follow the window.
        guard !isFullScreen, !settings.fitWindow else { return }
        let size = DisplayGeometry.contentSize(zoom: settings.zoom, aspect: settings.aspect)
        let content = window.contentLayoutRect.size
        if abs(content.width - size.width) > 1 || abs(content.height - size.height) > 1 {
            settings.fitWindow = true
            settingsDidChange()
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) { applyPresentation() }
    func windowDidExitFullScreen(_ notification: Notification) { applyPresentation() }

    // MARK: Input

    func framebufferKeyDown(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) { return false }   // ⌘-shortcuts belong to the menus
        if keyboard.keyDown(event.keyCode, isRepeat: event.isARepeat) { postInput() }
        return true   // unmapped keys are ignored quietly (no system beep during play)
    }

    /// A key-up that arrived while ⌘ was held (the view never gets those).
    private func commandKeyUp(_ event: NSEvent) {
        guard event.window == nil || event.window === window else { return }
        if keyboard.keyUp(event.keyCode) { postInput() }
    }

    func framebufferKeyUp(_ event: NSEvent) -> Bool {
        if keyboard.keyUp(event.keyCode) { postInput() }
        return !event.modifierFlags.contains(.command)
    }

    func framebufferFlagsChanged(_ event: NSEvent) -> Bool {
        let used = keyboard.modifierChanged(event.keyCode, modifierFlags: event.modifierFlags.rawValue)
        if used { postInput() }
        return used
    }

    private func releaseKeys() {
        keyboard.releaseAll()
        postInput()
    }

    private func pollGamepad() {
        let state = settings.gamepadEnabled ? (gamepad?.poll() ?? ([], [])) : ([], [])
        if state != gamepadJoysticks {
            gamepadJoysticks = state
            postInput()
        }
    }

    /// Merges keyboard and gamepad into the engine's input (sent only when it changes).
    private func postInput() {
        let input = InputState(keyboard: keyboard, keypadJoystick: settings.keypadJoystick, gamepad: gamepadJoysticks)
        guard input != postedInput else { return }
        postedInput = input
        host?.setInput(input)
    }
}
