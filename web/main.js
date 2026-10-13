// The page: cross-origin isolation, the disk, the engine worker, the keyboard, the sound, the
// picture and the controls. The game itself runs in engine-worker.js (fs2.wasm).

import { CONTROL, FLAG, RING_HEADER_BYTES, RING_SIZE } from "./shared.js";

const DISK_URL = "FlightSimulatorII.d64";
const WASM_URL = "fs2.wasm";
const DISK_SIZES = [174848, 175531, 196608, 197376];

const $ = (selector) => document.querySelector(selector);

// MARK: Settings (per browser)

const DEFAULTS = {
  pacing: "authentic",
  aspect: "ntsc",
  monitor: "color",
  keypadJoystick: true,
  strictJoystick: false,
  sound: true,
  volume: 0.8,
};

function loadSettings() {
  try {
    return { ...DEFAULTS, ...JSON.parse(localStorage.getItem("fs2.settings") || "{}") };
  } catch {
    return { ...DEFAULTS };
  }
}

const settings = loadSettings();

function saveSettings() {
  try {
    localStorage.setItem("fs2.settings", JSON.stringify(settings));
  } catch {
    // Storage blocked: the settings last for this visit.
  }
}

// MARK: Browser storage for the disk and the mode library (IndexedDB)

function openStore() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open("fs2", 1);
    request.onupgradeneeded = () => request.result.createObjectStore("files");
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

async function storedFile(key) {
  try {
    const db = await openStore();
    return await new Promise((resolve, reject) => {
      const get = db.transaction("files").objectStore("files").get(key);
      get.onsuccess = () => resolve(get.result ?? null);
      get.onerror = () => reject(get.error);
    });
  } catch {
    return null;
  }
}

async function storeFile(key, value) {
  try {
    const db = await openStore();
    await new Promise((resolve, reject) => {
      const tx = db.transaction("files", "readwrite");
      if (value === null) tx.objectStore("files").delete(key);
      else tx.objectStore("files").put(value, key);
      tx.oncomplete = resolve;
      tx.onerror = () => reject(tx.error);
    });
  } catch {
    // Storage blocked: nothing is kept for the next visit.
  }
}

// MARK: Cross-origin isolation (SharedArrayBuffer, Atomics.wait)

async function ensureIsolation() {
  const flag = "fs2.isolationReload";
  if (self.crossOriginIsolated) {
    try { sessionStorage.removeItem(flag); } catch {}
    return true;
  }
  if (!("serviceWorker" in navigator) || !window.isSecureContext) return false;
  let reloaded = false;
  try { reloaded = sessionStorage.getItem(flag) === "1"; } catch {}
  try {
    await navigator.serviceWorker.register("isolation-sw.js");
    if (reloaded) return false;
    await navigator.serviceWorker.ready;
    try { sessionStorage.setItem(flag, "1"); } catch {}
    location.reload();
    await new Promise(() => {});
  } catch {
    return false;
  }
  return false;
}

// MARK: The engine

const engine = {
  module: null,
  disk: null,
  diskFromDrop: false,
  worker: null,
  running: false,
  paused: false,
  sampleRate: 0,
  controls: null,
  ring: null,
};

function bump(notify) {
  Atomics.add(engine.controls, CONTROL.seq, 1);
  if (notify) Atomics.notify(engine.controls, CONTROL.seq);
}

function setFlag(bit, on) {
  if (on) Atomics.or(engine.controls, CONTROL.flags, bit);
  else Atomics.and(engine.controls, CONTROL.flags, ~bit);
  bump(true);
}

function applyEngineSettings() {
  setFlag(FLAG.smooth, settings.pacing === "smooth");
  setFlag(FLAG.strictJoystick, settings.strictJoystick);
  setFlag(FLAG.keypadJoystick, settings.keypadJoystick);
}

