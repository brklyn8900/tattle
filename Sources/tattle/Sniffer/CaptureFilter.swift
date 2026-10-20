import Foundation

/// A kernel packet filter (classic BPF, net/bpf.h) that keeps only what the parsers
/// read, so a download is dropped in the kernel instead of copied into the app:
///
/// - outbound TCP SYNs and outbound TCP segments carrying payload (the ClientHello,
///   the HTTP request line);
/// - outbound UDP datagrams whose first payload byte has the QUIC long-header bit;
/// - inbound UDP from port 53 (DNS replies).
///
/// Outbound is told from the interface's own hardware address on Ethernet, and from the
/// interface's addresses on links without one. Fragments other than the first are dropped;
/// IPv6 extension headers are not followed (a host's own TCP and UDP rarely have any).
struct CaptureFilter: Equatable, Sendable {
    struct Instruction: Equatable, Sendable {
        var code: UInt16
        var jt: UInt8
        var jf: UInt8
        var k: UInt32
    }

    /// How a packet is known to leave this Mac.
    enum Direction: Equatable, Sendable {
        /// Its Ethernet source is this hardware address.
        case hardwareAddress([UInt8])
        /// Its IP source is one of these addresses (4 or 16 bytes each).
        case sourceAddresses([[UInt8]])
    }

    static let snapLength: UInt32 = 2048

    var instructions: [Instruction]

    /// The program for a link type, or nil for one this filter has no layout for, in
    /// which case everything is copied and the parsers do all the dropping.
    static func program(linkType: UInt32, direction: Direction) -> CaptureFilter? {
        let linkLength: UInt32
        switch linkType {
        case PacketCapture.linkEthernet: linkLength = 14
        case PacketCapture.linkNull: linkLength = 4
        case PacketCapture.linkRaw: linkLength = 0
        default: return nil
        }
        if case .hardwareAddress(let mac) = direction, mac.count != 6 || linkType != PacketCapture.linkEthernet { return nil }

        var a = Assembler()
        let v4 = a.label(), v6 = a.label(), accept = a.label(), drop = a.label()
        let L = linkLength

        // IP version from the first nibble after the link header.
        a.loadByte(at: L)
        a.and(0xf0)
        a.jumpIfEqual(0x40, v4, else: nil)
        a.jumpIfEqual(0x60, v6, else: drop)

        // IPv4
        a.mark(v4)
        let v4out = a.label(), v4in = a.label()
        a.loadHalf(at: L + 6)
        a.jumpIfSet(0x1fff, drop, else: nil)  // not the first fragment
        emitDirection(&a, direction, linkLength: L, family: .v4, outbound: v4out, inbound: v4in)
        a.mark(v4out)
        let v4tcp = a.label(), v4udp = a.label()
        a.loadByte(at: L + 9)
        a.jumpIfEqual(6, v4tcp, else: nil)
        a.jumpIfEqual(17, v4udp, else: drop)
        a.mark(v4tcp)
        a.loadXHeaderLength(at: L)
        a.loadByteIndexed(at: L + 13)  // TCP flags
        a.jumpIfSet(0x02, accept, else: nil)
        a.loadHalf(at: L + 2)  // total length
        a.subtractX()
        a.store(0)
        a.loadByteIndexed(at: L + 12)  // data offset
        emitPayloadCheck(&a, accept: accept, drop: drop)
        a.mark(v4udp)
        a.loadXHeaderLength(at: L)
        a.loadByteIndexed(at: L + 8)  // first UDP payload byte
        a.jumpIfSet(0x80, accept, else: drop)
        a.mark(v4in)
        a.loadByte(at: L + 9)
        a.jumpIfEqual(17, nil, else: drop)
        a.loadXHeaderLength(at: L)
        a.loadHalfIndexed(at: L)  // UDP source port
        a.jumpIfEqual(53, accept, else: drop)

        // IPv6
        a.mark(v6)
        let v6out = a.label(), v6in = a.label()
        emitDirection(&a, direction, linkLength: L, family: .v6, outbound: v6out, inbound: v6in)
        a.mark(v6out)
        let v6tcp = a.label(), v6udp = a.label()
        a.loadByte(at: L + 6)
        a.jumpIfEqual(6, v6tcp, else: nil)
        a.jumpIfEqual(17, v6udp, else: drop)
        a.mark(v6tcp)
        a.loadByte(at: L + 40 + 13)
        a.jumpIfSet(0x02, accept, else: nil)
        a.loadHalf(at: L + 4)  // payload length
        a.store(0)
        a.loadByte(at: L + 40 + 12)
        emitPayloadCheck(&a, accept: accept, drop: drop)
        a.mark(v6udp)
        a.loadByte(at: L + 40 + 8)
        a.jumpIfSet(0x80, accept, else: drop)
        a.mark(v6in)
        a.loadByte(at: L + 6)
        a.jumpIfEqual(17, nil, else: drop)
        a.loadHalf(at: L + 40)
        a.jumpIfEqual(53, accept, else: drop)

        a.mark(accept)
        a.ret(snapLength)
        a.mark(drop)
        a.ret(0)
        return CaptureFilter(instructions: a.resolve())
    }

