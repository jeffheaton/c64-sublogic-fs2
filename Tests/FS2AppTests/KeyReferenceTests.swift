import C64Kit
import FS2Core
import FS2Data
@testable import FS2App
import Foundation
import Testing

/// The keyboard reference (Machine ▸ Keyboard Reference, ⌘/, and README.md's controls tables)
/// against `KeyMapper`, exactly, and against the functions of re/docs/input.md and editor.md.
@Suite struct KeyReferenceTests {
    private func section(_ title: String) -> KeyReference.Section {
        KeyReference.sections().first { $0.title == title } ?? KeyReference.Section(title: title, rows: [])
    }

    /// The input.md command map, transcribed: every code $00-$5F with a handler other than the RTS
    /// at $2CC1.
    static let documentedCommandCodes: Set<UInt8> = [
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x08, 0x09, 0x0C, 0x0D, 0x0E, 0x10, 0x14, 0x15, 0x16, 0x18, 0x1B,
        0x20, 0x2B, 0x2C, 0x2E, 0x2F, 0x31, 0x32, 0x33, 0x34, 0x35, 0x38, 0x39, 0x41, 0x42, 0x43, 0x45, 0x46,
        0x47, 0x48, 0x4C, 0x4D, 0x4E, 0x50, 0x51, 0x52, 0x53, 0x54, 0x56, 0x57, 0x58, 0x59, 0x5A,
    ]

    /// The codes editor.md's key table handles.
    static let documentedEditorCodes: Set<UInt8> =
        Set([0x0D, 0x2D, 0x45, 0x08, 0x2B, 0x53, 0x18, 0x1A] + Array(UInt8(0x30)...0x39))

    /// The Keyboard section is `KeyMapper.bindings` without the keypad joysticks, in order, with
    /// the same Mac and C64 labels; the keypad section is the joystick bindings. Nothing else.
    @Test func matchesKeyMapperExactly() {
        let keyboard = section(KeyReference.SectionTitle.keyboard).rows
        let plain = KeyMapper.bindings.filter { $0.joystick == nil }
        #expect(keyboard.map(\.mac) == plain.map(\.mac.label))
        #expect(keyboard.map(\.c64) == plain.map(\.c64Label))

        let keypad = section(KeyReference.SectionTitle.keypad).rows
        let joysticks = KeyMapper.bindings.filter { $0.joystick != nil }
        #expect(keypad.map(\.mac) == joysticks.map(\.mac.label))
        #expect(keypad.map(\.c64) == joysticks.map { KeyReference.joystickLabel($0.joystick!) })
        for (row, b) in zip(keypad, joysticks) {
            #expect(row.function.hasSuffix("(keypad-as-joystick off: \(b.c64Label))"), "\(row.mac)")
        }

        // Every Control row is a mapped Mac key whose C64 key is the one named, with CTRL (which
        // both Mac Control keys give).
        #expect(KeyMapper.binding(forKeyCode: MacKeyCode.control.rawValue)?.c64 == [.control])
        #expect(KeyMapper.binding(forKeyCode: MacKeyCode.rightControl.rawValue)?.c64 == [.control])
        for row in section(KeyReference.SectionTitle.control).rows {
            #expect(row.mac.hasPrefix("Control-"))
            let macLabel = String(row.mac.dropFirst("Control-".count))
            let b = KeyMapper.bindings.first { $0.mac.label == macLabel && $0.joystick == nil }
            let key = b.flatMap(KeyReference.effectiveKey(of:))
            #expect(key != nil && row.c64 == "CTRL + " + (key?.label ?? "?"), "\(row.mac)")
            #expect(key.flatMap(KeyReference.controlCode(of:)) == row.code, "\(row.mac)")
        }

        // The documented exceptions only.
        #expect(section(KeyReference.SectionTitle.unmapped).rows.map(\.c64) == [C64Key.leftShift.label])
    }