async function startWorker() {
  stopWorker();
  const c = engine.controls;
  for (let i = 0; i < CONTROL.words; i++) if (i !== CONTROL.flags) Atomics.store(c, i, 0);
  held.clear();
  if (engine.ring) {
    const header = new Int32Array(engine.ring, 0, 2);
    Atomics.store(header, 1, Atomics.load(header, 0));
  }
  const modeLibrary = await storedFile("modeLibrary");
  const worker = new Worker(new URL("./engine-worker.js", import.meta.url), { type: "module" });
  worker.onmessage = (event) => onWorkerMessage(worker, event.data);
  worker.onerror = (event) => showMessage("The engine could not start", event.message || "", true);
  worker.postMessage({
    module: engine.module,
    disk: engine.disk,
    modeLibrary,
    controls: c.buffer,
    ring: engine.ring,
    sampleRate: engine.sampleRate,
  });
  engine.worker = worker;
  engine.running = true;
  setPaused(false);
  enableControls(true);
}

function stopWorker() {
  if (engine.worker) engine.worker.terminate();
  engine.worker = null;
  engine.running = false;
}

function onWorkerMessage(worker, message) {
  if (worker !== engine.worker) return;
  switch (message.type) {
    case "config":
      configure(JSON.parse(message.text));
      hide("#loading");
      if (engine.diskFromDrop) {
        storeFile("disk", engine.disk);
        engine.diskFromDrop = false;
      }
      break;
    case "frame":
      latest = message;
      dirty = true;
      break;
    case "demo": {
      const status = Number(message.text);
      $("#demo").disabled = !engine.running || (status & 1) === 0;
      $("#demo").setAttribute("aria-pressed", String((status & 2) !== 0));
      break;
    }
    case "error":
      setPaused(true);
      showMessage("The engine stopped", message.text, true);
      break;
    case "ended":
    case "crash":
      stopWorker();
      enableControls(false);
      $("#reset").disabled = false;
      showMessage("The engine stopped", `${message.text}. Reset starts the machine again.`, true);
      break;
    case "bad-disk":
      stopWorker();
      enableControls(false);
      if (!engine.diskFromDrop) storeFile("disk", null);
      engine.disk = null;
      showDrop(`This disk image can't be used: ${message.text}`);
      break;
    case "mode-library":
      storeFile("modeLibrary", message.bytes);
      break;
    case "log":
      console.log("[fs2]", message.text);
      break;
  }
}

function setPaused(paused) {
  engine.paused = paused;
  setFlag(FLAG.paused, paused);
  $("#pause").setAttribute("aria-pressed", String(paused));
  $("#pause").textContent = paused ? "Resume" : "Pause";
  $("#paused-badge").hidden = !paused;
}

function enableControls(on) {
  for (const id of ["#pause", "#restart", "#reset"]) $(id).disabled = !on;
  if (!on) $("#demo").disabled = true;
}

// MARK: Configuration from the engine (palettes, keys, reference)

let palette = null;
let monochromePalette = null;
let frameWidth = 384;
let frameHeight = 248;
let pixelAspect = 0.75;
const keyCodes = new Map();

/** 0xAARRGGBB to the little-endian RGBA bytes of ImageData (0xAABBGGRR). */
function toImageDataColor(argb) {
  const r = (argb >>> 16) & 0xff, g = (argb >>> 8) & 0xff, b = argb & 0xff;
  return ((0xff << 24) | (b << 16) | (g << 8) | r) >>> 0;
}

function configure(config) {
  frameWidth = config.width;
  frameHeight = config.height;
  pixelAspect = config.pixelAspect;
  palette = Uint32Array.from(config.palette, toImageDataColor);
  monochromePalette = Uint32Array.from(config.monochrome, toImageDataColor);
  keyCodes.clear();
  for (const line of config.keys.split("\n")) {
    const [code, mac] = line.split("=");
    keyCodes.set(code, Number(mac));
  }
  buildReference(config.reference);
  layout();
}

/** The reference: the first section (the flying keys) open, every other one under "Every key". */
function buildReference(sections) {
  const body = $("#reference-body");
  body.replaceChildren();
  const table = (section) => {
    const t = document.createElement("table");
    const head = t.createTHead().insertRow();
    for (const title of ["Key", "Commodore 64", "In Flight Simulator II"]) {
      const th = document.createElement("th");
      th.textContent = title;
      head.appendChild(th);
    }
    const tbody = t.createTBody();
    for (const row of section.rows) {
      const tr = tbody.insertRow();
      for (const cell of row) tr.insertCell().textContent = cell;
    }
    return t;
  };
  const heading = (section) => {
    const h = document.createElement("h3");
    h.textContent = section.title;
    return h;
  };
  const [first, ...rest] = sections;
  if (first) body.append(heading(first), table(first));
  if (rest.length === 0) return;
  const details = document.createElement("details");
  const summary = document.createElement("summary");
  summary.textContent = "Every key";
  details.append(summary);
  for (const section of rest) details.append(heading(section), table(section));
  body.append(details);
}

