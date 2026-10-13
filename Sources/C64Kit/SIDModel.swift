/// One SID voice: the 24-bit phase accumulator with its waveform generators, and the envelope.
///
/// The accumulator adds the 16-bit frequency register every cycle, so the tone is
/// frequency × clock / 2^24 Hz. Waveforms are 12-bit values read off the accumulator: sawtooth is
/// its top 12 bits; triangle is bits 22-11, inverted while bit 23 is set (bit 23 exclusive-or the
/// modulating voice's bit 23 with ring modulation on); pulse is all ones while the top 12 bits are
/// at least the pulse width. Noise comes from a 23-bit shift register (feedback from bits 22 and 17)
/// that shifts whenever accumulator bit 19 goes high; eight of its bits drive the top of the DAC.
/// Several waveforms selected at once combine roughly as a bitwise AND, which is how they are
/// modeled. With no waveform selected the DAC keeps its last value.
///
/// TEST (control bit 3) holds the accumulator at zero, forces the pulse output high and fills the
/// noise register with ones.
struct SIDVoice {
    var accumulator: UInt32 = 0
    /// Added every cycle: the frequency, or 0 while TEST is set.
    var increment: UInt32 = 0
    var frequency: UInt16 = 0
    var pulseWidth: UInt32 = 0
    var control: UInt8 = 0
    var noise: UInt32 = 0x7F_FFFF
    /// The 12-bit noise waveform for the current register state.
    var noiseLevel = SIDVoice.noiseWaveform(0x7F_FFFF)
    /// DAC input while no waveform is selected.
    var held: UInt32 = 0
    var envelope = VoiceEnvelope()

    /// Noise register bits 22, 20, 16, 13, 11, 7, 4 and 2 drive waveform bits 11 down to 4.
    static func noiseWaveform(_ r: UInt32) -> UInt32 {
        (r >> 11 & 0x800) | (r >> 10 & 0x400) | (r >> 7 & 0x200) | (r >> 5 & 0x100)
            | (r >> 4 & 0x080) | (r >> 1 & 0x040) | (r << 1 & 0x020) | (r << 2 & 0x010)
    }

    @inline(__always)
    mutating func shiftNoise() {
        noise = (noise << 1 | ((noise >> 22) ^ (noise >> 17)) & 1) & 0x7F_FFFF
        noiseLevel = Self.noiseWaveform(noise)
    }

    /// The 12-bit waveform output. `modulator` is the accumulator of the voice that ring-modulates
    /// and hard-syncs this one.
    @inline(__always)
    func waveform(modulator: UInt32) -> UInt32 {
        switch control >> 4 {
        case 0: return held
        case 1: return triangle(modulator)
        case 2: return accumulator >> 12
        case 4: return pulse
        case 8: return noiseLevel
        default:
            var w: UInt32 = 0xFFF
            if control & 0x10 != 0 { w &= triangle(modulator) }
            if control & 0x20 != 0 { w &= accumulator >> 12 }
            if control & 0x40 != 0 { w &= pulse }
            if control & 0x80 != 0 { w &= noiseLevel }
            return w
        }
    }

    @inline(__always)
    private func triangle(_ modulator: UInt32) -> UInt32 {
        let top = control & 0x04 != 0 ? accumulator ^ modulator : accumulator
        let ramp = accumulator >> 11 & 0xFFF
        return top & 0x80_0000 != 0 ? ramp ^ 0xFFF : ramp
    }

    @inline(__always)
    private var pulse: UInt32 {
        control & 0x08 != 0 || accumulator >> 12 >= pulseWidth ? 0xFFF : 0
    }

    /// Writes voice register 0-6.
    mutating func write(_ register: Int, _ value: UInt8, modulator: UInt32) {
        switch register {
        case 0: frequency = frequency & 0xFF00 | UInt16(value)
        case 1: frequency = UInt16(value) << 8 | frequency & 0x00FF
        case 2: pulseWidth = pulseWidth & 0xF00 | UInt32(value)
        case 3: pulseWidth = UInt32(value & 0x0F) << 8 | pulseWidth & 0x0FF
        case 4:
            held = waveform(modulator: modulator)
            control = value
            if value & 0x08 != 0 {
                accumulator = 0
                noise = 0x7F_FFFF
                noiseLevel = Self.noiseWaveform(noise)
            }
            envelope.setGate(value & 0x01 != 0)
        case 5: envelope.setAttackDecay(value)
        default: envelope.setSustainRelease(value)
        }
        increment = control & 0x08 != 0 ? 0 : UInt32(frequency)
    }
}