    /// Every command code a Mac key reaches (alone, or with Control held) appears in the reference,
    /// in the row of that very Mac key, with the documented function.
    @Test func everyReachableCommandIsInTheReference() {
        let keyboard = section(KeyReference.SectionTitle.keyboard).rows
        let control = section(KeyReference.SectionTitle.control).rows
        var reached: Set<UInt8> = []
        for b in KeyMapper.bindings {
            guard let key = KeyReference.effectiveKey(of: b) else { continue }
            if let c = KeyReference.code(of: key), Self.documentedCommandCodes.contains(c) {
                reached.insert(c)
                if b.joystick == nil {
                    let row = keyboard.first { $0.mac == b.mac.label }
                    #expect(row?.code == c, "\(b.mac.label)")
                    #expect(row?.function.contains(KeyReference.flightFunctions[c] ?? "?") == true, "\(b.mac.label)")
                }
            }
            if let c = KeyReference.controlCode(of: key), b.joystick == nil,
               Self.documentedCommandCodes.contains(c) || Self.documentedEditorCodes.contains(c) {
                reached.insert(c)
                let row = control.first { $0.mac == "Control-" + b.mac.label }
                #expect(row?.code == c, "Control-\(b.mac.label)")
                #expect(row?.function == KeyReference.describe(code: c), "Control-\(b.mac.label)")
            }
        }
        // And every documented function is reachable from the Mac keyboard.
        #expect(Self.documentedCommandCodes.subtracting(reached).isEmpty,
                "unreachable: \(Self.documentedCommandCodes.subtracting(reached).sorted())")
        let rowCodes = Set((keyboard + control).compactMap(\.code))
        #expect(Self.documentedCommandCodes.isSubset(of: rowCodes))
    }

    /// The reference documents exactly input.md's command map and editor.md's keys.
    @Test func functionsAreTheDocumentedOnes() {
        #expect(Set(KeyReference.flightFunctions.keys) == Self.documentedCommandCodes)
        #expect(Set(KeyReference.editorFunctions.keys) == Self.documentedEditorCodes)
        for (code, text) in KeyReference.flightFunctions {
            #expect(!text.isEmpty && !text.hasSuffix("."), "\(code)")
        }
        // Codes with the same handler share the text: A and CTRL-A, L and CTRL-L, P, CTRL-P and RUN/STOP,
        // E and HOME, the throttle-down keys.
        #expect(KeyReference.flightFunctions[0x01] == KeyReference.flightFunctions[0x41])
        #expect(KeyReference.flightFunctions[0x0C] == KeyReference.flightFunctions[0x4C])
        #expect(KeyReference.flightFunctions[0x10] == KeyReference.flightFunctions[0x50])
        #expect(KeyReference.flightFunctions[0x1B] == KeyReference.flightFunctions[0x45])
        #expect(KeyReference.function(of: .colon) == KeyReference.function(of: .instDel))
        #expect(KeyReference.function(of: .leftArrow) == KeyReference.function(of: .instDel))
        #expect(KeyReference.function(of: .runStop) == KeyReference.function(of: .p))
        // Dead keys say so; CTRL with a digit is dropped.
        for key in [C64Key.f1, .f7, .at, .pound, .asterisk, .equals, .commodore, .cursorRight, .d, .u] {
            #expect(KeyReference.function(of: key) == KeyReference.noFunction, "\(key.label)")
        }
        #expect(KeyReference.controlCode(of: .digit1) == nil && KeyReference.controlCode(of: .space) == nil)
        #expect(KeyReference.controlCode(of: .a) == 0x01 && KeyReference.controlCode(of: .z) == 0x1A)
        #expect(KeyReference.controlCode(of: .runStop) == 0x10)
    }

    /// The editor's codes are the ones the ported editor acts on (`Editor.Key`, proved against the
    /// original by the editor's differential tests), plus the digits it types.
    @Test func editorFunctionsAreThePortedEditorsKeys() {
        let ported: Set<UInt8> = [Editor.Key.nextLine, Editor.Key.previousLine, Editor.Key.exit, Editor.Key.backspace,
                                  Editor.Key.recall, Editor.Key.save, Editor.Key.libraryLoad, Editor.Key.librarySave]
        #expect(Set(KeyReference.editorFunctions.keys) == ported.union(UInt8(0x30)...0x39))
        #expect(Self.documentedEditorCodes == ported.union(UInt8(0x30)...0x39))
        // The library keys are Control combinations in the reference.
        let control = section(KeyReference.SectionTitle.control).rows
        #expect(control.first { $0.code == Editor.Key.libraryLoad }?.mac == "Control-X")
        #expect(control.first { $0.code == Editor.Key.librarySave }?.mac == "Control-Z")
    }

    /// In slew the throttle keys step the altitude rate (input.md, "Slew mode"); every key that
    /// reaches the throttle handlers says so.
    @Test func throttleKeysNameTheSlewAltitudeRate() {
        for key in [C64Key.semicolon, .colon, .instDel, .leftArrow] {
            #expect(KeyReference.function(of: key).contains("Slew: altitude rate"), "\(key.label)")
        }
        #expect(KeyReference.controlSection().rows.first { $0.mac == "Control-U" }?.function
                .contains("Slew: altitude rate up") == true)
    }

    /// Letters and digits give their ASCII codes (input.md: "Letters and digits give their ASCII codes").
    @Test func lettersAndDigitsAreASCII() {
        for key in C64Key.allCases {
            let label = key.label
            if label.count == 1, let ascii = label.unicodeScalars.first, ascii.isASCII,
               ("A"..."Z").contains(label) || ("0"..."9").contains(label) {
                #expect(KeyReference.code(of: key) == UInt8(ascii.value), "\(label)")
            }
        }
    }

    /// The names the help uses for keys that differ between the Mac and the C64.
    @Test func macNamesComeFromTheMapper() {
        #expect(KeyReference.macName(for: .colon) == "'")
        #expect(KeyReference.macName(for: .plus) == "=")
        #expect(KeyReference.macName(for: .runStop) == "Esc")
        #expect(KeyReference.macName(for: .clrHome) == "Home")
        #expect(KeyReference.macName(for: .instDel) == "Delete")
        for key in [C64Key.colon, .plus, .runStop, .clrHome, .instDel] {
            let name = KeyReference.macName(for: key)
            #expect(KeyMapper.bindings.contains { $0.mac.label.hasPrefix(name) && $0.c64 == [key] }, "\(key.label)")
        }
    }

    /// README.md carries the tables `FS2 --key-reference` prints, so it never drifts from the mapper.
    /// After changing `KeyMapper` or `KeyReference`, paste `.build/debug/FS2 --key-reference` over the
    /// marked block.
    @Test func readmeHasTheGeneratedTables() throws {
        let readme = try String(contentsOf: Self.repositoryRoot.appendingPathComponent("README.md"), encoding: .utf8)
        #expect(readme.contains(KeyReference.markdown()),
                "README.md's keyboard tables are stale: replace the block between the markers with `FS2 --key-reference`")
    }

    @Test func markdownIsWellFormed() {
        #expect(KeyReference.markdownCode("`") == "`` ` ``")
        #expect(KeyReference.markdownCode("\\") == "`\\`")
        #expect(KeyReference.markdownText("a|b*c") == "a\\|b\\*c")
        let md = KeyReference.markdown()
        #expect(md.hasPrefix(KeyReference.markdownBegin) && md.hasSuffix(KeyReference.markdownEnd))
        for line in md.split(separator: "\n") where line.hasPrefix("|") {
            // Three cells: four unescaped pipes.
            var pipes = 0
            var previous: Character = " "
            for ch in line {
                if ch == "|" && previous != "\\" { pipes += 1 }
                previous = ch
            }
            #expect(pipes == 4, "\(line)")
        }
        // One table row per reference row.
        let rows = KeyReference.sections().reduce(0) { $0 + $1.rows.count }
        let tableLines = md.split(separator: "\n").filter { $0.hasPrefix("| `") }
        #expect(tableLines.count == rows)
    }

    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}

