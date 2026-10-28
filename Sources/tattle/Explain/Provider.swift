import Foundation

/// Something that turns a prompt into raw model output.
protocol ExplainProvider: Sendable {
    func explain(_ prompt: String) async throws -> String
}

enum ProviderError: Error, Equatable {
    case notConfigured
    case timedOut
    case failed(status: Int32, stderr: String)
}

/// Runs a shell command with the prompt on stdin and reads the answer from stdout. The
/// command runs in the user's login shell so PATH matches their terminal, and in a fresh
/// empty directory so agent CLIs with a sandbox have nothing to look at. `{schema}` in the
/// command is replaced with the output contract, shell-quoted.
struct ShellProvider: ExplainProvider {
    var command: String
    var timeout: TimeInterval = 120

    struct Preset: Identifiable, Sendable {
        let id: String
        let name: String
        let command: String
    }

    static let presets = [
        Preset(id: "claude", name: "Claude Code",
               // Not --bare: that mode reads no OAuth credentials, only an API key. User
               // settings are skipped so the user's hooks and plugins do not run for an
               // explain call; measured, that is a fifteenth of the cost and a third of
               // the time.
               command: "claude -p --setting-sources project,local --tools \"\" --permission-prompts none --output-format json --json-schema {schema}"),
        Preset(id: "codex", name: "Codex",
               // Every tool off, as --tools "" does for Claude: the shell and view_image read
               // the disk, web search and apps reach out. The user's config could add MCP servers.
               command: "codex exec --skip-git-repo-check --ignore-user-config --disable shell_tool --disable view_image --disable multi_agent --disable apps --disable plugins --disable image_generation -c web_search=disabled --sandbox read-only -"),
        Preset(id: "ollama", name: "Ollama",
               command: "ollama run llama3.2 --format json"),
    ]

