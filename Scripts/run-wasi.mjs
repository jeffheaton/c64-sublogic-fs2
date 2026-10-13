#!/usr/bin/env node
// Runs a WASI command (a .wasm built with the wasm Swift SDK) under Node's V8, the engine and
// default stack size of Chrome, with standard input and output passed through (`make web-check`).
//
//     node Scripts/run-wasi.mjs program.wasm [arguments...]

import { readFileSync } from "node:fs";
import { WASI } from "node:wasi";

const [file, ...args] = process.argv.slice(2);
const wasi = new WASI({ version: "preview1", args: [file, ...args], env: {}, returnOnExit: true });
const module = await WebAssembly.compile(readFileSync(file));
const instance = await WebAssembly.instantiate(module, wasi.getImportObject());
process.exitCode = wasi.start(instance);
