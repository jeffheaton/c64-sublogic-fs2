// A minimal WASI (preview 1) for the engine worker: what Swift's runtime and stdlib import from a
// WASI command, with no file system. stdout and stderr go to the given line handlers, stdin is
// empty, there are no arguments, environment variables or preopened directories.

const ERRNO_SUCCESS = 0;
const ERRNO_BADF = 8;
const ERRNO_NOENT = 44;
const ERRNO_NOSYS = 52;
const ERRNO_SPIPE = 70;
const FILETYPE_CHARACTER_DEVICE = 2;

/** Thrown by proc_exit to unwind out of the module. */
export class WASIExit extends Error {
  constructor(code) {
    super(`exit ${code}`);
    this.code = code;
  }
}

export function createWASI({ stdout = console.log, stderr = console.error } = {}) {
  let memory = null;
  const view = () => new DataView(memory.buffer);
  const bytes = () => new Uint8Array(memory.buffer);
  const decoders = { 1: new TextDecoder(), 2: new TextDecoder() };
  const pending = { 1: "", 2: "" };
  const sinks = { 1: stdout, 2: stderr };

  function emit(fd, text) {
    pending[fd] += text;
    let newline;
    while ((newline = pending[fd].indexOf("\n")) >= 0) {
      sinks[fd](pending[fd].slice(0, newline));
      pending[fd] = pending[fd].slice(newline + 1);
    }
  }

  const imports = {
    args_get: () => ERRNO_SUCCESS,
    args_sizes_get: (argc, bufSize) => {
      view().setUint32(argc, 0, true);
      view().setUint32(bufSize, 0, true);
      return ERRNO_SUCCESS;
    },
    environ_get: () => ERRNO_SUCCESS,
    environ_sizes_get: (count, bufSize) => {
      view().setUint32(count, 0, true);
      view().setUint32(bufSize, 0, true);
      return ERRNO_SUCCESS;
    },
    clock_res_get: (_id, resolution) => {
      view().setBigUint64(resolution, 1000n, true);
      return ERRNO_SUCCESS;
    },
    clock_time_get: (id, _precision, time) => {
      // 0 realtime, 1 monotonic (and the CPU-time clocks, which nothing here uses).
      const ns = id === 0
        ? BigInt(Date.now()) * 1_000_000n
        : BigInt(Math.round(performance.now() * 1_000_000));
      view().setBigUint64(time, ns, true);
      return ERRNO_SUCCESS;
    },
    fd_close: () => ERRNO_SUCCESS,
    fd_fdstat_get: (fd, stat) => {
      if (fd > 2) return ERRNO_BADF;
      const v = view();
      v.setUint8(stat, FILETYPE_CHARACTER_DEVICE);
      v.setUint16(stat + 2, 0, true);
      v.setBigUint64(stat + 8, 0n, true);
      v.setBigUint64(stat + 16, 0n, true);
      return ERRNO_SUCCESS;
    },
    fd_prestat_get: () => ERRNO_BADF,
    fd_prestat_dir_name: () => ERRNO_BADF,
    fd_read: (fd, _iovs, _iovsLen, nread) => {
      if (fd !== 0) return ERRNO_BADF;
      view().setUint32(nread, 0, true);
      return ERRNO_SUCCESS;
    },
    fd_seek: () => ERRNO_SPIPE,
    fd_write: (fd, iovs, iovsLen, nwritten) => {
      if (fd !== 1 && fd !== 2) return ERRNO_BADF;
      const v = view();
      let total = 0;
      for (let i = 0; i < iovsLen; i++) {
        const ptr = v.getUint32(iovs + i * 8, true);
        const len = v.getUint32(iovs + i * 8 + 4, true);
        emit(fd, decoders[fd].decode(bytes().slice(ptr, ptr + len), { stream: true }));
        total += len;
      }
      v.setUint32(nwritten, total, true);
      return ERRNO_SUCCESS;
    },
    path_open: () => ERRNO_NOENT,
    poll_oneoff: () => ERRNO_NOSYS,
    proc_exit: (code) => {
      throw new WASIExit(code);
    },
    random_get: (buf, len) => {
      crypto.getRandomValues(bytes().subarray(buf, buf + len));
      return ERRNO_SUCCESS;
    },
  };

  return {
    imports,
    /** Runs a WASI command's `_start`; returns its exit code. */
    start(instance) {
      memory = instance.exports.memory;
      try {
        instance.exports._start();
        return 0;
      } catch (e) {
        if (e instanceof WASIExit) return e.code;
        throw e;
      } finally {
        for (const fd of [1, 2]) if (pending[fd]) sinks[fd](pending[fd]);
      }
    },
  };
}

