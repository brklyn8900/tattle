import Foundation

/// The code a command line runs, read from its words: a program's own, a script file an
/// interpreter runs, or code the command line holds or does not name. Startup signs a job
/// by it and Processes names a process by it, so both tabs read one command line one way.
///
/// The options each interpreter and wrapper takes come from its manual page. An option the
/// tables do not list counts as taking no value.
enum LaunchedCode: Equatable, Sendable {
    /// A program that runs its own code.
    case program(String)
    /// An interpreter running a script file, at the path the command line gives.
    case script(path: String, interpreter: String)
    /// An interpreter running code the command line does not name as a file: inline (`-c`,
    /// `-e`), a module or class by name, or in arguments that cannot be read.
    case unnamed(interpreter: String)
    /// An interpreter reading its code from standard input: a pipe, a file launchd opens
    /// for it, or someone typing.
    case standardInput(interpreter: String)
    /// A wrapper running a program its command line does not name: an app by name or
    /// bundle identifier, or a command inside an option's value.
    case undetermined

    /// What a running process runs: its executable's code, unless the executable is an
    /// interpreter. A wrapper has by then replaced itself with the program or started it as
    /// a process of its own. `arguments` follow argv[0], nil when they cannot be read.
    static func running(executable: String, arguments: [String]?) -> LaunchedCode {
        let name = URL(fileURLWithPath: executable).lastPathComponent
        guard let grammar = grammar(of: name, in: interpreters) else { return .program(executable) }
        return interpreted(by: name, arguments: arguments, grammar)
    }

    /// What a command line starts: through any wrappers (`nohup`, `caffeinate`, `env`) to
    /// the program they run, and through java to the jar it runs, then as `running` reads
    /// it. `arguments` follow argv[0].
    static func started(program: String, arguments: [String]) -> LaunchedCode {
        let name = URL(fileURLWithPath: program).lastPathComponent
        if let grammar = grammar(of: name, in: launchers) { return interpreted(by: name, arguments: arguments, grammar) }
        guard let grammar = grammar(of: name, in: wrappers) else {
            return running(executable: program, arguments: arguments)
        }
        switch scan(arguments, grammar) {
        case .program(let path) where path.hasPrefix("/"): return started(program: path, arguments: [])
        case .operand(var index):
            if grammar.operandsBeforeCommand == .one { index += 1 }
            if grammar.operandsBeforeCommand == .assignments {
                while index < arguments.count, arguments[index].contains("=") { index += 1 }
            }
            guard index < arguments.count else { return .undetermined }
            return started(program: arguments[index], arguments: Array(arguments[(index + 1)...]))
        case .program, .code, .file, .standardInput, .nothing: return .undetermined
        }
    }

    /// What the interpreter `name` runs with `arguments`.
    private static func interpreted(by name: String, arguments: [String]?, _ grammar: Grammar) -> LaunchedCode {
        guard let arguments else { return .unnamed(interpreter: name) }
        switch scan(arguments, grammar) {
        case .file(let path): return .script(path: path, interpreter: name)
        case .operand(let index) where grammar.operandIsScript && !arguments[index].isEmpty:
            return .script(path: arguments[index], interpreter: name)
        // An empty operand is what is left when a process rewrites its own arguments (a node
        // title), so the script is no longer named.
        case .operand, .code, .program: return .unnamed(interpreter: name)
        case .standardInput, .nothing: return .standardInput(interpreter: name)
        }
    }

    /// "python3.14", "perl5.34" and "node25" are their interpreters too.
    private static func grammar(of name: String, in table: [String: Grammar]) -> Grammar? {
        table[name] ?? table[String(name.reversed().drop { $0.isNumber || $0 == "." }.reversed())]
    }

    // MARK: - Options

    private enum Takes {
        /// The code is in the command line: inline, or a module or app by name.
        case code
        /// The code comes from standard input.
        case standardInput
        /// The option's value is the file the code is in.
        case file
        /// The option's value is the program a wrapper runs.
        case program
        /// The option takes a value, in the same word or the next.
        case value
        /// The option takes a value only in the same word ("-i.bak"), if at all.
        case attachedValue
    }

    private enum OperandsBeforeCommand { case none, one, assignments }

    private struct Grammar {
        var options: [String: Takes]
        /// Single letters group into one word ("-ec"), and "+o" is "-o" turned off.
        var grouped = true
        /// The first operand is a script file, not code (awk) or a class (java).
        var operandIsScript = true
        /// Options may follow operands, as in `open`.
        var optionsAfterOperands = false
        /// Ends the wrapper's own arguments, as `--args` does `open`'s.
        var stop: String?
        /// What comes before the command a wrapper runs: `script`'s transcript file, `login`'s
        /// user, `env`'s assignments.
        var operandsBeforeCommand = OperandsBeforeCommand.none
    }

    private enum Found {
        case code, standardInput, file(String), program(String), operand(Int), nothing
    }

