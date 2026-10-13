import FS2Core
import Foundation

/// The monitor the frame is shown on (View ▸ Display).
enum MonitorKind: String, CaseIterable, Sendable {
    case color
    /// A black-and-white monitor: every color shown as its VIC-II luma gray.
    case blackAndWhite
}

/// User settings, persisted in `UserDefaults`.
struct AppSettings: Equatable, Sendable {
    /// Integer zoom (2-6), used unless `fitWindow` is on.
    var zoom = 2
    /// Scale the frame to whatever size the window has.
    var fitWindow = false
    var aspect = PixelAspect.ntsc
    var pacing = Pacing.authentic
    var monitor = MonitorKind.color
    /// Keypad 8/2/4/6 etc. drive the joysticks (otherwise the keypad types digits).
    var keypadJoystick = true
    /// Reproduce the original's suspension of the keyboard scan while a joystick is deflected
    /// (`EngineOptions.strictJoystick`; the native engine shares the CIA lines otherwise).
    var strictJoystick = false
    var gamepadEnabled = true
    var soundEnabled = true
    var volume: Double = 0.8

    var zoomMode: ZoomMode { fitWindow ? .fit : .fixed(zoom) }

    enum Key {
        static let zoom = "zoom"
        static let fitWindow = "fitWindow"
        static let aspect = "aspect"
        static let pacing = "pacing"
        static let monitor = "monitor"
        static let keypadJoystick = "keypadJoystick"
        static let strictJoystick = "strictJoystick"
        static let gamepadEnabled = "gamepadEnabled"
        static let soundEnabled = "soundEnabled"
        static let volume = "volume"
    }

    /// Reads the settings, using the defaults above for anything missing or invalid.
    static func load(from d: UserDefaults) -> AppSettings {
        var s = AppSettings()
        if let z = d.object(forKey: Key.zoom) as? Int, DisplayGeometry.zoomRange.contains(z) { s.zoom = z }
        if let v = d.object(forKey: Key.fitWindow) as? Bool { s.fitWindow = v }
        if let v = d.string(forKey: Key.aspect).flatMap(PixelAspect.init) { s.aspect = v }
        if let v = d.string(forKey: Key.pacing).flatMap(Pacing.init) { s.pacing = v }
        if let v = d.string(forKey: Key.monitor).flatMap(MonitorKind.init) { s.monitor = v }
        if let v = d.object(forKey: Key.keypadJoystick) as? Bool { s.keypadJoystick = v }
        if let v = d.object(forKey: Key.strictJoystick) as? Bool { s.strictJoystick = v }
        if let v = d.object(forKey: Key.gamepadEnabled) as? Bool { s.gamepadEnabled = v }
        if let v = d.object(forKey: Key.soundEnabled) as? Bool { s.soundEnabled = v }
        if let v = d.object(forKey: Key.volume) as? Double, (0...1).contains(v) { s.volume = v }
        return s
    }

    /// Whether a zoom was ever stored (first launch picks one that fits the screen).
    static func hasStoredZoom(in d: UserDefaults) -> Bool { d.object(forKey: Key.zoom) != nil }

    func save(to d: UserDefaults) {
        d.set(zoom, forKey: Key.zoom)
        d.set(fitWindow, forKey: Key.fitWindow)
        d.set(aspect.rawValue, forKey: Key.aspect)
        d.set(pacing.rawValue, forKey: Key.pacing)
        d.set(monitor.rawValue, forKey: Key.monitor)
        d.set(keypadJoystick, forKey: Key.keypadJoystick)
        d.set(strictJoystick, forKey: Key.strictJoystick)
        d.set(gamepadEnabled, forKey: Key.gamepadEnabled)
        d.set(soundEnabled, forKey: Key.soundEnabled)
        d.set(volume, forKey: Key.volume)
    }
}
