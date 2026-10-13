/// The overlay manager ($E5C0-$E6D7) and the editor cache swap ($E6D8-$E712).
///
/// One overlay at a time occupies the window at $A7E0; its first word is its end address, where
/// the scenery root list (block 66) is loaded after every overlay load. Loads are direct copies
/// from `Machine.diskBlocks` through `readBlocks`, which reproduces the memory the original
/// loader leaves behind.
extension Machine {
    /// $E559: (first block, count) pairs: cold start, editor, war, flight, database info, root.
    public static let overlayTable = 0xE559
    /// $08BC: the editor cache in RAM under I/O: 0 never loaded, 1 cached at $D000, 2 invalid
    /// (the course plotter used $D000).
    public static let editorCacheState = 0x08BC

    /// The overlays the trampolines load, by their index in the table at $E559.
    public enum Overlay: Int, Sendable, CaseIterable {
        case coldStart = 0, editor, war, flight, databaseInfo
    }

    /// $E5C0/$E5C9/$E5DB/$E5E4/$E5ED (vectors $2015-$2021, the overlay slots' targets): loads an
    /// overlay. The editor ($E5C9) is swapped in from the $D000 cache instead when `$08BC` = 1
    /// (through $E6DB, no root reload).
    public func loadOverlay(_ overlay: Overlay) {
        let m = mem
        let pair = Self.overlayTable + 2 * overlay.rawValue
        if overlay == .editor {
            let state = m[Self.editorCacheState]
            if state &- 1 == 0 {
                charge(11)                       // cached: on to the swap $E6DB
                swapEditorCache()
                return
            }
            charge(9)                               // the cache state test
        }
        charge(11)                                   // the table pair, on to $E5F6
        loadOverlay(first: m[pair], count: m[pair + 1])
    }

    /// $E5F6: reads `count` blocks from `first` to $A7E0; after the editor (the pair at $E55B)
    /// also copies it to the cache at $D000 (`$E6D8`) unless `$08BC` = 2; then `loadRootBlock`.
    public func loadOverlay(first: UInt8, count: UInt8) {
        let m = mem
        m[0x9E] = first
        m[0x9F] = count
        m[Scenery.Loader.destination] = 0xE0
        m[Scenery.Loader.destination + 1] = 0xA7
        charge(27)               // the pair and the destination $A7E0, the call of $E63C
        readBlocks()
        var c = 8                                       // the editor's first block?
        if first != m[Self.overlayTable + 2] {
            c += 3
        } else {
            c += 8                                  // the editor: the cache state test
            if m[Self.editorCacheState] == 2 {
                c += 3
            } else {
                charge(c + 8)                           // not invalid: copy it to the cache
                c = 0
                swapEditorCacheIn()
            }
        }
        charge(c)
        loadRootBlock()
    }

    /// $E618: clears the block cache slots `$0900-$0903` and reads the root block (the pair at
    /// $E563: block 66, 1 block) to the overlay's end address `[$A7E0]` (falls into $E63C). Note
    /// the loader's guard: with the editor resident ($BC6B) the part of the root block from
    /// $C000 on is not stored.
    public func loadRootBlock() {
        let m = mem
        for k in 0..<4 { m[Self.blockCacheSlots + k] = 0 }
        m[0x9E] = m[Self.overlayTable + 10]
        m[0x9F] = m[Self.overlayTable + 11]
        m[Scenery.Loader.destination] = m[0xA7E0]
        m[Scenery.Loader.destination + 1] = m[0xA7E1]
        charge(48)
        readBlocks()
    }

    /// $E6D2 (vector $2039): closes the disk channels after the editor's own block I/O (through the
    /// loader's close $730F; the error path $E6C4 cannot happen with the imported image).
    public func cacheHelper() {
        charge(6)
        loaderClose()
        charge(8)                                       // the error check, the return
    }

    /// $E6D8: copies the overlay window $A7E0-$BCDF to the cache at $D000-$E4FF (`$01` = $30
    /// during the copy, then `$01` = `$4B`).
    public func swapEditorCacheIn() {
        charge(5)                                       // carry clear: copy only
        editorCacheTransfer(swap: false)
    }

    /// $E6DB: exchanges the overlay window $A7E0-$BCDF with the cache at $D000-$E4FF.
    public func swapEditorCache() {
        charge(2)                                           // carry set: exchange
        editorCacheTransfer(swap: true)
    }

    /// $E6DC: with interrupts masked, $15 pages through the pointers `$A5/$A6` ($A7E0) and
    /// `$A7/$A8` ($D000), each page indexed down from 0 through $FF to 1; interrupts unmasked after
    /// (the normal-mode scheduler holds the raster IRQ during the transfer and takes the one the
    /// VIC latched after it).
    private func editorCacheTransfer(swap: Bool) {
        let m = mem
        sei()
        m[0x01] = 0x30
        for page in 0..<0x15 {
            let window = 0xA7E0 + page << 8, cache = 0xD000 + page << 8
            for y in 0..<0x100 {
                let v = m[window + y]
                if swap { m[window + y] = m[cache + y] }
                m[cache + y] = v
            }
        }
        m[0xA5] = 0xE0; m[0xA6] = 0xBC
        m[0xA7] = 0x00; m[0xA8] = 0xE5
        m[0x01] = m[Self.savedCpuPort]
        // Per byte: the copy 23 / the swap 39 cycles (the loop's branch back to $E6F5 crosses a
        // page: 4), +1 for the 224 offsets of each page where the indexed access through `$A5/$A6`
        // crosses a page, -2 for the last branch of each page; per page the two pointer steps, the
        // page count and its branch (4, the same page crossing; -2 on the last page).
        let perPage = 256 * (swap ? 39 : 23) + 224 - 2 + 5 + 5 + 2 + 4
        charge(31 + 0x15 * perPage - 2 + 3 + 3)             // setup, pages, the CPU port restored
        cli()
        charge(8)                                       // interrupts unmasked, the return
    }
}