/// Everything the chip and the board do per cycle, kept in one value so the cycle loop runs on
/// local state.
struct SIDEngine {
    let clockHz: Double
    var v1 = SIDVoice(), v2 = SIDVoice(), v3 = SIDVoice()
    var filter = MultimodeFilter()
    var board: BoardOutput
    var resampler: OutputResampler

    /// FC (11 bits), $D417 and $D418 as written.
    private var cutoff = 0
    private var resonanceRouting: UInt8 = 0
    private var modeVolume: UInt8 = 0
    /// 1 for a voice routed through the filter (`wet`) or straight to the mixer (`dry`), else 0.
    private var wet1 = 0.0, wet2 = 0.0, wet3 = 0.0
    private var dry1 = 1.0, dry2 = 1.0, dry3 = 1.0
    /// Master volume times the normalization to output units.
    private var volumeGain = 0.0
    /// The waveform value that gives no output, and a constant the mixer adds before the volume stage.
    private var silentWave: Int32 = SIDEngine.midScale
    private var mixerOffset = 0.0

    /// A voice contributes (waveform − silent value) × envelope; full scale is ±2048 × 255. Three
    /// such voices at volume 15 map to ±0.5.
    static let outputScale = 0.5 / (3 * 2048 * 255 * 15)
    static let midScale: Int32 = 0x800
    /// On the 6581 the waveform value that gives no output is about $380 rather than mid-scale, and
    /// the mixer carries a standing offset of about one voice's amplitude, which the volume DAC
    /// scales: hence the click of a volume write.
    static let chipSilentWave: Int32 = 0x380
    static let chipMixerOffset = 2048.0 * 255

    init(clockHz: Double, sampleRate: Double) {
        self.clockHz = clockHz
        board = BoardOutput(clockHz: clockHz, sampleRate: sampleRate)
        resampler = OutputResampler(clockHz: clockHz, sampleRate: sampleRate)
        retuneFilter()
    }

    /// Power-on state of the registers, voices and filter; the board and the resampler are kept.
    mutating func resetChip() {
        v1 = SIDVoice()
        v2 = SIDVoice()
        v3 = SIDVoice()
        filter.discharge()
        cutoff = 0
        resonanceRouting = 0
        modeVolume = 0
        retuneFilter()
        reroute()
    }

    mutating func useChipOffsets(_ on: Bool) {
        silentWave = on ? Self.chipSilentWave : Self.midScale
        mixerOffset = on ? Self.chipMixerOffset : 0
    }

    mutating func write(_ register: Int, _ value: UInt8) {
        switch register {
        case 0x00...0x06: v1.write(register, value, modulator: v3.accumulator)
        case 0x07...0x0D: v2.write(register - 7, value, modulator: v1.accumulator)
        case 0x0E...0x14: v3.write(register - 14, value, modulator: v2.accumulator)
        case 0x15:
            cutoff = cutoff & 0x7F8 | Int(value & 0x07)
            retuneFilter()
        case 0x16:
            cutoff = Int(value) << 3 | cutoff & 0x07
            retuneFilter()
        case 0x17:
            resonanceRouting = value
            retuneFilter()
            reroute()
        case 0x18:
            modeVolume = value
            reroute()
        default: break
        }
    }

    func waveform(voice: Int) -> UInt32 {
        switch voice {
        case 0: v1.waveform(modulator: v3.accumulator)
        case 1: v2.waveform(modulator: v1.accumulator)
        default: v3.waveform(modulator: v2.accumulator)
        }
    }

    func envelopeLevel(voice: Int) -> UInt8 {
        switch voice {
        case 0: v1.envelope.level
        case 1: v2.envelope.level
        default: v3.envelope.level
        }
    }

    private mutating func retuneFilter() {
        filter.tune(cutoffHz: MultimodeFilter.cutoff6581(cutoff),
                    quality: MultimodeFilter.quality(resonance: Int(resonanceRouting >> 4)), clockHz: clockHz)
    }

    /// Applies $D417's routing bits and $D418's mode bits, 3OFF and volume. 3OFF mutes voice 3 only
    /// on the direct path; routed through the filter it still sounds. With no mode bit set the
    /// filter output is not connected, so routed voices are silent.
    private mutating func reroute() {
        wet1 = resonanceRouting & 0x01 != 0 ? 1 : 0
        wet2 = resonanceRouting & 0x02 != 0 ? 1 : 0
        wet3 = resonanceRouting & 0x04 != 0 ? 1 : 0
        dry1 = 1 - wet1
        dry2 = 1 - wet2
        dry3 = modeVolume & 0x80 != 0 ? 0 : 1 - wet3
        filter.lowLevel = modeVolume & 0x10 != 0 ? 1 : 0
        filter.bandLevel = modeVolume & 0x20 != 0 ? 1 : 0
        filter.highLevel = modeVolume & 0x40 != 0 ? 1 : 0
        volumeGain = Double(modeVolume & 0x0F) * Self.outputScale
    }

