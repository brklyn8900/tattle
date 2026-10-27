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

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        let pid = try spawn(shell, ["-l", "-c", command], in: workDir.path, stdin: stdin, stdout: stdout, stderr: stderr)

        // The command leads a process group of its own, so the timeout ends whatever it
        // started: a child left holding stdout would keep the read below waiting.
        let watchdog = Watchdog()
        let deadline = DispatchWorkItem { watchdog.fire { _ = killpg(pid, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)

        stdin.fileHandleForWriting.write(Data(input.utf8))
        try? stdin.fileHandleForWriting.close()

        // Drain stderr on its own queue so a chatty command cannot block on a full pipe.
        let errorBuffer = ErrorBuffer()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errorBuffer.set(stderr.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let terminationStatus = waitForExit(pid) { deadline.cancel(); return watchdog.disarm() }
        group.wait()

        if terminationStatus.timedOut { throw ProviderError.timedOut }
        guard terminationStatus.status == 0 else {
            var message = String(decoding: errorBuffer.value, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty {
                message = failureMessage(in: String(decoding: output, as: UTF8.self))
            }
            throw ProviderError.failed(status: terminationStatus.status, stderr: message)
        }
        return String(decoding: output, as: UTF8.self)
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

    /// Waits for `pid` to exit and reaps it. `exited` runs between the two: until the
    /// reap the pid, and so the group id, cannot belong to another process.
    private static func waitForExit(_ pid: pid_t, exited: () -> Bool) -> (status: Int32, timedOut: Bool) {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
        let timedOut = exited()
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        // The exit code, or the signal that ended it, as Process reports them.
        let signal = status & 0x7f
        return (signal == 0 ? (status >> 8) & 0xff : signal, timedOut)
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

/// Kills at the timeout unless disarmed first, never both: once the command is reaped,
/// its group id may name another process's group.
private final class Watchdog: @unchecked Sendable {
    private enum State { case armed, fired, disarmed }
    private let lock = NSLock()
    private var state = State.armed

    func fire(_ kill: () -> Void) {
        lock.withLock {
            guard state == .armed else { return }
            state = .fired
            kill()
        }
    }

    /// Whether it fired.
    func disarm() -> Bool {
        lock.withLock {
            defer { state = .disarmed }
            return state == .fired
        }
    }
}

private final class ErrorBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    var value: Data { lock.withLock { data } }
    func set(_ new: Data) { lock.withLock { data = new } }
}