    /// The first option that decides what runs, else the first operand.
    private static func scan(_ arguments: [String], _ grammar: Grammar) -> Found {
        var operand: Int?
        var index = 0
        // A value in the same word, else the next word.
        func value(attached: Substring?) -> String? {
            if let attached { return String(attached) }
            guard index < arguments.count else { return nil }
            index += 1
            return arguments[index - 1]
        }
        func taking(_ takes: Takes, attached: Substring?) -> Found? {
            switch takes {
            case .code: return .code
            case .standardInput: return .standardInput
            case .file: return value(attached: attached).map(Found.file) ?? Found.nothing
            case .program: return value(attached: attached).map(Found.program) ?? Found.nothing
            case .value: _ = value(attached: attached); return nil
            case .attachedValue: return nil
            }
        }
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == grammar.stop { break }
            if argument == "--" {
                if operand == nil, index < arguments.count { operand = index }
                break
            }
            if argument == "-" { return .standardInput }
            let isOption = argument.count > 1 && (argument.hasPrefix("-") || (grammar.grouped && argument.hasPrefix("+")))
            guard isOption else {
                if operand == nil { operand = index - 1 }
                if grammar.optionsAfterOperands { continue } else { break }
            }
            if argument.hasPrefix("--") || !grammar.grouped {
                let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let takes = grammar.options[String(parts[0])] else { continue }
                if let found = taking(takes, attached: parts.count > 1 ? parts[1] : nil) { return found }
                continue
            }
            var letters = argument.dropFirst()
            while let letter = letters.popFirst() {
                guard let takes = grammar.options["-\(letter)"] else { continue }
                if let found = taking(takes, attached: letters.isEmpty ? nil : letters) { return found }
                if takes == .value || takes == .attachedValue { break }
            }
        }
        return operand.map(Found.operand) ?? Found.nothing
    }

    private static let shell = Grammar(options: [
        "-c": .code, "-s": .standardInput, "-o": .value, "-O": .value,
        "--rcfile": .value, "--init-file": .value, "--emulate": .value,
    ])

    /// Interpreters: the code is a script file, inline, or standard input, never their own.
    private static let interpreters: [String: Grammar] = [
        "sh": shell, "bash": shell, "zsh": shell, "ksh": shell, "csh": shell, "tcsh": shell, "dash": shell,
        "python": Grammar(options: ["-c": .code, "-m": .code, "-W": .value, "-X": .value, "--check-hash-based-pycs": .value]),
        "perl": Grammar(options: [
            "-e": .code, "-E": .code, "-I": .value, "-M": .value, "-m": .value,
            "-i": .attachedValue, "-l": .attachedValue, "-0": .attachedValue, "-C": .attachedValue,
            "-d": .attachedValue, "-D": .attachedValue, "-x": .attachedValue, "-V": .attachedValue,
        ]),
        "ruby": Grammar(options: [
            "-e": .code, "-I": .value, "-r": .value, "-C": .value, "-E": .value,
            "-x": .attachedValue, "-0": .attachedValue, "-K": .attachedValue, "-T": .attachedValue,
            "-W": .attachedValue, "-F": .attachedValue,
            "--encoding": .value, "--external-encoding": .value, "--internal-encoding": .value,
            "--enable": .value, "--disable": .value, "--dump": .value,
        ]),
        "php": Grammar(options: [
            "-r": .code, "-R": .code, "-B": .code, "-E": .code, "-S": .code, "-f": .file, "-F": .file,
            "-c": .value, "-d": .value, "-z": .value, "-t": .value,
        ]),
        "node": Grammar(options: [
            "-e": .code, "--eval": .code, "-p": .code, "--print": .code, "-pe": .code, "--run": .code,
            "-r": .value, "--require": .value, "--import": .value, "--loader": .value, "--experimental-loader": .value,
            "-C": .value, "--conditions": .value, "--input-type": .value, "--title": .value, "--env-file": .value,
        ], grouped: false),
        "osascript": Grammar(options: ["-e": .code, "-l": .value, "-s": .value]),
        "tclsh": Grammar(options: ["-encoding": .value], grouped: false),
        "expect": Grammar(options: ["-c": .code, "-f": .file, "-b": .file, "-D": .value], grouped: false),
        "awk": Grammar(options: ["-f": .file, "-v": .value, "-F": .value], operandIsScript: false),
    ]

    /// Interpreters only in a command line: a job run through java runs its jar, not Apple's
    /// `/usr/bin/java`. A running JVM keeps its own name and signer, as a program rather than
    /// a script.
    private static let launchers: [String: Grammar] = [
        "java": Grammar(options: [
            "-jar": .file, "-m": .code, "--module": .code,
            "-cp": .value, "-classpath": .value, "--class-path": .value, "-p": .value, "--module-path": .value,
            "--upgrade-module-path": .value, "--add-modules": .value, "--limit-modules": .value, "--source": .value,
        ], grouped: false, operandIsScript: false),
    ]

    /// Wrappers: they run the command in their operands, by replacing themselves with it or
    /// starting it as a child.
    private static let wrappers: [String: Grammar] = [
        "nohup": Grammar(options: [:]),
        "nice": Grammar(options: ["-n": .value]),
        "time": Grammar(options: ["-o": .value]),
        "caffeinate": Grammar(options: ["-t": .value, "-w": .value]),
        "xargs": Grammar(options: [
            "-E": .value, "-I": .value, "-J": .value, "-L": .value, "-n": .value,
            "-P": .value, "-R": .value, "-S": .value, "-s": .value,
        ]),
        "sandbox-exec": Grammar(options: ["-f": .value, "-n": .value, "-p": .value, "-D": .value]),
        "arch": Grammar(options: ["-arch": .value, "-d": .value, "-e": .value], grouped: false),
        "env": Grammar(options: ["-u": .value, "-P": .value, "-C": .value, "-S": .code], operandsBeforeCommand: .assignments),
        "script": Grammar(options: ["-t": .value, "-T": .value], operandsBeforeCommand: .one),
        "login": Grammar(options: ["-h": .value], operandsBeforeCommand: .one),
        "open": Grammar(options: [
            "-a": .program, "-b": .code, "-u": .code,
            "-s": .value, "--env": .value, "--stderr": .value, "--stdin": .value, "--stdout": .value, "--arch": .value,
        ], grouped: false, optionsAfterOperands: true, stop: "--args"),
    ]
}
