// Plays the SID samples the engine worker renders into the shared ring. It starts once a little
// is buffered (to ride out the worker's frame-by-frame rhythm) and plays silence when the ring
// runs dry (paused, or the worker fell behind), then waits for the buffer again.

const RING_HEADER_BYTES = 8;

class RingPlayer extends AudioWorkletProcessor {
  constructor(options) {
    super();
    const { ring, size, threshold } = options.processorOptions;
    this.header = new Int32Array(ring, 0, 2);
    this.data = new Float32Array(ring, RING_HEADER_BYTES, size);
    this.size = size;
    this.threshold = threshold;
    this.playing = false;
  }

  process(_inputs, outputs) {
    const out = outputs[0][0];
    const read = Atomics.load(this.header, 0);
    const available = (Atomics.load(this.header, 1) - read) | 0;
    if (!this.playing && available >= this.threshold) this.playing = true;
    if (!this.playing) {
      out.fill(0);
      return true;
    }
    const n = Math.min(available, out.length);
    const mask = this.size - 1;
    for (let i = 0; i < n; i++) out[i] = this.data[(read + i) & mask];
    if (n < out.length) {
      out.fill(0, n);
      this.playing = false;
    }
    Atomics.store(this.header, 0, (read + n) | 0);
    return true;
  }
}

registerProcessor("fs2-ring-player", RingPlayer);
