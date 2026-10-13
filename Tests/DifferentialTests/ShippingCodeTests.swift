import Foundation
import FS2Core
import FS2Data
import Testing

/// The shipping code runs no original 6502 code: the development bridge `callOriginal` is only
/// defined (`Machine.swift`, for the differential rigs), and the two places the disk's data never
/// reaches (an op 0A native call to an unported address, an ATIS hook patched to anything but the
/// composer) stop the program with a fatal error naming the address instead of calling it. The
/// message is kept in optimized builds too (`fatalError`; a `preconditionFailure`'s is dropped
/// there), so these tests pass under `swift test -c release` as well.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"))
struct ShippingCodeTests {
    /// `grep -rn "callOriginal(" Sources` finds only the API definition.
    @Test func noBridgeCallInSources() throws {
        let sources = Original.repoRoot.appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var hits: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (n, line) in lines.enumerated() where line.contains("callOriginal(") {
                hits.append("\(url.path.replacingOccurrences(of: sources.path + "/", with: "")):\(n + 1)")
            }
        }
        #expect(hits.count == 1 && hits.first?.hasPrefix("FS2Core/Machine/Machine.swift:") == true, "\(hits)")
    }

    /// The cold memory (the opcode table at $86A4 loaded) with a display list at $C100.
    static func machine(list: [UInt8]) -> Machine {
        let m = Machine(memory: Original.data!.coldMemory)
        for (k, b) in list.enumerated() { m.mem[0xC100 + k] = b }
        m.setU16(0x8B, 0xC100)
        return m
    }

    /// What the stopped program wrote to standard error.
    static func message(_ result: ExitTest.Result?) -> String {
        String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
    }

    /// Op 0A through a pointer to $1234: no port, no bridge; the program stops.
    @Test func unportedNativeCallStops() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let m = ShippingCodeTests.machine(list: [0x0A, 0x00, 0xC2, 0x79])
            m.setU16(0xC200, 0x1234)
            try? m.dlInterpreter()
        }
        #expect(Self.message(result).contains("op 0A: native call to $1234"), "\(Self.message(result))")
        // The ported targets still run: $80D1 copies four operand bytes and the list goes on.
        let m = Self.machine(list: [0x0A, 0x00, 0xC2, 0x79])
        m.setU16(0xC200, 0x80D1)
        #expect(throws: Never.self) { try m.dlInterpreter() }
    }

    /// Op 1E (a COM record) that matches the tuned frequency, with the ATIS hook $802D patched to
    /// $1234 instead of the composer $F16A: the program stops.
    @Test func foreignAtisHookStops() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            // 1E len, a byte, the frequency (BCD kHz, MHz), 8 parameter bytes, the text.
            var list: [UInt8] = [0x1E, 0x10, 0x00, 0x30, 0x21]
            list += [UInt8](repeating: 0, count: 8) + [0x20, 0x20, 0x79]
            let m = ShippingCodeTests.machine(list: list)
            m.mem[0x0938] = 1                               // the COM search of this pass
            m.mem[0x08B3] = 0x30
            m.mem[0x08B4] = 0x21                            // tuned to 121.30
            m.mem[0x802D] = 0x4C
            m.setU16(0x802E, 0x1234)
            try? m.dlInterpreter()
        }
        #expect(Self.message(result).contains("the ATIS hook $802D jumps to $1234"), "\(Self.message(result))")
    }
}