/// The reference against the original program's own tables on the user's disk: the code table
/// $2482 (matrix position → command code) and the dispatch table $2718 (code → handler).
@Suite(.enabled(if: TestDisk.data != nil, "needs the Flight Simulator II disk image"))
struct KeyReferenceDiskTests {
    private let memory = TestDisk.data?.coldMemory ?? []

    private func diskCode(_ key: C64Key) -> UInt8 { memory[Input.Table.keyCodeTable + key.rawValue] }

    private func handler(_ code: UInt8) -> UInt16 {
        let p = Input.Table.keyDispatchTable + 2 * Int(code)
        return UInt16(memory[p]) | UInt16(memory[p + 1]) << 8
    }

    /// `KeyReference.code(of:)` is the code table: equal for every live key, nil exactly where the
    /// original's code is $80 or more (never queued).
    @Test func codeTableMatchesTheOriginal() {
        for key in C64Key.allCases {
            let c = diskCode(key)
            #expect(KeyReference.code(of: key) == (c < 0x80 ? c : nil), "\(key.label): disk $\(String(c, radix: 16))")
        }
        #expect(diskCode(.control) == Input.ctrlCode)
    }

    /// The flight functions are exactly the codes $00-$5F whose handler is not the RTS at $2CC1.
    @Test func flightFunctionsAreTheOriginalsHandlers() {
        let handled = Set((0..<0x60).map(UInt8.init).filter { handler($0) != Input.Handler.keyIgnored })
        let documented = Set(KeyReference.flightFunctions.keys)
        let missing = handled.subtracting(documented).sorted(), extra = documented.subtracting(handled).sorted()
        #expect(documented == handled, "missing: \(missing), extra: \(extra)")
        // Codes sharing a handler share a description.
        for a in handled {
            for b in handled where a < b && handler(a) == handler(b) {
                #expect(KeyReference.flightFunctions[a] == KeyReference.flightFunctions[b], "$\(a) / $\(b)")
            }
        }
    }