    private enum Family { case v4, v6 }

    private static func emitDirection(_ a: inout Assembler, _ direction: Direction, linkLength L: UInt32, family: Family, outbound: Assembler.Label, inbound: Assembler.Label) {
        switch direction {
        case .hardwareAddress(let mac):
            let high = UInt32(mac[0]) << 24 | UInt32(mac[1]) << 16 | UInt32(mac[2]) << 8 | UInt32(mac[3])
            let low = UInt32(mac[4]) << 8 | UInt32(mac[5])
            a.loadWord(at: 6)
            a.jumpIfEqual(high, nil, else: inbound)
            a.loadHalf(at: 10)
            a.jumpIfEqual(low, outbound, else: inbound)
        case .sourceAddresses(let addresses):
            let wanted = family == .v4 ? 4 : 16
            let offset = family == .v4 ? L + 12 : L + 8
            let matching = addresses.filter { $0.count == wanted }
            for address in matching {
                let miss = a.label()
                for word in 0..<(wanted / 4) {
                    let value = UInt32(address[word * 4]) << 24 | UInt32(address[word * 4 + 1]) << 16
                        | UInt32(address[word * 4 + 2]) << 8 | UInt32(address[word * 4 + 3])
                    a.loadWord(at: offset + UInt32(word * 4))
                    let last = word == wanted / 4 - 1
                    a.jumpIfEqual(value, last ? outbound : nil, else: miss)
                }
                a.mark(miss)
            }
            a.jump(inbound)
        }
    }

    /// A holds the transport header's data-offset byte and M[0] the bytes from the
    /// transport header on; accepts when payload follows the header.
    private static func emitPayloadCheck(_ a: inout Assembler, accept: Assembler.Label, drop: Assembler.Label) {
        a.shiftRight(4)
        a.shiftLeft(2)
        a.toX()
        a.loadMemory(0)
        a.subtractX()
        a.jumpIfGreater(0, accept, else: drop)
    }

    /// The checks the kernel makes before accepting a program (bpf_validate): jumps go
    /// forward and land inside the program, memory slots exist, it ends in a return.
    var isValid: Bool {
        let count = instructions.count
        guard count > 0, count <= 4096 else { return false }
        for (index, insn) in instructions.enumerated() {
            switch insn.code & 0x07 {
            case Op.jmp:
                if insn.code & 0xf0 == Op.ja {
                    guard index + 1 + Int(insn.k) < count else { return false }
                } else {
                    guard index + 1 + Int(insn.jt) < count, index + 1 + Int(insn.jf) < count else { return false }
                }
            case Op.st, Op.stx:
                guard insn.k < 16 else { return false }
            case Op.ld, Op.ldx:
                if insn.code & 0xe0 == Op.mem { guard insn.k < 16 else { return false } }
            default:
                break
            }
        }
        return instructions[count - 1].code & 0x07 == Op.ret
    }

    private enum Op {
        static let ld: UInt16 = 0x00, ldx: UInt16 = 0x01, st: UInt16 = 0x02, stx: UInt16 = 0x03
        static let alu: UInt16 = 0x04, jmp: UInt16 = 0x05, ret: UInt16 = 0x06, misc: UInt16 = 0x07
        static let w: UInt16 = 0x00, h: UInt16 = 0x08, b: UInt16 = 0x10
        static let imm: UInt16 = 0x00, abs: UInt16 = 0x20, ind: UInt16 = 0x40, mem: UInt16 = 0x60, msh: UInt16 = 0xa0
        static let sub: UInt16 = 0x10, and: UInt16 = 0x50, lsh: UInt16 = 0x60, rsh: UInt16 = 0x70
        static let ja: UInt16 = 0x00, jeq: UInt16 = 0x10, jgt: UInt16 = 0x20, jset: UInt16 = 0x40
        static let k: UInt16 = 0x00, x: UInt16 = 0x08
        static let tax: UInt16 = 0x00
    }

