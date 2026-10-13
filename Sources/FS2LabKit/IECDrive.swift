import C64Kit

/// A virtual 1541 on the IEC serial bus, implementing the bus handshakes at the signal level so
/// SubLogic's own serial routines ($7686-$7834) run unmodified, with all their zero-page and
/// CIA side effects. The drive reacts to the C64's line changes and answers on a cycle timeline.
/// It understands the commands Flight Simulator II uses: I, U1/U2 (block read/write),
/// B-P, N (format), OPEN "#" (direct-access buffer) and the status channel.
final class IECDrive {
    let device: UInt8 = 8
    var disk: [UInt8]   // .d64 bytes (writes go here)

    // Lines asserted (pulled low) by the C64 and by the drive.
    private(set) var c64ATN = false, c64CLK = false, c64DATA = false
    private(set) var driveCLK = false, driveDATA = false
    private var scheduled: [(cycle: UInt64, clk: Bool?, data: Bool?, action: (() -> Void)?)] = []

    // Byte reception (drive as listener).
    private enum ListenState { case idle, waitTalkerReady, readyForData(since: UInt64), bits(count: Int, value: UInt8) }
    private var listen = ListenState.idle
    private var eoiSeen = false

    // Roles.
    private var listening = false
    private var talking = false
    private var underATN = false
    private var secondary: UInt8 = 0       // last SECOND/TKSA byte
    private var openName: [UInt8] = []
    private var commandBuffer: [UInt8] = []

    // Talker output.
    private var talkQueue: [UInt8] = []
    private var talkIndex = 0
    private enum TalkState { case idle, waitListenerReady, sending, waitFrameAck }
    private var talk = TalkState.idle

    // Channels.
    private var buffer = [UInt8](repeating: 0, count: 256)
    private var bufferPointer = 0
    private var bufferChannelOpen = false
    private var status = "00, OK,00,00"

    init(disk: [UInt8]) { self.disk = disk }

    /// Debug trace of bus activity (set FS2LAB_IECTRACE=1).
    var trace: ((String) -> Void)?

    // MARK: Bus interface

    /// Lines as the drive currently drives them, after applying scheduled events up to `now`.
    func lines(at now: UInt64) -> (clk: Bool, data: Bool) {
        runSchedule(until: now)
        return (driveCLK, driveDATA)
    }

    /// The C64 changed its outputs ($DD00 write).
    func c64Lines(atn: Bool, clk: Bool, data: Bool, at now: UInt64) {
        runSchedule(until: now)
        let atnEdge = atn != c64ATN, clkReleased = c64CLK && !clk, clkAsserted = !c64CLK && clk
        let dataReleased = c64DATA && !data, dataAsserted = !c64DATA && data
        c64ATN = atn; c64CLK = clk; c64DATA = data
        trace?("\(now) c64 atn=\(atn ? 1 : 0) clk=\(clk ? 1 : 0) data=\(data ? 1 : 0) | drive clk=\(driveCLK ? 1 : 0) data=\(driveDATA ? 1 : 0) listen=\(listen) talk=\(talk) L=\(listening) T=\(talking)")

        if atnEdge {
            if atn { attention(at: now) } else { attentionReleased(at: now) }
            return
        }
        if listening || underATN { listenerEdge(clkReleased: clkReleased, clkAsserted: clkAsserted, at: now) }
        if talking && !underATN { talkerEdge(dataReleased: dataReleased, dataAsserted: dataAsserted, at: now) }
    }

    private func schedule(_ cycle: UInt64, clk: Bool? = nil, data: Bool? = nil, _ action: (() -> Void)? = nil) {
        scheduled.append((cycle, clk, data, action))
        scheduled.sort { $0.cycle < $1.cycle }
    }

    private func runSchedule(until now: UInt64) {
        while let first = scheduled.first, first.cycle <= now {
            scheduled.removeFirst()
            if let c = first.clk { driveCLK = c }
            if let d = first.data { driveDATA = d }
            first.action?()
        }
    }

    // MARK: ATN

    private func attention(at now: UInt64) {
        scheduled.removeAll()
        underATN = true
        talk = .idle
        driveCLK = false
        // Every device answers ATN by pulling DATA.
        schedule(now + 20, data: true)
        listen = .waitTalkerReady
        eoiSeen = false
    }

