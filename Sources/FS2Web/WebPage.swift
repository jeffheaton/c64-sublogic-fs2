#if os(WASI)
import C64Kit
import CFS2Web
import FS2Core
import FS2Data
import FS2Host

/// Messages for the page (`fs2_message`'s kind; web/engine-worker.js names them).
enum PageMessage: Int32 {
    /// The page's configuration (JSON): the picture's size, the palettes, the key table, the reference.
    case config = 1
    /// The demo's state (`DemoMode.Status.rawValue`, as text).
    case demo = 2
    /// The engine stopped making progress (text); the page shows it and pauses.
    case error = 3
    /// The program ended for good (text); the page offers Reset.
    case ended = 4
    /// The disk image cannot be used (text); the page asks for another one.
    case badDisk = 5
}

/// The page's side, as the worker provides it (`CFS2Web`'s imports).
enum WebPage {
    static func send(_ kind: PageMessage, _ text: String) {
        var text = text
        text.withUTF8 { fs2_message(kind.rawValue, $0.baseAddress, Int32($0.count)) }
    }

    static var diskImage: [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Int(fs2_disk_size()))
        bytes.withUnsafeMutableBufferPointer { fs2_disk_read($0.baseAddress) }
        return bytes
    }

    static var savedModeLibrary: [UInt8]? {
        let count = fs2_mode_library_size()
        guard count == ModeLibrary.blockSize else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(count))
        bytes.withUnsafeMutableBufferPointer { fs2_mode_library_read($0.baseAddress) }
        return bytes
    }

    static func saveModeLibrary(_ block: [UInt8]) {
        block.withUnsafeBufferPointer { fs2_mode_library_write($0.baseAddress, Int32($0.count)) }
    }

    static var now: UInt64 { UInt64(fs2_now_ns()) }

    static func wait(_ nanoseconds: UInt64) { fs2_wait(Double(nanoseconds)) }

    /// Blocks for good (the program ended, or nothing can run): the page terminates the worker.
    static func idle() -> Never {
        while true { fs2_wait(3_600_000_000_000) }
    }

    /// The configuration the page needs before the first frame.
    static var configJSON: String {
        func numbers(_ values: [UInt32]) -> String { "[" + values.map { String($0) }.joined(separator: ",") + "]" }
        return "{\"width\":\(VICPresenter.width),\"height\":\(VICPresenter.height),\"pixelAspect\":0.75,"
            + "\"palette\":\(numbers(C64Palette.color)),\"monochrome\":\(numbers(C64Palette.monochrome)),"
            + "\"keys\":\(KeyReference.jsonString(MacKeyCode.webCodeTable)),"
            + "\"reference\":\(KeyReference.json(style: .web))}"
    }
}

/// The control block the page writes (web/engine-worker.js `CONTROL`): the keys held (Mac key
/// codes, 128 bits), the keys pressed since the last read, and the page's settings and requests.
struct WebControls {
    static let words = 13
    enum Word {
        static let held = 1, pressed = 5, changed = 9, flags = 10, restart = 11, demo = 12
    }
    enum Flag {
        static let paused: Int32 = 1, smooth: Int32 = 2, strictJoystick: Int32 = 4, keypadJoystick: Int32 = 8
    }

    private var buffer = [Int32](repeating: 0, count: words)
    private var lastInput = InputState()

    /// Reads the block (clearing the taps and the requests) as the session step takes it.
    mutating func read() -> HostRequests {
        buffer.withUnsafeMutableBufferPointer { fs2_read_controls($0.baseAddress, Int32(Self.words)) }
        let flags = buffer[Word.flags]
        let keypadJoystick = flags & Flag.keypadJoystick != 0
        var r = HostRequests()
        r.input = InputState(keyboard: KeyboardState(held: keys(at: Word.held)), keypadJoystick: keypadJoystick)
        r.pressedSinceRead = KeyboardState(held: keys(at: Word.pressed)).matrix(keypadJoystick: keypadJoystick)
        r.inputChanged = buffer[Word.changed] != 0 || r.input != lastInput
        lastInput = r.input
        r.paused = flags & Flag.paused != 0
        r.restart = buffer[Word.restart] != 0
        r.demo = buffer[Word.demo] != 0
        r.options = EngineOptions(pacing: flags & Flag.smooth != 0 ? .smooth : .authentic,
                                  strictJoystick: flags & Flag.strictJoystick != 0)
        return r
    }

    var options: EngineOptions {
        var copy = self
        return copy.read().options
    }

    private func keys(at word: Int) -> Set<MacKeyCode> {
        var keys: Set<MacKeyCode> = []
        for w in 0..<4 {
            let bits = UInt32(bitPattern: buffer[word + w])
            guard bits != 0 else { continue }
            for b in 0..<32 where bits & (1 << b) != 0 {
                if let key = MacKeyCode(rawValue: UInt16(w * 32 + b)) { keys.insert(key) }
            }
        }
        return keys
    }
}

/// The SID sound for the page: the frames' writes rendered at the output's rate as the virtual
/// clock advances, into the page's audio ring (what does not fit is dropped).
final class WebAudio {
    let feed = AudioFeed()
    private let renderer: SIDRenderer
    private let sampleRate: Double
    private var startCycle: UInt64?
    private var rendered = 0
    private var buffer = [Float](repeating: 0, count: 4096)

    init?(sampleRate: Double) {
        guard sampleRate > 0 else { return nil }
        self.sampleRate = sampleRate
        renderer = SIDRenderer(sampleRate: sampleRate, feed: feed)
        renderer.volume = 1   // the page's volume control is a gain after the worklet
        feed.active.store(true, ordering: .relaxed)
    }

    /// The engine's clock reached `cycles`: render the samples due by then.
    func advance(to cycles: UInt64) {
        guard let start = startCycle else {
            startCycle = cycles
            return
        }
        let due = Int(Double(cycles &- start) * sampleRate / VirtualClock.hz)
        var count = due - rendered
        rendered = due
        while count > 0 {
            let n = min(count, buffer.count)
            buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, count: n) }
            if fs2_audio_room() >= n {
                buffer.withUnsafeBufferPointer { fs2_audio_push($0.baseAddress, Int32(n)) }
            }
            count -= n
        }
    }
}

/// Posts frames to the page, skipping a picture identical to the last one (Authentic pacing
/// changes the window about once a second).
final class WebPresenter {
    private var last: [UInt8] = []
    private var lastMonochrome = false

    func present(_ frame: FrameOutput) {
        guard frame.pixels != last || frame.monochrome != lastMonochrome else { return }
        last = frame.pixels
        lastMonochrome = frame.monochrome
        frame.pixels.withUnsafeBufferPointer { fs2_frame($0.baseAddress, Int32($0.count), frame.monochrome ? 1 : 0) }
    }
}
#endif
