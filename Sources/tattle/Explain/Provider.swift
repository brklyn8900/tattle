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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", command]
        process.currentDirectoryURL = workDir
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        // The watchdog only keeps the pid: Process itself is not Sendable.
        let pid = process.processIdentifier
        let timedOut = TimedOutFlag()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if kill(pid, 0) == 0 {
                timedOut.set()
                kill(pid, SIGKILL)
            }
        }

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
        process.waitUntilExit()
        group.wait()

        if timedOut.value { throw ProviderError.timedOut }
        guard process.terminationStatus == 0 else {
            var message = String(decoding: errorBuffer.value, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty {
                message = failureMessage(in: String(decoding: output, as: UTF8.self))
            }
            throw ProviderError.failed(status: process.terminationStatus, stderr: message)
        }
        return String(decoding: output, as: UTF8.self)
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

private final class TimedOutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

private final class ErrorBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    var value: Data { lock.withLock { data } }
    func set(_ new: Data) { lock.withLock { data = new } }
}