// MARK: Keyboard

const held = new Set();

function writeHeld() {
  const words = [0, 0, 0, 0];
  for (const key of held) words[key >> 5] |= 1 << (key & 31);
  for (let i = 0; i < 4; i++) Atomics.store(engine.controls, CONTROL.held + i, words[i]);
  Atomics.store(engine.controls, CONTROL.changed, 1);
  bump(false);
}

function capturingKeys() {
  return engine.running && !document.querySelector("dialog[open]") && $("#message").hidden;
}

window.addEventListener("keydown", (event) => {
  if (!capturingKeys() || event.metaKey) return;
  const key = keyCodes.get(event.code);
  if (key === undefined) return;
  event.preventDefault();
  if (event.repeat || held.has(key)) return;
  held.add(key);
  Atomics.or(engine.controls, CONTROL.pressed + (key >> 5), 1 << (key & 31));
  writeHeld();
});

window.addEventListener("keyup", (event) => {
  const key = keyCodes.get(event.code);
  if (key === undefined || !held.has(key)) return;
  event.preventDefault();
  held.delete(key);
  writeHeld();
});

function releaseKeys() {
  if (held.size === 0 || !engine.controls) return;
  held.clear();
  writeHeld();
}

window.addEventListener("blur", releaseKeys);
document.addEventListener("visibilitychange", () => {
  if (document.hidden) releaseKeys();
});

// MARK: Sound

let audioContext = null;
let gain = null;

async function startAudio() {
  if (audioContext) return audioContext.sampleRate;
  try {
    audioContext = new AudioContext({ latencyHint: "interactive" });
    await audioContext.audioWorklet.addModule("audio-worklet.js");
    const player = new AudioWorkletNode(audioContext, "fs2-ring-player", {
      numberOfInputs: 0,
      numberOfOutputs: 1,
      outputChannelCount: [1],
      processorOptions: {
        ring: engine.ring,
        size: RING_SIZE,
        threshold: Math.round(audioContext.sampleRate * 0.06),
      },
    });
    gain = audioContext.createGain();
    player.connect(gain).connect(audioContext.destination);
    applyVolume();
    await audioContext.resume();
    return audioContext.sampleRate;
  } catch (error) {
    console.warn("no sound:", error);
    audioContext = null;
    return 0;
  }
}

function applyVolume() {
  $("#sound").setAttribute("aria-pressed", String(settings.sound));
  $("#volume").value = String(Math.round(settings.volume * 100));
  $("#volume").disabled = !settings.sound;
  if (gain) gain.gain.value = settings.sound ? settings.volume : 0;
}

// MARK: Picture

const canvas = $("#screen");
const context = canvas.getContext("2d");
const frameCanvas = document.createElement("canvas");
const frameContext = frameCanvas.getContext("2d");
const scaledCanvas = document.createElement("canvas");
const scaledContext = scaledCanvas.getContext("2d");
let imageData = null;
let latest = null;
let dirty = false;

/** Fits the canvas into the stage at the chosen pixel shape, in device pixels. */
function layout() {
  const stage = $("#stage");
  const aspect = settings.aspect === "ntsc" ? pixelAspect : 1;
  const ratio = frameWidth / (frameHeight / aspect);
  const width = Math.max(1, Math.min(stage.clientWidth, stage.clientHeight * ratio));
  const height = width / ratio;
  canvas.style.width = `${Math.floor(width)}px`;
  canvas.style.height = `${Math.floor(height)}px`;
  const dpr = window.devicePixelRatio || 1;
  canvas.width = Math.max(1, Math.round(Math.floor(width) * dpr));
  canvas.height = Math.max(1, Math.round(Math.floor(height) * dpr));
  dirty = true;
}