    /// Every dispatch code reachable from the Mac keyboard, worked out from the disk's tables the way
    /// the original's scan and `requeueKey` do (CTRL subtracts $40; codes of $80 and up are never
    /// queued; the dispatcher drops $60 and up), appears in the reference when its handler does
    /// something, in the row of the Mac key (or Control combination) that produces it.
    @Test func everyDispatchCodeReachableFromTheKeyboardIsInTheReference() {
        let sections = KeyReference.sections()
        let keyboard = sections.first { $0.title == KeyReference.SectionTitle.keyboard }!.rows
        let control = sections.first { $0.title == KeyReference.SectionTitle.control }!.rows
        let controlIsMapped = KeyMapper.reachableC64Keys.contains(.control)
        var reached: Set<UInt8> = []
        for b in KeyMapper.bindings {
            // RIGHT SHIFT in a chord queues nothing (its code is dead).
            #expect(diskCode(.rightShift) >= 0x80)
            for key in b.c64 {
                let c = diskCode(key)
                guard c < 0x80 else { continue }
                if c < 0x60, handler(c) != Input.Handler.keyIgnored {
                    reached.insert(c)
                    guard b.joystick == nil else { continue }   // typed only with keypad-as-joystick off
                    let row = keyboard.first { $0.mac == b.mac.label }
                    #expect(row?.code == c, "\(b.mac.label)")
                    #expect(row?.function.contains(KeyReference.flightFunctions[c] ?? "?") == true, "\(b.mac.label)")
                }
                let withControl = c &- 0x40
                if controlIsMapped, withControl < 0x60, handler(withControl) != Input.Handler.keyIgnored {
                    reached.insert(withControl)
                    guard b.joystick == nil else { continue }
                    let row = control.first { $0.mac == "Control-" + b.mac.label }
                    #expect(row?.code == withControl, "Control-\(b.mac.label)")
                    #expect(row?.function.contains(KeyReference.flightFunctions[withControl] ?? "?") == true,
                            "Control-\(b.mac.label)")
                }
            }
        }
        // Nothing the program can do is out of reach of the Mac keyboard.
        let handled = Set((0..<0x60).map(UInt8.init).filter { handler($0) != Input.Handler.keyIgnored })
        #expect(handled == reached, "not reachable: \(handled.subtracting(reached).sorted())")
    }
}