    private func attentionReleased(at now: UInt64) {
        underATN = false
        if talking {
            // Turnaround: once the C64 holds DATA and releases CLK, the drive takes over CLK.
            listen = .idle
            talk = .idle
            schedule(now + 30) { [weak self] in self?.startTurnaround(at: now + 30) }
        } else if listening {
            listen = .waitTalkerReady
            schedule(now + 10, data: true)
        } else {
            listen = .idle
            schedule(now + 10, clk: false, data: false)
        }
    }

    private func startTurnaround(at now: UInt64) {
        // Wait (by polling the schedule) until the C64 released CLK, then become talker.
        if c64CLK {
            schedule(now + 20) { [weak self] in self?.startTurnaround(at: now + 20) }
            return
        }
        driveDATA = false
        driveCLK = true
        talkIndex = 0
        prepareTalkQueue()
        talk = .idle
        schedule(now + 60, clk: false) { [weak self] in self?.talk = .waitListenerReady }
    }

    // MARK: Listener

    private func listenerEdge(clkReleased: Bool, clkAsserted: Bool, at now: UInt64) {
        switch listen {
        case .waitTalkerReady:
            if clkReleased {
                // Ready for data: release DATA; if the talker then waits > 200 µs it signals EOI.
                driveDATA = false
                listen = .readyForData(since: now)
                schedule(now + 210, data: true) { [weak self] in self?.eoiSeen = true }
                schedule(now + 270, data: false)
            }
        case .readyForData:
            if clkAsserted {
                scheduled.removeAll { $0.cycle > now }
                driveDATA = false
                listen = .bits(count: 0, value: 0)
            }
        case .bits(let count, let value):
            if clkReleased {
                // Data valid: released DATA line = 1.
                let bit: UInt8 = c64DATA ? 0 : 1
                let v = value | bit << UInt8(count)
                if count == 7 {
                    listen = .bits(count: 8, value: v)
                } else {
                    listen = .bits(count: count + 1, value: v)
                }
            } else if clkAsserted, count == 8 {
                // Frame handshake: acknowledge by pulling DATA.
                schedule(now + 15, data: true)
                listen = .waitTalkerReady
                let eoi = eoiSeen
                eoiSeen = false
                received(value, eoi: eoi, at: now)
            }
        case .idle:
            break
        }
    }

    private func received(_ byte: UInt8, eoi: Bool, at now: UInt64) {
        trace?(String(format: "%llu RECEIVED $%02X eoi=%d atn=%d", now, byte, eoi ? 1 : 0, underATN ? 1 : 0))
        if underATN {
            command(byte, at: now)
            return
        }
        guard listening else { return }
        switch secondary & 0xF0 {
        case 0xF0: openName.append(byte)
        case 0x60:
            if secondary & 0x0F == 15 {
                commandBuffer.append(byte)
            } else if secondary & 0x0F == 2, bufferChannelOpen {
                buffer[bufferPointer & 0xFF] = byte
                bufferPointer = (bufferPointer + 1) & 0xFF
            }
        default: break
        }
    }

    private func command(_ byte: UInt8, at now: UInt64) {
        switch byte {
        case 0x20...0x3E:
            if byte & 0x1F == device { listening = true; talking = false }
        case 0x3F:
            if listening { unlisten() }
            listening = false
        case 0x40...0x5E:
            if byte & 0x1F == device { talking = true; listening = false }
        case 0x5F:
            talking = false
        case 0x60...0x6F, 0xF0...0xFF:
            if listening || talking {
                secondary = byte
                if byte & 0xF0 == 0xF0 { openName = [] }
                if byte & 0x0F == 15, byte & 0xF0 == 0x60, listening { commandBuffer = [] }
            }
        case 0xE0...0xEF:
            if listening, byte & 0x0F == 2 { bufferChannelOpen = false }
        default: break
        }
    }

    private func unlisten() {
        if secondary & 0xF0 == 0xF0 {
            let ch = secondary & 0x0F
            if ch == 15 {
                if !openName.isEmpty { execute(openName) }
            } else if ch == 2, openName.first == UInt8(ascii: "#") {
                bufferChannelOpen = true
                bufferPointer = 1   // a 1541 starts a direct-access buffer at position 1
                status = "00, OK,00,00"
            }
        } else if secondary & 0xF0 == 0x60, secondary & 0x0F == 15, !commandBuffer.isEmpty {
            execute(commandBuffer)
            commandBuffer = []
        }
    }