    func explain(_ prompt: String) async throws -> String {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { throw ProviderError.notConfigured }
        let expanded = command.replacingOccurrences(of: "{schema}", with: Self.shellQuote(OutputContract.schema))
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let timeout = timeout
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try Self.run(shell: shell, command: expanded, input: prompt, timeout: timeout)
                })
            }
        }
    }

    private static func run(shell: String, command: String, input: String, timeout: TimeInterval) throws -> String {
        let workDir = FileManager.default.temporaryDirectory
            .appending(path: "tattle-explain-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let queue = kqueue()
        guard queue != -1 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(queue) }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        let pid = try spawn(shell, ["-l", "-c", command], in: workDir.path, stdin: stdin, stdout: stdout, stderr: stderr)
        let result = exchange(with: pid, on: queue, input: Data(input.utf8), stdin: stdin.fileHandleForWriting,
                              stdout: stdout.fileHandleForReading, stderr: stderr.fileHandleForReading,
                              until: .now() + timeout)
        let status = reap(pid)

        guard result.exited else { throw ProviderError.timedOut }
        guard status == 0 else {
            var message = String(decoding: result.errors, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty {
                message = failureMessage(in: String(decoding: result.output, as: UTF8.self))
            }
            throw ProviderError.failed(status: status, stderr: message)
        }
        return String(decoding: result.output, as: UTF8.self)
    }

    /// Writes `input` to the command and reads its stdout and stderr until it exits or the
    /// deadline passes. Then it kills the command's process group, which ends whatever the
    /// command left running. A process that left the group, as a daemonizing helper does,
    /// can hold a pipe open long after the command is gone, so nothing here waits on a pipe:
    /// the descriptors are non-blocking, and one kqueue watches them and the exit with the
    /// deadline as its timeout.
    private static func exchange(with pid: pid_t, on queue: Int32, input: Data, stdin: FileHandle,
                                 stdout: FileHandle, stderr: FileHandle,
                                 until deadline: DispatchTime) -> (output: Data, errors: Data, exited: Bool) {
        for handle in [stdin, stdout, stderr] {
            _ = fcntl(handle.fileDescriptor, F_SETFL, fcntl(handle.fileDescriptor, F_GETFL) | O_NONBLOCK)
        }
        // A command may answer without reading all of its input. The write then fails with
        // EPIPE rather than raising SIGPIPE, which would end the app, and the answer counts.
        _ = fcntl(stdin.fileDescriptor, F_SETNOSIGPIPE, 1)

        func watch(_ ident: Int32, _ filter: Int32, _ flags: Int32 = EV_ADD, _ fflags: UInt32 = 0) -> kevent {
            kevent(ident: UInt(ident), filter: Int16(filter), flags: UInt16(flags), fflags: fflags, data: 0, udata: nil)
        }
        var changes = [watch(pid, EVFILT_PROC, EV_ADD, NOTE_EXIT), watch(stdin.fileDescriptor, EVFILT_WRITE),
                       watch(stdout.fileDescriptor, EVFILT_READ), watch(stderr.fileDescriptor, EVFILT_READ)]
        var events = Array(repeating: kevent(), count: changes.count)
        var unsent = input, writing: FileHandle? = stdin
        var output = Data(), errors = Data()
        var exited = false
        while !exited {
            let now = DispatchTime.now()
            guard now < deadline else { break }
            let left = deadline.uptimeNanoseconds - now.uptimeNanoseconds
            var wait = timespec(tv_sec: Int(left / 1_000_000_000), tv_nsec: Int(left % 1_000_000_000))
            let count = kevent(queue, changes, Int32(changes.count), &events, Int32(events.count), &wait)
            changes.removeAll()
            for event in events.prefix(Int(max(count, 0))) {
                switch Int32(event.filter) {
                case EVFILT_PROC:
                    // The exit, or ESRCH if the command had already exited when it was watched.
                    exited = true
                case EVFILT_WRITE:
                    if let handle = writing, !send(&unsent, to: handle) {
                        try? handle.close()
                        writing = nil
                    }
                default:
                    let open = event.ident == UInt(stdout.fileDescriptor)
                        ? receive(from: stdout, into: &output) : receive(from: stderr, into: &errors)
                    if !open { changes.append(watch(Int32(event.ident), EVFILT_READ, EV_DELETE)) }
                }
            }
        }
        // The command is still unreaped, so its group id names only its own group.
        _ = killpg(pid, SIGKILL)
        try? writing?.close()
        // What the command wrote before it exited is already in the pipes.
        _ = receive(from: stdout, into: &output)
        _ = receive(from: stderr, into: &errors)
        return (output, errors, exited)
    }

    /// Writes as much of `unsent` as the pipe takes now. False once all of it is written or
    /// the command has closed its end.
    private static func send(_ unsent: inout Data, to handle: FileHandle) -> Bool {
        while !unsent.isEmpty {
            let count = unsent.withUnsafeBytes { write(handle.fileDescriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                unsent.removeFirst(count)
            } else if errno != EINTR {
                return errno == EAGAIN
            }
        }
        return false
    }

    /// Reads what the pipe holds now. False once every writer has closed its end.
    private static func receive(from handle: FileHandle, into data: inout Data) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(handle.fileDescriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer[..<count])
            } else if count == 0 || errno != EINTR {
                return count == -1 && errno == EAGAIN
            }
        }
    }

    /// Starts `path` with posix_spawn: Process cannot put the child in a group of its own
    /// before it runs, and setting it afterwards races the child's own children.
    private static func spawn(_ path: String, _ arguments: [String], in directory: String,
                              stdin: Pipe, stdout: Pipe, stderr: Pipe) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdin.fileHandleForReading.fileDescriptor, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout.fileHandleForWriting.fileDescriptor, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr.fileHandleForWriting.fileDescriptor, 2)
        posix_spawn_file_actions_addchdir_np(&actions, directory)

        // Every other descriptor closed, and signals as a fresh process has them, as
        // Process does.
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                    | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, &actions, &attributes, argv, environ)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        // The parent keeps only its own ends, or the reads never see end of file.
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        return pid
    }

    /// Reaps `pid` and returns its exit code, or the signal that ended it, as Process
    /// reports them.
    private static func reap(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : signal
    }

    /// Agent CLIs report errors on stdout inside their JSON envelope ("Not logged in").
    static func failureMessage(in stdout: String) -> String {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let result = object["result"] as? String, !result.isEmpty {
            return result
        }
        return String(trimmed.suffix(300))
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
