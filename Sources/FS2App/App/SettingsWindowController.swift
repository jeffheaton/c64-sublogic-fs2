import AppKit

/// Flight Simulator II ▸ Settings… (⌘,): controls and sound. Zoom, aspect, pacing and the monitor
/// type live in the View menu.
@MainActor
final class SettingsWindowController: NSWindowController {
    private var settings: AppSettings
    private let onChange: (AppSettings) -> Void

    private let keypad = NSButton(checkboxWithTitle: "Use the keypad as joysticks", target: nil, action: nil)
    private let strict = NSButton(checkboxWithTitle: "Strict joystick", target: nil, action: nil)
    private let gamepad = NSButton(checkboxWithTitle: "Use game controllers", target: nil, action: nil)
    private let sound = NSButton(checkboxWithTitle: "Sound", target: nil, action: nil)
    private let volume = NSSlider(value: 0.8, minValue: 0, maxValue: 1, target: nil, action: nil)

    init(settings: AppSettings, onChange: @escaping (AppSettings) -> Void) {
        self.settings = settings
        self.onChange = onChange
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        update(settings)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ s: AppSettings) {
        settings = s
        keypad.state = s.keypadJoystick ? .on : .off
        strict.state = s.strictJoystick ? .on : .off
        gamepad.state = s.gamepadEnabled ? .on : .off
        sound.state = s.soundEnabled ? .on : .off
        volume.doubleValue = s.volume
        volume.isEnabled = s.soundEnabled
    }

    private func note(_ text: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.textColor = .secondaryLabelColor
        f.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        f.preferredMaxLayoutWidth = 400
        return f
    }

    private func heading(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return f
    }

    private func build() {
        for control in [keypad, strict, gamepad, sound] {
            control.target = self
            control.action = #selector(changed(_:))
        }
        volume.target = self
        volume.action = #selector(changed(_:))
        volume.isContinuous = true
        volume.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let volumeRow = NSStackView(views: [NSTextField(labelWithString: "Volume"), volume])
        volumeRow.spacing = 8

        let stack = NSStackView(views: [
            heading("Controls"),
            keypad,
            note("Keypad 8/2/4/6 (and 7/9/1/3 diagonals) are joystick 1, the yoke; 5 and 0 are its fire button. "
                 + "Keypad + and - are joystick 2 up and down (throttle) and Enter is its fire button (guns)."),
            gamepad,
            strict,
            note("Like the original, ignore the keyboard while a joystick is deflected (keys pressed meanwhile "
                 + "are lost). Off, keys still work while you steer with a joystick."),
            heading("Sound"),
            sound,
            volumeRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.setCustomSpacing(16, after: stack.views[5])
        window?.contentView = stack
    }

    @objc private func changed(_ sender: Any?) {
        settings.keypadJoystick = keypad.state == .on
        settings.strictJoystick = strict.state == .on
        settings.gamepadEnabled = gamepad.state == .on
        settings.soundEnabled = sound.state == .on
        settings.volume = volume.doubleValue
        volume.isEnabled = settings.soundEnabled
        onChange(settings)
    }
}
