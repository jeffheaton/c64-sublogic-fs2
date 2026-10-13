// The engine worker: runs fs2.wasm (a WASI command that never returns) and provides its "fs2"
// imports. The page starts it with one message (the compiled module, the disk, the shared control
// block and audio ring); after that the worker only blocks in Atomics.wait between frames, so
// everything the page changes reaches it through the shared memory, not through messages.

import { CONTROL, MESSAGE, RING_HEADER_BYTES, RING_SIZE } from "./shared.js";
import { createWASI } from "./wasi.js";

self.onmessage = (event) => {
  self.onmessage = null;
  run(event.data);
};

function run({ module, disk, modeLibrary, controls, ring, sampleRate }) {
  const control = new Int32Array(controls);
  const ringHeader = ring ? new Int32Array(ring, 0, 2) : null;
  const ringData = ring ? new Float32Array(ring, RING_HEADER_BYTES, RING_SIZE) : null;
  const decoder = new TextDecoder();
  let memory = null;
  let lastSeq = 0;
  const bytes = () => new Uint8Array(memory.buffer);

  const fs2 = {
    disk_size: () => disk.length,
    disk_read: (ptr) => bytes().set(disk, ptr),
    mode_library_size: () => (modeLibrary ? modeLibrary.length : -1),
    mode_library_read: (ptr) => bytes().set(modeLibrary, ptr),
    mode_library_write: (ptr, count) => {
      self.postMessage({ type: "mode-library", bytes: bytes().slice(ptr, ptr + count) });
    },
    sample_rate: () => sampleRate,
    now_ns: () => performance.now() * 1e6,
    // Sleeps until the page changes a control since the last read, or the time is up.
    wait: (nanoseconds) => {
      Atomics.wait(control, CONTROL.seq, lastSeq, Math.max(0, nanoseconds / 1e6));
    },
    read_controls: (ptr, count) => {
      const out = new Int32Array(memory.buffer, ptr, count);
      lastSeq = Atomics.load(control, CONTROL.seq);
      out[CONTROL.seq] = lastSeq;
      for (let i = 0; i < 4; i++) {
        out[CONTROL.held + i] = Atomics.load(control, CONTROL.held + i);
        out[CONTROL.pressed + i] = Atomics.exchange(control, CONTROL.pressed + i, 0);
      }
      out[CONTROL.changed] = Atomics.exchange(control, CONTROL.changed, 0);
      out[CONTROL.flags] = Atomics.load(control, CONTROL.flags);
      out[CONTROL.restart] = Atomics.exchange(control, CONTROL.restart, 0);
      out[CONTROL.demo] = Atomics.exchange(control, CONTROL.demo, 0);
    },
    frame: (ptr, count, monochrome) => {
      const pixels = bytes().slice(ptr, ptr + count);
      self.postMessage({ type: "frame", pixels, monochrome: monochrome !== 0 }, [pixels.buffer]);
    },
    audio_room: () => {
      if (!ringHeader) return 0;
      return RING_SIZE - ((Atomics.load(ringHeader, 1) - Atomics.load(ringHeader, 0)) | 0);
    },
    audio_push: (ptr, count) => {
      if (!ringHeader) return;
      const samples = new Float32Array(memory.buffer, ptr, count);
      let write = Atomics.load(ringHeader, 1);
      for (let i = 0; i < count; i++, write = (write + 1) | 0) ringData[write & (RING_SIZE - 1)] = samples[i];
      Atomics.store(ringHeader, 1, write);
    },
    message: (kind, ptr, count) => {
      const text = decoder.decode(bytes().slice(ptr, ptr + count));
      self.postMessage({ type: MESSAGE[kind] ?? "log", text });
    },
  };

  const wasi = createWASI({
    stdout: (line) => self.postMessage({ type: "log", text: line }),
    stderr: (line) => self.postMessage({ type: "log", text: line }),
  });
  try {
    const instance = new WebAssembly.Instance(module, { wasi_snapshot_preview1: wasi.imports, fs2 });
    memory = instance.exports.memory;
    const code = wasi.start(instance);
    self.postMessage({ type: "ended", text: `the engine exited (${code})` });
  } catch (error) {
    // A trap: a stack overflow, a failed precondition in the port.
    self.postMessage({ type: "crash", text: String(error && error.message ? error.message : error) });
  }
}