/** "Sharp bilinear": an integer nearest-neighbor prescale, then a smooth scale to the canvas. */
function draw() {
  if (!latest || !palette) return;
  if (!imageData || imageData.width !== frameWidth) {
    frameCanvas.width = frameWidth;
    frameCanvas.height = frameHeight;
    imageData = frameContext.createImageData(frameWidth, frameHeight);
  }
  const colors = latest.monochrome || settings.monitor === "bw" ? monochromePalette : palette;
  const out = new Uint32Array(imageData.data.buffer);
  const pixels = latest.pixels;
  for (let i = 0; i < out.length; i++) out[i] = colors[pixels[i] & 0x0f];
  frameContext.putImageData(imageData, 0, 0);

  const kx = Math.min(16, Math.max(1, Math.ceil(canvas.width / frameWidth)));
  const ky = Math.min(16, Math.max(1, Math.ceil(canvas.height / frameHeight)));
  if (scaledCanvas.width !== frameWidth * kx || scaledCanvas.height !== frameHeight * ky) {
    scaledCanvas.width = frameWidth * kx;
    scaledCanvas.height = frameHeight * ky;
  }
  scaledContext.imageSmoothingEnabled = false;
  scaledContext.drawImage(frameCanvas, 0, 0, scaledCanvas.width, scaledCanvas.height);
  context.imageSmoothingEnabled = true;
  context.imageSmoothingQuality = "high";
  context.drawImage(scaledCanvas, 0, 0, canvas.width, canvas.height);
}

function frameLoop() {
  if (dirty) {
    dirty = false;
    draw();
  }
  requestAnimationFrame(frameLoop);
}

new ResizeObserver(layout).observe($("#stage"));

// MARK: Overlays and dialogs

function show(selector) { $(selector).hidden = false; }
function hide(selector) { $(selector).hidden = true; }

function showMessage(title, text, offerReset) {
  $("#message-title").textContent = title;
  $("#message-text").textContent = text;
  $("#message-reset").hidden = !offerReset;
  show("#message");
}

function showDrop(error) {
  hide("#loading");
  hide("#start");
  const e = $("#drop-error");
  e.textContent = error || "";
  e.hidden = !error;
  show("#drop");
}

async function useDroppedFile(file) {
  if (!file) return;
  const bytes = new Uint8Array(await file.arrayBuffer());
  if (!DISK_SIZES.includes(bytes.length)) {
    showDrop(`${file.name} is not a .d64 disk image (${bytes.length} bytes).`);
    return;
  }
  engine.disk = bytes;
  engine.diskFromDrop = true;
  hide("#drop");
  await fly();
}

/** Starts the machine (a click or a drop: the browser lets the page start sound then). */
async function fly() {
  hide("#start");
  show("#loading");
  engine.sampleRate = await startAudio();
  applyEngineSettings();
  await startWorker();
  canvas.focus?.();
}

