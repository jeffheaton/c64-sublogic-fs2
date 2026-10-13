# Excluded: modified copies, protection, loader and residue

Copies of the disk are sometimes modified. **Nothing a modified copy adds is reproduced.**
SubLogic's copy protection, its IEC disk loader and its development leftovers are not ported
either. This page is the reference for the shipping audits ([The audits](#the-audits) below):

- no source, asset, rendered title or shipped binary names or shows what a modified copy adds;
- none of the excluded ranges is ported;
- no committed file and no shipped binary holds SubLogic's bytes or a listing of its code.

`re/symbols.json` marks every excluded range as kind `crack`, `protection`, `loader` or
`residue` (table at the end). The listing prints them as `NOT PORTED` banners and never dumps
them.

## What modified copies add

This page describes the additions without reproducing their text.

| What | Where | Treatment |
|---|---|---|
| A KERNAL boot loader with a banner and border flashing | Track 18 sector 2 (outside the logical block map) | Never read. The port boots from SubLogic's stage-2 handoff (`Machine.bootMemory`, `main-loop.md`). |
| Other text in a title record (y=28, x=8, 31 characters) | $A839-$A85A (overlay 0) | The import scrub blanks the text bytes $A83B-$A859 to spaces and keeps the record, so the list structure is unchanged. The row stays blank. |
| Other text in a second title record (y=36, x=7, 32 characters) | $A85B-$A87D (overlay 0) | Text bytes $A85D-$A87C blanked. The row stays blank. |
| A 3-letter tag before and after the disk-error text | $0E91-$0E93 and $0EAF-$0EB1 | Restored to spaces. |

The original text of the two title records is not on such a copy (`open-questions.md`).
`FS2Data.ColdImage` holds the scrub ranges and blanks each one only when its bytes are those of
the known modification, so an unmodified disk keeps its own text. The scrub runs on the cold
image, on overlay 0, and in the cold start at $A970 after the boot loads have brought the tagged
line back (`ColdStart.swift`, as `Lab.boot` does at the same point).

## SubLogic copy protection

A drive-status check (copy protection) and the init stubs; not ported.

| Part | Range | In the port |
|---|---|---|
| Drive-status check | $7835-$7897 (entry `$7848`, called by the stage-2 boot) | Not ported. |
| Its mismatch counter | `$7326` | The stage-2 handoff the port and the lab start from has it at 0 (the check passed). |
| Delayed check | $E56F-$E58C, part of `$E565`, which runs every main-loop pass | Not ported. It acts only when `$7326` is not 0. |
| Init stubs | $AAF7-$AAF9 (overlay 0) | Not ported; the port charges their cycles. |

**Port:** `setSceneryRoot` ($E565-$E56E) sets `$8B/$8C = [$A7E0]` and charges the cycles of the
delayed check's first test; the check, the counter and the delayed check do not exist in the port.

## SubLogic's disk loader

| Part | Range | In the port |
|---|---|---|
| Stage-2 IEC block loader and API | $7300-$7834: `$7303` fatal, `$7306` open, `$7309` read, `$730C` write, `$730F` close, `$7312` DOS command; sector mask `$7473` | **Not ported.** The lab runs it against its virtual 1541 (`IECDrive`). The port copies blocks from `Machine.diskBlocks` and leaves the memory the loader leaves, at the loader's measured time (`Scenery.Loader`: `loaderOpen`, `loaderRead`, `loaderClose`; the editor's `loaderDosCommand`, `loaderWriteBlock`; `scenery-3d.md`, `editor.md`). Two hooks in this range lead to game code that **is** ported: `$732E` → `$796C` text mode (the editor, via `$203F` → `$2673`) and `$7331` → `$794E` color RAM fill (display init `$25EB`). |
| Boot entry and table | $7898-$7909 | **Not ported.** `Machine.bootMemory` builds the state stage 2 leaves at its jump to $A7E2. |
| Disk glue | $E618-$E6D7: root-block load, synchronous reads with retries, sprites off, border flashing ($E681) | Ported (kind `code`): `loadRootBlock`, `readBlocks` (the border counter, the sprites, `$08DA`, the interrupt window), `cacheHelper`. The retry path $E6A6 and the fatal error $E6C4 are unreachable (the port's reads cannot fail) and not ported. |
| Editor cache swap | $E6D8-$E712 | Ported: `swapEditorCacheIn`, `swapEditorCache` (`Game/Overlays.swift`), with the cache in RAM under I/O at $D000-$E4FF as in the original. |
| Disk-error prompt | $5F77-$5FF0 (text and code) | Not ported: unreachable, since a block read cannot fail. `restoreGraphics` $5F40 is ported. |
| SYSTEM ERROR screen | $790B-$794D | Not ported. Its only cause in the game, an invalid display-list opcode, makes the port throw `Scenery.Fault`; the engine ends and the app reports it. The rest of that code block, `$794E` color RAM fill and `$796C`-$79A8 text-mode setup, is game code and is ported. |

## Development and build residue

| What | Range | Notes |
|---|---|---|
| Remote debug monitor | $C000-$C7CF (now kind `buffer`, `debugMonitor`) | Never called. It installs IRQ/BRK $C79A, uses expansion-port I/O $DE03/$DE06/$DE09, and has a 14-entry command table $C22B. $C02D-$C12B is a stale copy of panel color bytes. Its code is not ported, but the area is a live **buffer**: the instrument-mask code saves panel pixels there ($C000-$C7D3, with `instrumentSaveTail` $C7D0-$C7D3). Streamed scenery never lands there (the loader's $C000 guard, `scenery-3d.md`). The port reproduces every write there (memory-faithful). |
| Junk | $C7D4-$C7FF, $A7DD-$A7DF, $FFF1-$FFF9 | |
| Linker export table | $7B00-$7B99 | About 70 words naming the $0F00-$1EAF library entry points, then $7A00. Never executed; useful only as a cross-check of symbol names. |
| Stage-3 tail | $ABBB-$ABFF (overlay 0) | Editor text bytes |
| Editor duplicate | $AD00-$B3DF (overlay 0) | 1759 of 1760 bytes equal the editor overlay (it is not game code). $AD00 is where the root block lands during init. |
| Root block tail | Block 66 offsets $88-$3FF ($A888-$ABFF in flight) | New England VOR/op-1D records that are never executed. The area lists stream in over them. |
| Block 65 tail | Block 65 after $A800 | 'WAR !!!!', AMMO and HITS strings copied from the war overlay; overwritten by block 66 |
| Text-screen residue | $03F8-$07FF disk content | A screen-code message the game never draws. The VIC shows it only during the boot's disk loads, while the text screen at $0400 is still on (`engine.md`, Boot): the app skips those frames (`skipDiskLoading`), and so does a headless run with `--quick-boot`. The area itself is the runtime vertex cache. |
| Orphan blocks | 77 (identical to 79), 99 | Valid-looking display lists that no op 0D references |
| Empty blocks | 5, 67, 88, 91, 101, 108, 111, 130-149, 161-163 | All zero |

## Not residue, but documented as a no-op

`$FD00` is the war-mode hook. R sets `$08D7`, and in Europe 1917 the main loop then calls
`$FD00` (from $20C0). On the disk $F9F9-$FFF0 is zero, and nothing on the disk writes $FDxx.
Either code is missing there or it is a latent bug. The call executes uninitialized memory: a
chain of 377 break interrupts (each one entering the IRQ handler through $FFFE, advancing the
frame counters) that runs on into the $FF80-$FFDF save buffer, whose contents depend on earlier
lights-off/on cycles at night, and ends at $FFF2, whose residue bytes happen to decode as a call
to $20D5 (`re/sessions/war-hook.txt`). That is undefined behavior, not part of the game's design.
**Decision:** the port treats the call to `$FD00` as a no-op (the call and an immediate return
are charged; `mainLoopPass`). This is a documented deviation; revisit if an image of an
unmodified original disk turns up (`open-questions.md`).

## The audits

`make audit` builds the app (`make app`) and runs `CrackExclusionTests` and
`SubLogicBytesAuditTests` with `FS2_AUDIT_BINARY` naming its binary; without the variable (as in
`make test`) they scan the repository only. `ShippingCodeTests` runs with the other tests. The
audits read the disk at test time and are skipped without it; none of them writes the text a
modified copy adds, SubLogic's bytes or a listing of its code.

| Suite | What |
|---|---|
| `CrackExclusionTests` | The scrub covers every byte of the known modifications (the cold image, overlay 0, the stage-2 handoff, the title after a RUN/STOP + RESTORE restart); no file in `Sources/`, `Tests/`, `Packaging/`, `Scripts/`, the sessions, the top-level files or the shipped binary names the text a modified copy adds (the two title records, any word of six letters or more from them, or the tag); the native title frame shows nothing in the two rows. |
| `SubLogicBytesAuditTests` | No repository file and no part of the shipped binary has a run of 12 or more of the disk's bytes, raw or written as hex, decimal or binary byte lists, 16- to 64-bit hex words, hex strings or base64 (runs of fill bytes, counting sequences and the 1541's status line are not content). Quoted screen text is allowed in the notes under `re/`. Elsewhere only the short on-screen labels in the test's `allowedLabels` may be quoted (the two title prompts, the course plotter's heading, three editor fields): each at most 40 characters of printable text, on the disk, listed with where it appears in the game. A quoted run passes only when, without the spaces and NULs at its ends, it lies inside one quoted label, so a longer text, a label run on into more of the game's text, and any data still fail. |
| Instruction listings (in `SubLogicBytesAuditTests`) | No file quotes the original's code: every run of 6502 instructions written out in a file (comments, notes, data) is assembled, and the test fails when 12 or more of the resulting bytes occur in one piece on the disk. Comments describe behavior in prose (`porting-guide.md`). |
| `ShippingCodeTests` | No `callOriginal` call in `Sources/`; the two unreachable display-list cases stop the program with an error naming the address. |

`make app` itself checks that the shipped binary links no lab code (`nm`, `strings`, `otool`).

## All excluded regions in symbols.json

Generated by `python3 re/tools/region_tables.py`.

<!-- generated:excluded-regions:begin -->
| Kind | Range | Overlay | Name | Bytes | What |
|---|---|---|---|---|---|
| residue | $7B00-$7B99 | resident | `linkerExportTable` | 154 | Development residue: linker/export address table (about 70 words naming entry points and tables of the $0F00-$1EAF instrument/math library, then $7A00). Never executed; useful as a symbol cross-check. |
| residue | $A7DD-$A7DF | resident | `residueA7DD` | 3 | Three stray bytes at the end of the $77E0 load. |
| residue | $C7D4-$C7FF | resident | `residueC7D4` | 44 | Junk bytes. |
| residue | $FFF1-$FFF9 | resident | `residueFFF1` | 9 | Stray non-zero bytes below the vectors. |
| residue | $ABBB-$ABFF | coldStart | `stage3TailResidue` | 69 | Build residue: editor overlay text bytes left in the stage-3 image. |
| residue | $AD00-$B3DF | coldStart | `editorDuplicateResidue` | 1760 | Build residue: 1759 of 1760 bytes equal the editor overlay at the same addresses. $AD00 is where the root block lands during init; area data overwrites the rest in flight. |
| residue | $A888-$ABFF | flight | `rootBlockResidue` | 888 | Dead tail of block 66 (New England VOR/op-1D records). Area lists load at $A887 and overwrite it; never executed. (Block 65's own bytes after $A800 are war-overlay residue, also overwritten.) |
| crack | $0E91-$0E93 | resident | `diskErrorTagLeft` | 3 | Three bytes before '** DISK READ/WRITE ERROR **' that are spaces in the original and are overwritten in modified copies. The import restores the spaces. |
| crack | $0EAF-$0EB1 | resident | `diskErrorTagRight` | 3 | Three bytes after the disk-error text, restored as spaces like diskErrorTagLeft. |
| crack | $A839-$A85A | coldStart | `titleCrackRecord1` | 34 | A title record (y=28, x=8, 31 characters) whose original text is not on the disk; modified copies carry other text here. The import blanks the text bytes $A83B-$A859 and keeps the record structure. |
| crack | $A85B-$A87D | coldStart | `titleCrackRecord2` | 35 | A title record (y=36, x=7, 32 characters) like titleCrackRecord1; the import blanks its text bytes $A85D-$A87C. |
| loader | $7300-$7834 | resident | `stage2Loader` | 1333 | SubLogic stage-2 IEC block loader (blocks 0-1) with its API at $7300-$7314 ($7303 fatal error, $7306 open, $7309 read, $730C write, $730F close, $7312 DOS command), sector mask $7473. The lab runs it against its virtual 1541 (IECDrive). The port copies blocks from the imported disk instead and leaves the memory this loader leaves (Scenery.Loader: loaderOpen, loaderRead, loaderClose; the editor's loaderDosCommand and loaderWriteBlock) and charges its time. Exception: the hooks $732E (text mode -> $796C, used by the editor via $2673) and $7331 (color RAM fill -> $794E, used by $25EB) lead to game routines, which are ported. |
| loader | $7898-$7909 | resident | `stage2Boot` | 114 | Loader overlay table copy $7898 and the stage-2 boot entry $78A2 (loads stage 3, runs the drive-status check, enters the cold-start slot $A7E2). |
| protection | $7835-$7897 | resident | `driveStatusCheck` | 99 | A drive-status check (copy protection). Not ported. |
| protection | $E56F-$E58C | resident | `tamperHang` | 30 | Part of the drive-status check (copy protection). Not ported. |
| protection | $AAF7-$AAF9 | coldStart | `protectionStubs` | 3 | Two stubs in the init chain (probably copy protection). Not ported; their cycles are charged. |
<!-- generated:excluded-regions:end -->
