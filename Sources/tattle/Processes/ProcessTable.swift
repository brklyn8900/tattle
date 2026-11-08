import Darwin
import Foundation

/// One running process as the kernel lists it, with the usage numbers the current user
/// is allowed to read.
struct ProcessEntry: Equatable, Sendable, Identifiable {
    var pid: Int32
    var parentPid: Int32
    /// Effective user id, which is what `ps` shows as UID.
    var uid: UInt32
    /// What the process is: the script's name when an interpreter runs a script, else
    /// the executable's file name, else the name it was started under, else the kernel's
    /// command name, which is cut at 16 characters.
    var name: String
    var path: String?
    /// The interpreter's file name when the process runs code that is not its executable's
    /// (a script file, inline code, standard input under launchd, what one of Apple's
    /// developer tools is told to run, or code its unreadable arguments would name), so a row
    /// can name the interpreter and sign the code apart from it, with the interpreter's
    /// signature as a fact of its own.
    var interpreter: String?
    /// The interpreter runs code the command line does not name as a file, not a script:
    /// the row says "node, unnamed code" and signs it as such.
    var runsUnnamedCode = false
    /// The script an interpreter runs, as the command line gives it.
    var script: String?
    /// Command-line arguments, readable for the user's own processes only.
    var arguments: [String]?
    /// Working directory, readable for the user's own processes only.
    var workingDirectory: String?
    var started: Date
    var usage: ProcessUsage?

    var id: Int32 { pid }

    /// The name and interpreter for an executable and its arguments, by what the process
    /// runs (`LaunchedCode.running`, which knows Apple's programs by `signature`). An
    /// interpreter running a script file is named after the file, or after the npm package
    /// the file belongs to; running other code or a folder, it is still marked as the
    /// interpreter, and so is one launchd started reading its standard input, which is then
    /// a file or a pipe, not a person at a terminal. Otherwise the name the process was
    /// started under wins over the executable's file name: a multi-call binary at a
    /// version-numbered path is "claude" or "ugrep", a login shell "-zsh" is zsh, and a node
    /// process that set its title keeps it.
    static func name(
        path: String?, arguments: [String]?, command: String, signature: CodeSignature? = nil, startedByLaunchd: Bool = false
    ) -> (name: String, interpreter: String?, runsUnnamedCode: Bool, script: String?) {
        let executable = path.map { URL(fileURLWithPath: $0).lastPathComponent }
        var interpreter: String?
        var runsUnnamedCode = false
        if let path {
            let identity = LaunchedCode.Identity(path: path, signature: signature)
            switch LaunchedCode.running(executable: path, arguments: arguments.map { Array($0.dropFirst()) }, identity: identity) {
            case .script(let script, let name): return (scriptName(script), name, false, script)
            case .inline(let name), .unnamed(let name):
                interpreter = name
                runsUnnamedCode = true
            case .standardInput(let name) where startedByLaunchd: interpreter = name
            case .standardInput(let name) where identity.isDeveloperTool:
                interpreter = name
                runsUnnamedCode = true
            case .program, .standardInput, .undetermined: break
            }
        }
        if let first = arguments?.first {
            // A title with spaces ("npm exec @scope/pkg") is not a path, unless it starts
            // like one ("/Users/u/Library/Application Support/x/server").
            let isTitle = first.contains(" ") && !first.hasPrefix("/")
            let started = (isTitle ? Substring(first) : Substring(URL(fileURLWithPath: first).lastPathComponent)).drop { $0 == "-" }
            if !started.isEmpty { return (String(started), interpreter, runsUnnamedCode, nil) }
        }
        return (executable ?? command, interpreter, runsUnnamedCode, nil)
    }

    /// This entry named by its executable's signature, for one listed without it: a renamed
    /// copy of Apple's interpreter or one of Apple's developer tools is known only by that.
    func named(signature: CodeSignature?) -> ProcessEntry {
        guard let path else { return self }
        let named = Self.name(path: path, arguments: arguments, command: name, signature: signature, startedByLaunchd: parentPid == 1)
        var entry = self
        (entry.name, entry.interpreter, entry.runsUnnamedCode, entry.script) = named
        return entry
    }

    /// Who signed the code the process runs, given its executable's signature: no one for a
    /// script or unnamed code.
    func codeSignature(executable: CodeSignature?) -> CodeSignature? {
        interpreter == nil ? executable : CodeSignature(signer: runsUnnamedCode ? .unnamed : .script)
    }

    /// What tells the code this process runs from another's of its name (`CodeIdentity`),
    /// given its executable's signature: the script's file, or the executable when it runs its
    /// own code. Unnamed code, standard input and a script at a path relative to a working
    /// directory that cannot be read have nothing to tell them apart.
    func identity(executable: CodeSignature?) -> CodeIdentity? {
        if let script {
            guard script.hasPrefix("/") || workingDirectory != nil else { return nil }
            let base = workingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            return CodeIdentity.script(at: URL(fileURLWithPath: script, relativeTo: base).absoluteURL.standardized.path)
        }
        return interpreter == nil ? CodeIdentity.of(executable, path: path) : nil
    }

