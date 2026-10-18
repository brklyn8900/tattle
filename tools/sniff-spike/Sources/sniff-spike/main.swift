import CBPF
import Foundation

final class BPFDevice {
    let fd: Int32
    let bufferLength: Int
    let dataLinkType: UInt32
    private let buffer: UnsafeMutableRawPointer

    init(interface: String, timeoutMs: Int32 = 1000) throws {
        var length: UInt32 = 0
        var dlt: UInt32 = 0
        let fd = cbpf_open(interface, &length, &dlt, timeoutMs)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
        }
        self.fd = fd
        self.bufferLength = Int(length)
        self.dataLinkType = dlt
        self.buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(length), alignment: 16)
    }

    deinit {
        close(fd)
        buffer.deallocate()
    }

    // One read(2); returns without calling `handle` on timeout.
    func readPackets(_ handle: (Double, [UInt8]) -> Void) throws {
        let n = read(fd, buffer, bufferLength)
        if n < 0 {
            if errno == EINTR { return }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
        }
        var offset = 0
        var timestamp = 0.0
        var dataOffset = 0
        var caplen: UInt32 = 0
        var next = 0
        while cbpf_next(buffer, n, offset, &timestamp, &dataOffset, &caplen, &next) == 1 {
            let bytes = Array(UnsafeRawBufferPointer(start: buffer + dataOffset, count: Int(caplen)))
            handle(timestamp, bytes)
            offset = next
        }
    }
}

func defaultInterface() -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/sbin/route")
    task.arguments = ["-n", "get", "default"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    guard (try? task.run()) != nil else { return nil }
    task.waitUntilExit()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    for line in output.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("interface:") {
            return trimmed.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
        }
    }
    return nil
}

func usage() -> Never {
    fputs("""
    usage: sniff-spike [--interface en0] [--every 60] [--duration 3600] [--log flows.jsonl] [--debug]

    Captures on the interface (default: the default route's), names outbound connections
    from DNS replies, TLS SNI, QUIC Initial packets and plaintext HTTP, and prints a coverage
    summary every --every seconds and at exit. Stops after --duration seconds, or on Ctrl-C.
    Needs read access to /dev/bpf*: run with sudo.

    """, stderr)
    exit(2)
}

var interface = defaultInterface() ?? "en0"
var every = 60.0
var logPath: String?
var duration: Double?
var debug = false
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--interface", "-i":
        guard !args.isEmpty else { usage() }
        interface = args.removeFirst()
    case "--every":
        guard !args.isEmpty, let value = Double(args.removeFirst()), value > 0 else { usage() }
        every = value
    case "--duration":
        guard !args.isEmpty, let value = Double(args.removeFirst()), value > 0 else { usage() }
        duration = value
    case "--debug":
        debug = true
    case "--log":
        guard !args.isEmpty else { usage() }
        logPath = args.removeFirst()
    default:
        usage()
    }
}

let device: BPFDevice
do {
    device = try BPFDevice(interface: interface)
} catch {
    fputs("sniff-spike: cannot open BPF on \(interface): \(error.localizedDescription). Run with sudo.\n", stderr)
    exit(1)
}

let tally = Tally(localAddresses: localAddresses(), logPath: logPath, debug: debug)
var stopRequested = false
signal(SIGINT) { _ in stopRequested = true }
signal(SIGTERM) { _ in stopRequested = true }

fputs("sniff-spike: capturing on \(interface) (dlt \(device.dataLinkType)), summary every \(Int(every))s; Ctrl-C to stop\n", stderr)

var lastSummary = Date()
let deadline = duration.map { Date().addingTimeInterval($0) }
while !stopRequested {
    if let deadline, Date() >= deadline { break }
    do {
        try device.readPackets { ts, bytes in
            if let packet = Packet.parse(bytes, dlt: device.dataLinkType) {
                tally.observe(packet, at: ts)
            }
        }
    } catch {
        fputs("sniff-spike: read failed: \(error.localizedDescription)\n", stderr)
        break
    }
    tally.expire(now: Date().timeIntervalSince1970)
    if Date().timeIntervalSince(lastSummary) >= every {
        tally.printSummary()
        lastSummary = Date()
    }
}

tally.finishAll()
tally.printSummary(final: true)