    /// Emits instructions with symbolic jump targets and resolves them to the relative
    /// offsets BPF wants, which must be forward. A missing target falls through.
    private struct Assembler {
        struct Label: Hashable { let id: Int }

        private enum Target {
            case label(Label)
            case none
        }

        private struct Pending {
            var code: UInt16
            var k: UInt32
            var jt: Target
            var jf: Target
            var ja: Target
        }

        private var pending: [Pending] = []
        private var positions: [Label: Int] = [:]
        private var nextID = 0

        mutating func label() -> Label {
            defer { nextID += 1 }
            return Label(id: nextID)
        }

        mutating func mark(_ label: Label) { positions[label] = pending.count }

        private mutating func emit(_ code: UInt16, _ k: UInt32 = 0, jt: Label? = nil, jf: Label? = nil, ja: Label? = nil) {
            pending.append(Pending(code: code, k: k, jt: jt.map(Target.label) ?? .none,
                                   jf: jf.map(Target.label) ?? .none, ja: ja.map(Target.label) ?? .none))
        }

        mutating func loadByte(at offset: UInt32) { emit(Op.ld | Op.b | Op.abs, offset) }
        mutating func loadHalf(at offset: UInt32) { emit(Op.ld | Op.h | Op.abs, offset) }
        mutating func loadWord(at offset: UInt32) { emit(Op.ld | Op.w | Op.abs, offset) }
        mutating func loadByteIndexed(at offset: UInt32) { emit(Op.ld | Op.b | Op.ind, offset) }
        mutating func loadHalfIndexed(at offset: UInt32) { emit(Op.ld | Op.h | Op.ind, offset) }
        /// X = 4 * (P[offset] & 0xf): the IPv4 header length.
        mutating func loadXHeaderLength(at offset: UInt32) { emit(Op.ldx | Op.b | Op.msh, offset) }
        mutating func loadMemory(_ slot: UInt32) { emit(Op.ld | Op.w | Op.mem, slot) }
        mutating func store(_ slot: UInt32) { emit(Op.st, slot) }
        mutating func and(_ value: UInt32) { emit(Op.alu | Op.and | Op.k, value) }
        mutating func subtractX() { emit(Op.alu | Op.sub | Op.x) }
        mutating func shiftRight(_ bits: UInt32) { emit(Op.alu | Op.rsh | Op.k, bits) }
        mutating func shiftLeft(_ bits: UInt32) { emit(Op.alu | Op.lsh | Op.k, bits) }
        mutating func toX() { emit(Op.misc | Op.tax) }
        // A nil branch falls through to the next instruction.
        mutating func jumpIfEqual(_ value: UInt32, _ jt: Label?, else jf: Label?) { emit(Op.jmp | Op.jeq | Op.k, value, jt: jt, jf: jf) }
        mutating func jumpIfGreater(_ value: UInt32, _ jt: Label?, else jf: Label?) { emit(Op.jmp | Op.jgt | Op.k, value, jt: jt, jf: jf) }
        mutating func jumpIfSet(_ mask: UInt32, _ jt: Label?, else jf: Label?) { emit(Op.jmp | Op.jset | Op.k, mask, jt: jt, jf: jf) }
        mutating func jump(_ target: Label) { emit(Op.jmp | Op.ja, ja: target) }
        mutating func ret(_ length: UInt32) { emit(Op.ret | Op.k, length) }

        func resolve() -> [Instruction] {
            pending.enumerated().map { index, p in
                func offset(_ target: Target) -> Int {
                    guard case .label(let label) = target, let position = positions[label] else { return 0 }
                    let delta = position - (index + 1)
                    precondition(delta >= 0 && delta <= 255, "BPF jumps go forward and at most 255 instructions")
                    return delta
                }
                if case .label = p.ja {
                    return Instruction(code: p.code, jt: 0, jf: 0, k: UInt32(offset(p.ja)))
                }
                return Instruction(code: p.code, jt: UInt8(offset(p.jt)), jf: UInt8(offset(p.jf)), k: p.k)
            }
        }
    }
}