    /// A file inside an npm package is known by the package: "chrome-devtools-mcp"
    /// rather than "main.js". Scoped packages keep their scope; a launcher in .bin is
    /// already named for its command.
    static func scriptName(_ path: String) -> String {
        let components = path.split(separator: "/")
        if let index = components.lastIndex(of: "node_modules"), index + 1 < components.count - 1, components[index + 1] != ".bin" {
            let package = components[index + 1]
            if package.hasPrefix("@"), index + 2 < components.count - 1 {
                return "\(package)/\(components[index + 2])"
            }
            return String(package)
        }
        return String(components.last ?? Substring(path))
    }
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
    /// would not answer for; the default spawns `ps`, tests pass a table. `signature` is
    /// called per executable path, to know Apple's interpreters by their signing identifier.
    static func read(
        fallback: ([Int32]) -> [Int32: ProcessUsage] = ProcessUsageFallback.read, signature: (String) -> CodeSignature?
    ) throws -> [ProcessEntry] {
        var entries = try list(signature: signature)
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
    static func list(signature: (String) -> CodeSignature?) throws -> [ProcessEntry] {
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
            // One argmax-sized scratch buffer for the command lines: allocating a
            // megabyte per process made a sweep of 1,600 take over a second.
            var scratch = [UInt8](repeating: 0, count: argumentsMaximum)
            return buffer.prefix(length / stride).compactMap { entry($0, scratch: &scratch, signature: signature) }
        }
        throw ReadError.sysctl(errno: ENOMEM)
    }

    private static func entry(_ info: kinfo_proc, scratch: inout [UInt8], signature: (String) -> CodeSignature?) -> ProcessEntry? {
        guard Int32(info.kp_proc.p_stat) != SZOMB else { return nil }
        let pid = info.kp_proc.p_pid
        let command = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let path = pidPath(pid)
        // KERN_PROCARGS2 refuses other users' processes, so only ask for our own.
        let own = pid > 0 && info.kp_eproc.e_ucred.cr_uid == getuid()
        let arguments = own ? self.arguments(pid: pid, scratch: &scratch) : nil
        let named = ProcessEntry.name(
            path: path, arguments: arguments, command: command, signature: path.flatMap(signature),
            startedByLaunchd: info.kp_eproc.e_ppid == 1)
        let started = info.kp_proc.p_starttime
        return ProcessEntry(
            pid: pid, parentPid: info.kp_eproc.e_ppid, uid: info.kp_eproc.e_ucred.cr_uid,
            name: named.name, path: path, interpreter: named.interpreter, runsUnnamedCode: named.runsUnnamedCode,
            script: named.script, arguments: arguments,
            workingDirectory: own ? workingDirectory(pid: pid) : nil,
            started: Date(timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000))
    }

    /// The current directory, through PROC_PIDVNODEPATHINFO, which answers only for the
    /// user's own processes.
    static func workingDirectory(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }

    private static let argumentsMaximum: Int = {
        var value: Int32 = 0
        var length = MemoryLayout<Int32>.size
        sysctlbyname("kern.argmax", &value, &length, nil, 0)
        return Int(max(value, 4096))
    }()

    /// The command line, through KERN_PROCARGS2, which answers only for the user's own
    /// processes. The buffer holds argc, the executable path, padding, then the
    /// arguments and the environment, all NUL-separated.
    static func arguments(pid: Int32) -> [String]? {
        var scratch = [UInt8](repeating: 0, count: argumentsMaximum)
        return arguments(pid: pid, scratch: &scratch)
    }

    static func arguments(pid: Int32, scratch: inout [UInt8]) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var length = scratch.count
        guard sysctl(&mib, 3, &scratch, &length, nil, 0) == 0, length > MemoryLayout<Int32>.size else { return nil }
        return parseArguments(scratch.prefix(length))
    }

    static func parseArguments(_ bytes: ArraySlice<UInt8>) -> [String]? {
        guard bytes.count > 4 else { return nil }
        let argc = Int(bytes[bytes.startIndex..<bytes.startIndex + 4].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var cursor = bytes.startIndex + 4
        // Skip the executable path and the NULs padding it.
        while cursor < bytes.endIndex, bytes[cursor] != 0 { cursor += 1 }
        while cursor < bytes.endIndex, bytes[cursor] == 0 { cursor += 1 }
        var arguments: [String] = []
        while arguments.count < argc, cursor < bytes.endIndex {
            let start = cursor
            while cursor < bytes.endIndex, bytes[cursor] != 0 { cursor += 1 }
            arguments.append(String(decoding: bytes[start..<cursor], as: UTF8.self))
            cursor += 1
        }
        return arguments
    }

    static func pidPath(_ pid: Int32) -> String? {
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
