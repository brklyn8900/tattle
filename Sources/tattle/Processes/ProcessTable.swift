import Darwin
import Foundation

/// One running process as the kernel lists it, with the usage numbers the current user
/// is allowed to read.
struct ProcessEntry: Equatable, Sendable, Identifiable {
    var pid: Int32
    var parentPid: Int32
    /// Effective user id, which is what `ps` shows as UID.
    var uid: UInt32
    /// The executable's file name when its path is readable, otherwise the kernel's
    /// command name, which is cut at 16 characters.
    var name: String
    var path: String?
    var started: Date
    var usage: ProcessUsage?

    var id: Int32 { pid }
}

/// Memory and CPU of one process. The two sources measure memory differently, so the
/// entry says which one it got.
struct ProcessUsage: Equatable, Sendable {
    var memoryBytes: UInt64
    /// CPU time consumed since the process started, user plus system, in seconds. A
    /// percentage is the difference between two readings over the time between them.
    var cpuSeconds: Double
    /// True for the physical footprint, Activity Monitor's Memory column, which libproc
    /// gives for the user's own processes. False for the resident set size `ps` gives
    /// for everyone else's, which also counts pages shared with other processes.
    var memoryIsFootprint: Bool
}

/// Reads every process without privileges. The list, parent, user and start time come
/// from the kinfo_proc sysctl; memory and CPU time come from libproc for the user's own
/// processes, which is all libproc will give an unprivileged caller, and from one run of
/// `ps`, which is setuid root, for the rest.
enum ProcessTable {
    enum ReadError: Error, Equatable {
        case sysctl(errno: Int32)
    }

    /// Every process with its usage. `fallback` is asked once for the pids libproc
    /// would not answer for; the default spawns `ps`, tests pass a table.
    static func read(fallback: ([Int32]) -> [Int32: ProcessUsage] = ProcessUsageFallback.read) throws -> [ProcessEntry] {
        var entries = try list()
        let uid = getuid()
        var missing: [Int32] = []
        for index in entries.indices {
            if entries[index].uid == uid, let usage = ownUsage(pid: entries[index].pid) {
                entries[index].usage = usage
            } else {
                missing.append(entries[index].pid)
            }
        }
        if !missing.isEmpty {
            let filled = fallback(missing)
            for index in entries.indices where entries[index].usage == nil {
                entries[index].usage = filled[entries[index].pid]
            }
        }
        return entries
    }

    /// The kernel's process list. Zombies are left out: they hold nothing and are gone
    /// as soon as their parent notices.
    static func list() throws -> [ProcessEntry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride
        // Processes start between the size query and the read, so ask for room to spare
        // and retry if the table still outgrew the buffer.
        for _ in 0..<4 {
            var length = 0
            guard sysctl(&mib, 4, nil, &length, nil, 0) == 0 else { throw ReadError.sysctl(errno: errno) }
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: length / stride + 64)
            length = buffer.count * stride
            if sysctl(&mib, 4, &buffer, &length, nil, 0) != 0 {
                if errno == ENOMEM { continue }
                throw ReadError.sysctl(errno: errno)
            }
            return buffer.prefix(length / stride).compactMap(entry)
        }
        throw ReadError.sysctl(errno: ENOMEM)
    }

    private static func entry(_ info: kinfo_proc) -> ProcessEntry? {
        guard Int32(info.kp_proc.p_stat) != SZOMB else { return nil }
        let pid = info.kp_proc.p_pid
        let command = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let path = pidPath(pid)
        let started = info.kp_proc.p_starttime
        return ProcessEntry(
            pid: pid, parentPid: info.kp_eproc.e_ppid, uid: info.kp_eproc.e_ucred.cr_uid,
            name: path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? command,
            path: path,
            started: Date(timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000))
    }

    private static func pidPath(_ pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cBuffer: buffer)
    }

    /// Footprint and CPU time from libproc. Fails with EPERM for other users' processes.
    static func ownUsage(pid: Int32) -> ProcessUsage? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pid_rusage(pid, RUSAGE_INFO_V4, UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: rusage_info_t?.self))
        }
        guard status == 0 else { return nil }
        return ProcessUsage(
            memoryBytes: info.ri_phys_footprint,
            cpuSeconds: machSeconds(info.ri_user_time + info.ri_system_time),
            memoryIsFootprint: true)
    }

    /// The rusage times are in Mach absolute units, not nanoseconds: on Apple silicon
    /// one unit is 125/3 ns.
    private static let timebase: (numer: Double, denom: Double) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (Double(info.numer), Double(info.denom))
    }()

    private static func machSeconds(_ units: UInt64) -> Double {
        Double(units) * timebase.numer / timebase.denom / 1_000_000_000
    }
}

/// Usage of the processes libproc will not describe, through `ps`. It is setuid root, so
/// it reads every process; one run takes about 50 ms for 1,600 processes.
enum ProcessUsageFallback {
    static func read(pids: [Int32]) -> [Int32: ProcessUsage] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,rss=,time="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Log.app.error("ps failed to start: \(error, privacy: .public)")
            return [:]
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let wanted = Set(pids)
        return parse(String(decoding: data, as: UTF8.self)).filter { wanted.contains($0.key) }
    }

    /// Lines of `ps -axo pid=,rss=,time=`: pid, resident kilobytes, cumulative CPU time.
    static func parse(_ output: String) -> [Int32: ProcessUsage] {
        var usage: [Int32: ProcessUsage] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 3, let pid = Int32(fields[0]), let kilobytes = UInt64(fields[1]),
                  let seconds = seconds(fromTime: fields[2]) else { continue }
            usage[pid] = ProcessUsage(memoryBytes: kilobytes * 1024, cpuSeconds: seconds, memoryIsFootprint: false)
        }
        return usage
    }

    /// `ps` prints CPU time as [[dd-]hh:]mm:ss.cc.
    static func seconds(fromTime text: Substring) -> Double? {
        var days = 0.0
        var rest = text
        if let dash = rest.firstIndex(of: "-") {
            guard let value = Double(rest[..<dash]) else { return nil }
            days = value
            rest = rest[rest.index(after: dash)...]
        }
        let parts = rest.split(separator: ":").map { Double($0) }
        guard parts.count >= 2, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        let values = parts.map { $0! }
        let hours = values.count == 3 ? values[0] : 0
        let minutes = values[values.count - 2]
        let seconds = values[values.count - 1]
        return ((days * 24 + hours) * 60 + minutes) * 60 + seconds
    }
}