    // MARK: Talker

    private func prepareTalkQueue() {
        talkIndex = 0
        if secondary & 0x0F == 15 {
            talkQueue = Array(status.utf8) + [0x0D]
            status = "00, OK,00,00"
        } else if secondary & 0x0F == 2, bufferChannelOpen {
            talkQueue = Array(buffer[bufferPointer...])
            bufferPointer = 0
        } else {
            talkQueue = [0x0D]
        }
    }

    private func talkerEdge(dataReleased: Bool, dataAsserted: Bool, at now: UInt64) {
        switch talk {
        case .waitListenerReady:
            if dataReleased, !driveDATA {
                guard talkIndex < talkQueue.count else { return }
                let last = talkIndex == talkQueue.count - 1
                if last {
                    // EOI: hold off; the listener times out, pulls DATA, then releases it again.
                    talk = .idle
                    eoiPending = true
                } else {
                    sendByte(talkQueue[talkIndex], at: now)
                }
            }
        case .idle:
            if eoiPending, dataReleased {
                // Listener released DATA after acknowledging EOI: send the last byte now.
                eoiPending = false
                sendByte(talkQueue[talkIndex], at: now)
            }
        case .waitFrameAck:
            if dataAsserted {
                talkIndex += 1
                talk = .idle
                if talkIndex < talkQueue.count {
                    schedule(now + 40, clk: false) { [weak self] in self?.talk = .waitListenerReady }
                }
            }
        case .sending:
            break
        }
    }

    private var eoiPending = false

    private func sendByte(_ byte: UInt8, at now: UInt64) {
        talk = .sending
        var t = now + 30
        schedule(t, clk: true)
        // 1541-like bit timing: setup with CLK asserted, then CLK released while data is valid.
        // Both phases must outlast a badline (40 cycles) plus the C64's debounced polling loop. Like a
        // real 1541 they do not survive badlines plus sprite DMA: the game turns sprites off ($E657)
        // around disk I/O, and callers of the loader must do the same.
        for bit in 0..<8 {
            let one = byte >> UInt8(bit) & 1 != 0
            t += 10
            schedule(t, clk: true, data: !one)
            t += 60
            schedule(t, clk: false)
            t += 60
        }
        t += 10
        schedule(t, clk: true, data: false) { [weak self] in self?.talk = .waitFrameAck }
    }

    // MARK: DOS commands

    private func execute(_ bytes: [UInt8]) {
        let text = String(decoding: bytes.filter { $0 != 0x0D }, as: UTF8.self)
        let upper = text.uppercased()
        func numbers(_ s: Substring) -> [Int] {
            s.split(whereSeparator: { $0 == " " || $0 == "," || $0 == ":" }).compactMap { Int($0) }
        }
        if upper.hasPrefix("I") {
            status = "00, OK,00,00"
        } else if upper.hasPrefix("U1") || upper.hasPrefix("UA") || upper.hasPrefix("U2") || upper.hasPrefix("UB") {
            let write = upper.hasPrefix("U2") || upper.hasPrefix("UB")
            let args = numbers(upper.dropFirst(2))
            guard args.count >= 4 else { status = "30,SYNTAX ERROR,00,00"; return }
            let t = args[2], s = args[3]
            guard t >= 1, t <= 35, s >= 0, s < D64Image.sectorCount(track: t) else {
                status = String(format: "66,ILLEGAL TRACK OR SECTOR,%02d,%02d", t, s)
                return
            }
            let o = D64Image.offset(track: t, sector: s)
            if write {
                for i in 0..<256 { disk[o + i] = buffer[i] }   // U2 leaves the buffer pointer alone
            } else {
                for i in 0..<256 { buffer[i] = disk[o + i] }
                bufferPointer = 0
            }
            status = "00, OK,00,00"
        } else if upper.hasPrefix("B-P") {
            let args = numbers(upper.dropFirst(3))
            if args.count >= 2 { bufferPointer = args[1] & 0xFF }
            status = "00, OK,00,00"
        } else if upper.hasPrefix("N") {
            for i in 0..<disk.count { disk[i] = 0 }
            status = "00, OK,00,00"
        } else {
            status = "31,SYNTAX ERROR,00,00"
        }
    }
}