    /// One chip cycle; returns the board's output at the cycle rate.
    @inline(__always)
    private mutating func clockOnce() -> Double {
        let old1 = v1.accumulator, old2 = v2.accumulator, old3 = v3.accumulator
        v1.accumulator = (old1 &+ v1.increment) & 0xFF_FFFF
        v2.accumulator = (old2 &+ v2.increment) & 0xFF_FFFF
        v3.accumulator = (old3 &+ v3.increment) & 0xFF_FFFF
        // Bits that went from 0 to 1 this cycle: bit 19 clocks the noise, bit 23 syncs the next voice.
        let rose1 = v1.accumulator & ~old1, rose2 = v2.accumulator & ~old2, rose3 = v3.accumulator & ~old3
        if rose1 & 0x08_0000 != 0 { v1.shiftNoise() }
        if rose2 & 0x08_0000 != 0 { v2.shiftNoise() }
        if rose3 & 0x08_0000 != 0 { v3.shiftNoise() }
        if rose3 & 0x80_0000 != 0 && v1.control & 0x02 != 0 { v1.accumulator = 0 }
        if rose1 & 0x80_0000 != 0 && v2.control & 0x02 != 0 { v2.accumulator = 0 }
        if rose2 & 0x80_0000 != 0 && v3.control & 0x02 != 0 { v3.accumulator = 0 }

        v1.envelope.clock()
        v2.envelope.clock()
        v3.envelope.clock()

        let out1 = Double(Int32(bitPattern: v1.waveform(modulator: v3.accumulator)) - silentWave) * Double(v1.envelope.level)
        let out2 = Double(Int32(bitPattern: v2.waveform(modulator: v1.accumulator)) - silentWave) * Double(v2.envelope.level)
        let out3 = Double(Int32(bitPattern: v3.waveform(modulator: v2.accumulator)) - silentWave) * Double(v3.envelope.level)
        let filtered = filter.process(out1 * wet1 + out2 * wet2 + out3 * wet3)
        let mixed = (out1 * dry1 + out2 * dry2 + out3 * dry3 + filtered + mixerOffset) * volumeGain
        return board.lowPass(mixed)
    }

    /// Clocks up to `cycles` cycles, writing up to `maxSamples` samples to `out` (computed but dropped
    /// when nil); stops right after the cycle that completes the last sample allowed.
    mutating func run(cycles: Int, into out: UnsafeMutablePointer<Float>?, maxSamples: Int,
                      gain: Float) -> (cycles: Int, samples: Int) {
        var produced = 0
        // When the output rate is above the stage-1 rate, one stage-1 sample can owe several outputs.
        while produced < maxSamples && resampler.outputDue {
            emit(into: out, at: produced, gain: gain)
            produced += 1
        }
        var done = 0
        while done < cycles && produced < maxSamples {
            let x = clockOnce()
            done += 1
            if resampler.push(Float(x)) {
                // Every 8th cycle, so the samples do not depend on how the calls split the run.
                filter.flushTinyStates()
                board.flushTinyStates()
                while produced < maxSamples && resampler.outputDue {
                    emit(into: out, at: produced, gain: gain)
                    produced += 1
                }
            }
        }
        return (done, produced)
    }

    @inline(__always)
    private mutating func emit(into out: UnsafeMutablePointer<Float>?, at index: Int, gain: Float) {
        let y = Float(board.highPass(resampler.nextOutput())) * gain
        out?[index] = min(1, max(-1, y))
    }
}

/// MOS 6581 SID, clocked cycle by cycle: three voices (24-bit oscillators, the noise shift
/// register, ring modulation and hard sync, ADSR envelopes with the chip's rate counter), the
/// multimode filter, the mixer with its 4-bit master volume, and the C64 board's output network.
/// The cycle-rate signal is brought to `sampleRate` by a two-stage band-limiting resampler.
///
/// By default the mixer is centered: silent voices and an idle mixer output exactly 0, so volume
/// writes do not click. `authenticDCOffsets` adds the 6581's offsets back, with the click.
///
/// Not thread-safe. `run`, `render` and `clock` do not allocate and are safe on a real-time audio thread.
public final class SIDModel {
    public static let ntscClockHz = 1_022_727.14
    public static let palClockHz = 985_248.0
    /// Cycles a value written to the chip stays readable on its data bus.
    static let busHoldCycles = 0x2000

