/// The database info screen (CTRL-E): overlay 4 (disk block 64) at $A7E0, entry $A86A.
///
/// CTRL-E increments `databaseInfoRequest` `$0E87`; on the next flip pass the main loop clears it
/// and calls slot $A7FA. With the flight overlay resident that slot calls the overlay manager at
/// $2021, which loads overlay 4 over $A7E0 (the scenery unit); the call then returns into the new
/// bytes at $A7FD, where overlay 4 jumps on to $A86A. Overlay 4's own $A7FA slot leads to $A86A
/// too. On the next pass, overlay 4's slot $A7F4 calls $201E, which loads the flight overlay again.
///
/// The screen works on the overlay bytes in memory: the text-record list at $A802 (a heading, the
/// four area names, Chicago, Los Angeles, Seattle and New York, the press-any-key line, then
/// 00 00). Literal translation with exact cycles; the wait for a key ($2003 → $2250) is
/// `waitForKey`.
public enum DatabaseInfo {
    /// $A86A: the screen routine in overlay 4.
    public static let entry: UInt16 = 0xA86A
    /// $A802: the text-record list in overlay 4.
    public static let list: UInt16 = 0xA802
    /// $0E87: CTRL-E increments it; the main loop clears it and calls $A7FA.
    public static let request = 0x0E87
}

extension Machine {
    /// $A86A (overlay 4): clears the window, draws the record list at $A802 and waits for a key
    /// (through $2003). The key is consumed. Clobbers A, X, Y.
    public func databaseInfoScreen() {
        charge(6)
        clearWindow()
        charge(10)                                       // the list address, then the call
        drawTextList(DatabaseInfo.list)
        charge(9)                                        // through the $2003 vector
        waitForKey()
        charge(6)
    }
}