function wireControls() {
  $("#start-button").addEventListener("click", fly);
  $("#pause").addEventListener("click", () => setPaused(!engine.paused));
  $("#restart").addEventListener("click", () => {
    Atomics.add(engine.controls, CONTROL.restart, 1);
    bump(true);
  });
  $("#reset").addEventListener("click", () => {
    hide("#message");
    startWorker();
  });
  $("#demo").addEventListener("click", () => {
    Atomics.add(engine.controls, CONTROL.demo, 1);
    bump(true);
  });
  $("#sound").addEventListener("click", () => {
    settings.sound = !settings.sound;
    applyVolume();
    saveSettings();
  });
  $("#volume").addEventListener("input", (event) => {
    settings.volume = Number(event.target.value) / 100;
    applyVolume();
    saveSettings();
  });
  $("#keys").addEventListener("click", () => $("#reference").showModal());
  $("#about-open").addEventListener("click", () => $("#about").showModal());
  $("#fullscreen").addEventListener("click", async () => {
    try {
      await $("#stage").requestFullscreen();
      await navigator.keyboard?.lock?.();
    } catch {
      // Full screen refused (an iframe without permission): stay as is.
    }
  });
  document.addEventListener("fullscreenchange", () => {
    if (!document.fullscreenElement) navigator.keyboard?.unlock?.();
    layout();
  });
  $("#message-close").addEventListener("click", () => hide("#message"));
  $("#message-reset").addEventListener("click", () => {
    hide("#message");
    startWorker();
  });

  const form = $("#settings form");
  $("#settings-open").addEventListener("click", () => {
    form.elements.pacing.value = settings.pacing;
    form.elements.aspect.value = settings.aspect;
    form.elements.monitor.value = settings.monitor;
    form.elements.keypadJoystick.checked = settings.keypadJoystick;
    form.elements.strictJoystick.checked = settings.strictJoystick;
    $("#settings").showModal();
  });
  form.addEventListener("change", () => {
    settings.pacing = form.elements.pacing.value;
    settings.aspect = form.elements.aspect.value;
    settings.monitor = form.elements.monitor.value;
    settings.keypadJoystick = form.elements.keypadJoystick.checked;
    settings.strictJoystick = form.elements.strictJoystick.checked;
    saveSettings();
    if (engine.controls) applyEngineSettings();
    layout();
  });

  const zone = $("#dropzone");
  for (const type of ["dragenter", "dragover"]) {
    zone.addEventListener(type, (event) => {
      event.preventDefault();
      zone.classList.add("over");
    });
  }
  zone.addEventListener("dragleave", () => zone.classList.remove("over"));
  zone.addEventListener("drop", (event) => {
    event.preventDefault();
    zone.classList.remove("over");
    useDroppedFile(event.dataTransfer.files[0]);
  });
  $("#disk-file").addEventListener("change", (event) => useDroppedFile(event.target.files[0]));
  canvas.tabIndex = 0;
  canvas.addEventListener("pointerdown", () => canvas.focus());
}

// MARK: Start

async function compileEngine() {
  const response = await fetch(WASM_URL);
  if (!response.ok) throw new Error(`${WASM_URL}: ${response.status}`);
  try {
    return await WebAssembly.compileStreaming(response.clone());
  } catch {
    // A server that does not send application/wasm.
    return await WebAssembly.compile(await response.arrayBuffer());
  }
}

async function findDisk() {
  try {
    const response = await fetch(DISK_URL, { cache: "no-cache" });
    if (response.ok) {
      const bytes = new Uint8Array(await response.arrayBuffer());
      if (DISK_SIZES.includes(bytes.length)) return bytes;
    }
  } catch {
    // Not deployed with the page.
  }
  const stored = await storedFile("disk");
  return stored instanceof Uint8Array ? stored : null;
}

async function main() {
  // The service worker (and so the isolation) needs a secure context: plain HTTP goes to HTTPS.
  if (location.protocol === "http:" && !["localhost", "127.0.0.1", "[::1]"].includes(location.hostname)) {
    location.replace(`https://${location.host}${location.pathname}${location.search}${location.hash}`);
    return;
  }
  // For the console: the engine's state (worker, controls, audio ring).
  Object.defineProperty(window, "fs2", { value: engine });
  wireControls();
  applyVolume();
  layout();
  requestAnimationFrame(frameLoop);
  const fineKeyboard = matchMedia("(pointer: fine)").matches;
  if (!fineKeyboard) $("#hint").textContent = "Flight Simulator II needs a keyboard: it is not playable on a touch screen alone.";

  if (!(await ensureIsolation())) {
    hide("#loading");
    showMessage("This browser cannot run the simulator here",
      "It needs SharedArrayBuffer, which this page could not enable (a private window, or service workers blocked). Try a regular window of a current Chrome, Edge, Firefox or Safari.",
      false);
    $("#message-close").hidden = true;
    return;
  }
  engine.controls = new Int32Array(new SharedArrayBuffer(CONTROL.words * 4));
  engine.ring = new SharedArrayBuffer(RING_HEADER_BYTES + RING_SIZE * 4);

  try {
    [engine.module, engine.disk] = await Promise.all([compileEngine(), findDisk()]);
  } catch (error) {
    hide("#loading");
    showMessage("The simulator could not be loaded", String(error.message || error), false);
    return;
  }
  hide("#loading");
  if (engine.disk) show("#start");
  else showDrop();
}

main();
