// The WebAssembly build's entry point (fs2.wasm, a WASI command run by web/engine-worker.js in a
// Web Worker). It boots the port on the disk the page hands over and runs it inline for good: the
// program runs on this stack, and at every frame the shared host step (`SessionDriver`) applies
// the page's controls, posts the picture and the sound, and sleeps until the next frame is due.

#if os(WASI)
import C64Kit
import CFS2Web
import FS2Core
import FS2Data
import FS2Host

let data: GameData
do {
    data = try GameData(d64: D64Image(data: WebPage.diskImage))
} catch {
    WebPage.send(.badDisk, "\(error)")
    WebPage.idle()
}
WebPage.send(.config, WebPage.configJSON)

let modeLibrary = ModeLibrary.InMemoryStore(block: WebPage.savedModeLibrary)
let modeLibraryIO = ModeLibrary.IO(load: { modeLibrary.io.load() }, formatAndSave: { block in
    guard modeLibrary.io.formatAndSave(block) else { return false }
    WebPage.saveModeLibrary(block)
    return true
})

nonisolated(unsafe) var controls = WebControls()
let audio = WebAudio(sampleRate: fs2_sample_rate())
let presenter = WebPresenter()
let engine = NativeEngine(data: data, modeLibrary: modeLibraryIO, execution: .inline)

var io = SessionDriver.IO(now: { WebPage.now }, wait: WebPage.wait, readRequests: { controls.read() })
var lastDemo: UInt8?
io.demoStatus = { status in
    guard status.rawValue != lastDemo else { return }
    lastDemo = status.rawValue
    WebPage.send(.demo, String(status.rawValue))
}
io.sliceEnded = { cycles in audio?.advance(to: cycles) }
io.error = { WebPage.send(.error, $0) }

let driver = SessionDriver(engine: engine, audio: audio?.feed, options: controls.options, io: io) { frame in
    presenter.present(frame)
}
let host = InlineSessionHost(driver: driver, stopped: { WebPage.idle() }, ended: { reason in
    WebPage.send(.ended, reason)
    WebPage.idle()
})
engine.runInline(host)
#else
print("FS2Web is the WebAssembly build of Flight Simulator II: build it with `make web`.")
#endif
