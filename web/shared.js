// Layouts shared by the page (main.js) and the engine worker (engine-worker.js).

// The control block: an Int32Array over a SharedArrayBuffer the page writes and the worker reads
// (FS2Web's WebControls has the same layout).
export const CONTROL = {
  seq: 0,       // bumped on every change; the worker's waits watch it
  held: 1,      // 4 words: Mac key codes held (bit n = code n)
  pressed: 5,   // 4 words: keys pressed since the worker's last read (cleared by the read)
  changed: 9,   // the held keys changed since the last read (cleared by the read)
  flags: 10,    // FLAG bits
  restart: 11,  // RUN/STOP + RESTORE requests (cleared by the read)
  demo: 12,     // demo requests (cleared by the read)
  words: 13,
};

export const FLAG = {
  paused: 1,
  smooth: 2,
  strictJoystick: 4,
  keypadJoystick: 8,
};

// The audio ring: a SharedArrayBuffer holding two Int32 counters (samples read, samples written;
// they only grow, wrapping at 32 bits) followed by RING_SIZE Float32 samples (a power of two).
export const RING_SIZE = 16384;
export const RING_HEADER_BYTES = 8;

// FS2Web's PageMessage kinds.
export const MESSAGE = {
  1: "config",
  2: "demo",
  3: "error",
  4: "ended",
  5: "bad-disk",
};
