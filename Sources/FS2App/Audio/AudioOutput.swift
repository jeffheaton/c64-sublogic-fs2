import AVFoundation
import FS2Host
import Foundation

/// The SID sound through AVAudioEngine: an `AVAudioSourceNode` pulls mono samples from a
/// `SIDRenderer`, which is fed by the engine thread through `AudioFeed`'s lock-free ring.
@MainActor
final class AudioOutput {
    let feed: AudioFeed
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var renderer: SIDRenderer?
    private var configurationObserver: NSObjectProtocol?
    private var volume: Float = 0.8
    private var muted = false

    init(feed: AudioFeed) {
        self.feed = feed
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        }
    }

    var isRunning: Bool { engine.isRunning && source != nil }

    /// Starts output on the default device. Throws when there is no usable device.
    func start() throws {
        try start(restoring: nil)
    }

    private func start(restoring registers: [UInt8]?) throws {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard rate >= 8000, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else {
            throw CocoaError(.featureUnsupported)
        }
        let renderer = SIDRenderer(sampleRate: rate, feed: feed, restoring: registers)
        renderer.volume = volume
        renderer.muted.store(muted, ordering: .relaxed)
        let node = Self.makeSourceNode(renderer: renderer, format: format)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.detach(node)
            throw error
        }
        source = node
        self.renderer = renderer
        feed.active.store(true, ordering: .releasing)
    }

    func stop() {
        feed.active.store(false, ordering: .releasing)
        engine.stop()
        if let source { engine.detach(source) }
        source = nil
        // Drop whatever the engine thread sent meanwhile.
        while feed.ring.pop() != nil {}
    }

    /// Rebuilds the output after a device or format change, keeping the chip's registers.
    private func restart() {
        let registers = renderer?.registers
        stop()
        renderer = nil
        try? start(restoring: registers)
    }

    func setVolume(_ v: Float) {
        volume = v
        renderer?.volume = v
    }

    func setMuted(_ m: Bool) {
        muted = m
        renderer?.muted.store(m, ordering: .relaxed)
    }

    /// The render block, built outside any actor: it runs on the real-time audio thread.
    private nonisolated static func makeSourceNode(renderer: SIDRenderer, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let n = Int(frameCount)
            guard let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            renderer.render(into: first, count: n)
            for b in buffers.dropFirst() {
                b.mData?.assumingMemoryBound(to: Float.self).update(from: first, count: n)
            }
            return noErr
        }
    }
}