    public let clockHz: Double
    public let sampleRate: Double
    /// Cycles clocked so far. Settable to align the chip with an external cycle counter.
    public var cycle: UInt64 = 0
    /// Output gain. At 1, three full-amplitude voices at volume 15 peak at +/-0.5, which leaves
    /// headroom for filter resonance and the output high-pass; samples are clamped to -1...1.
    public var gain: Float = 1
    /// Paddle inputs ($19, $1A); $FF with nothing connected.
    public var potX: UInt8 = 0xFF
    public var potY: UInt8 = 0xFF
    /// Models the 6581's waveform and mixer DC offsets (volume writes then click, as on the chip).
    public var authenticDCOffsets = false {
        didSet { engine.useChipOffsets(authenticDCOffsets) }
    }

    private var engine: SIDEngine
    private var busValue: UInt8 = 0
    private var busHold = 0

    public init(clockHz: Double = SIDModel.ntscClockHz, sampleRate: Double) {
        self.clockHz = clockHz
        self.sampleRate = sampleRate
        engine = SIDEngine(clockHz: clockHz, sampleRate: sampleRate)
    }

    deinit { engine.resampler.deallocate() }

    /// Hardware reset of the chip registers, oscillators, envelopes and filter. The output stage, the
    /// resampler and `cycle` keep running.
    public func reset() {
        engine.resetChip()
        busValue = 0
        busHold = 0
    }

    /// Writes register $00-$18 (mirrored every 32 bytes). Writes to the read-only registers only load the bus.
    public func write(_ reg: Int, _ value: UInt8) {
        engine.write(reg & 0x1F, value)
        busValue = value
        busHold = Self.busHoldCycles
    }

    /// Reads a register: $19/$1A paddles, $1B OSC3 (voice 3 waveform output, high 8 bits),
    /// $1C ENV3 (voice 3 envelope). Write-only registers return the last value written to the chip
    /// until it fades (after $2000 cycles) to 0.
    public func read(_ reg: Int) -> UInt8 {
        switch reg & 0x1F {
        case 0x19: potX
        case 0x1A: potY
        case 0x1B: UInt8(truncatingIfNeeded: engine.waveform(voice: 2) >> 4)
        case 0x1C: engine.envelopeLevel(voice: 2)
        default: busHold > 0 ? busValue : 0
        }
    }

    /// Envelope level of voice 0-2.
    public func envelopeLevel(voice: Int) -> UInt8 {
        engine.envelopeLevel(voice: voice)
    }

    /// 12-bit waveform output of voice 0-2.
    public func waveformOutput(voice: Int) -> UInt16 {
        UInt16(engine.waveform(voice: voice))
    }

    /// Cutoff frequency in Hz of the 6581 filter for an 11-bit FC value.
    public static func cutoffFrequency6581(_ fc: Int) -> Double { MultimodeFilter.cutoff6581(fc) }

    /// Advances the chip `cycles` cycles, discarding the audio produced (the output pipeline still runs,
    /// so later rendering continues seamlessly).
    public func clock(cycles: Int) {
        _ = run(cycles: cycles, into: nil, maxSamples: .max)
    }

    /// Produces exactly `count` samples, clocking the chip for as long as that takes.
    public func render(into out: UnsafeMutablePointer<Float>, count: Int) {
        var produced = 0
        while produced < count {
            produced += run(cycles: .max, into: out + produced, maxSamples: count - produced).samples
        }
    }

    /// Allocating convenience for `render(into:count:)`.
    public func render(count: Int) -> [Float] {
        guard count > 0 else { return [] }
        return [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
            render(into: buffer.baseAddress!, count: count)
            initialized = count
        }
    }

    /// Clocks up to `cycles` cycles, writing output samples to `out` (or dropping them when nil). Stops
    /// right after the cycle that completes the `maxSamples`th sample. Returns what was done.
    public func run(cycles: Int, into out: UnsafeMutablePointer<Float>?, maxSamples: Int)
        -> (cycles: Int, samples: Int) {
        let done = engine.run(cycles: cycles, into: out, maxSamples: maxSamples, gain: gain)
        cycle &+= UInt64(done.cycles)
        busHold = max(0, busHold - done.cycles)
        return done
    }
}
