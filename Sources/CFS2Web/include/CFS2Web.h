// The web page's side of the WebAssembly build: functions the engine worker (web/engine-worker.js)
// provides to fs2.wasm as imports of module "fs2". Declared only when compiling for WebAssembly.
#ifndef CFS2WEB_H
#define CFS2WEB_H

#include <stdint.h>

#if defined(__wasm__)
#define FS2_IMPORT(name) __attribute__((import_module("fs2"), import_name(#name)))

/// The disk image's size in bytes, and its bytes copied to `dst`.
FS2_IMPORT(disk_size) int32_t fs2_disk_size(void);
FS2_IMPORT(disk_read) void fs2_disk_read(uint8_t *dst);
/// The saved mode library block (CTRL-X): its size (-1 when none), and its bytes copied to `dst`.
FS2_IMPORT(mode_library_size) int32_t fs2_mode_library_size(void);
FS2_IMPORT(mode_library_read) void fs2_mode_library_read(uint8_t *dst);
/// CTRL-Z: the page keeps this block for the next visit.
FS2_IMPORT(mode_library_write) void fs2_mode_library_write(const uint8_t *src, int32_t count);
/// The audio output's sample rate (0: no sound).
FS2_IMPORT(sample_rate) double fs2_sample_rate(void);
/// Nanoseconds of a monotonic clock.
FS2_IMPORT(now_ns) double fs2_now_ns(void);
/// Blocks up to `nanoseconds`, or until the page changes a control.
FS2_IMPORT(wait) void fs2_wait(double nanoseconds);
/// Copies the control block (`count` words) to `dst`, clearing its one-shot fields.
FS2_IMPORT(read_controls) void fs2_read_controls(int32_t *dst, int32_t count);
/// A new picture: `count` palette indices, and whether the black-and-white display was chosen.
FS2_IMPORT(frame) void fs2_frame(const uint8_t *pixels, int32_t count, int32_t monochrome);
/// Free room in the audio ring (samples), and samples appended to it.
FS2_IMPORT(audio_room) int32_t fs2_audio_room(void);
FS2_IMPORT(audio_push) void fs2_audio_push(const float *samples, int32_t count);
/// A message for the page (`kind`: see FS2Web's `PageMessage`), UTF-8 text.
FS2_IMPORT(message) void fs2_message(int32_t kind, const uint8_t *text, int32_t count);

#undef FS2_IMPORT
#endif

#endif
