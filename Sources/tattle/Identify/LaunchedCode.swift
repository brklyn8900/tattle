import Foundation

/// The code a command line runs, read from its words: a program's own, a script file an
/// interpreter runs, or code the command line holds or does not name. Startup signs a job
/// by what it starts (`started`), and Processes names and marks a process by what it runs
/// (`running`).
///
/// The options each interpreter and wrapper takes come from its manual page. An option the
/// tables do not list counts as taking no value.
enum LaunchedCode: Equatable, Sendable {
    /// A program that runs its own code.
    case program(String)
    /// An interpreter running a script file, at the path the command line gives.
    case script(path: String, interpreter: String)
    /// An interpreter running code the command line does not name as a file: inline (`-c`,
    /// `-e`), a module or class by name, or in arguments that cannot be read; or a compiler
    /// running a plugin.
    case unnamed(interpreter: String)
    /// An interpreter reading its code from standard input: a pipe, a file launchd opens
    /// for it, or someone typing.
    case standardInput(interpreter: String)
    /// A program the command line does not locate: at a path relative to the working
    /// directory, found nowhere on the PATH, an app by name or bundle identifier, a document
    /// and whatever app opens it, a command inside an option's value, or one that xargs
    /// completes from its standard input.
    case undetermined

    /// Who a program is, for reading its command line. Apple's programs are known by their
    /// signing identifier, which a symlink, another name or another case leaves as it is;
    /// anyone else's by file name, which says nothing about what the file holds.
    struct Identity: Equatable, Sendable {
        /// The name the option tables know it by.
        var name: String
        var isApples: Bool

        init(path: String, signature: CodeSignature?) {
            let file = URL(fileURLWithPath: path).lastPathComponent
            isApples = signature?.signer == .apple
            if isApples, let identifier = signature?.identifier, !Self.stubs.contains(identifier),
               let last = identifier.split(separator: ".").last {
                name = String(last)
            } else {
                name = file
            }
        }

        /// Apple's stubs that run the developer tool their own file name chooses
        /// (`/usr/bin/python3`, `make`, `swift`, `java`), under one identifier.
        private static let stubs: Set<String> = ["com.apple.dt.xcode_select.tool-shim-public", "com.apple.servertool"]
    }

    /// What a running process runs: its executable's code, unless the executable is an
    /// interpreter. A wrapper has by then replaced itself with the program or started it as
    /// a process of its own. `arguments` follow argv[0], nil when they cannot be read;
    /// `invokedAs` is argv[0], when it is known.
    static func running(executable: String, arguments: [String]?, invokedAs: String? = nil, identity: Identity) -> LaunchedCode {
        if let tool = swiftTool(identity.name, invokedAs: invokedAs.flatMap { $0.isEmpty ? nil : $0 } ?? executable) {
            guard let arguments else { return .unnamed(interpreter: URL(fileURLWithPath: executable).lastPathComponent) }
            return swift(executable: executable, tool: tool, arguments: arguments)
        }
        guard let grammar = grammar(of: identity.name, in: interpreters) else { return .program(executable) }
        return interpreted(by: URL(fileURLWithPath: executable).lastPathComponent, arguments: arguments, grammar)
    }

    /// What a command line starts: through any wrappers (`nohup`, `caffeinate`, `env`) to
    /// the program they run, and through java to the jar it runs, then as `running` reads
    /// it. `arguments` follow argv[0].
    ///
    /// A program that is not Apple's runs its own code, whatever its name and arguments say:
    /// a command line through one reads as that program, unless it reaches a script, which
    /// reads as a script whoever starts it.
    ///
    /// launchd finds a program named without a path on `standardPath`; a wrapper finds one on
    /// the job's PATH, `environmentPath` when the plist sets it. `invokedAs` is argv[0], which
    /// a plist's `ProgramArguments` can name apart from its `Program`.
    static func started(
        program: String, arguments: [String], invokedAs: String? = nil, environmentPath: String? = nil, identify: (String) -> Identity
    ) -> LaunchedCode {
        guard let program = located(program, on: standardPath) else { return .undetermined }
        return started(program, arguments, invokedAs: invokedAs, identify, searchPath: environmentPath ?? standardPath)
    }

    /// launchd's `_PATH_STDPATH`, which is also the PATH a job runs with unless its plist
    /// sets one.
    static let standardPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// The file a command runs: an absolute path as it is, a bare name where execvp finds it
    /// on `searchPath`. Nil for a path relative to the working directory, which the command
    /// line does not give, for a search that would look there (an empty or relative entry),
    /// and for a name found nowhere.
    private static func located(_ command: String, on searchPath: String) -> String? {
        if command.hasPrefix("/") { return command }
        guard !command.isEmpty, !command.contains("/") else { return nil }
        for directory in searchPath.split(separator: ":", omittingEmptySubsequences: false) {
            guard directory.hasPrefix("/") else { return nil }
            let candidate = "\(directory)/\(command)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// `searchPath` is where a wrapper finds a program named without a path. A wrapper runs
    /// a program under the name its command line gives it, so only launchd sets `invokedAs`
    /// apart from the program.
    private static func started(
        _ program: String, _ arguments: [String], invokedAs: String? = nil, _ identify: (String) -> Identity, searchPath: String
    ) -> LaunchedCode {
        let identity = identify(program)
        let code = followed(program, arguments, invokedAs, identity, identify, searchPath: searchPath)
        switch code {
        case .script, .unnamed, .standardInput: return code
        case .program, .undetermined: return identity.isApples ? code : .program(program)
        }
    }

    /// What `program` starts, read by the name `identity` gives it.
    private static func followed(
        _ program: String, _ arguments: [String], _ invokedAs: String?, _ identity: Identity, _ identify: (String) -> Identity,
        searchPath: String
    ) -> LaunchedCode {
        if let grammar = grammar(of: identity.name, in: launchers) {
            return interpreted(by: URL(fileURLWithPath: program).lastPathComponent, arguments: arguments, grammar)
        }
        // xargs adds words from its standard input to the command it runs.
        if identity.name == "xargs" { return .undetermined }
        if identity.name == "open" { return opened(arguments, identify, searchPath: searchPath) }
        if identity.name == "find", let code = found(arguments, identify, searchPath: searchPath) { return code }
        guard let grammar = grammar(of: identity.name, in: wrappers) else {
            return running(executable: program, arguments: arguments, invokedAs: invokedAs, identity: identity)
        }
        switch scan(arguments, grammar) {
        case .operand(var index):
            var searchPath = searchPath
            if grammar.operandsBeforeCommand == .one { index += 1 }
            if grammar.operandsBeforeCommand == .assignments {
                while index < arguments.count, arguments[index].contains("=") {
                    if arguments[index].hasPrefix("PATH=") { searchPath = String(arguments[index].dropFirst(5)) }
                    index += 1
                }
            }
            guard index < arguments.count, let command = located(arguments[index], on: searchPath) else { return .undetermined }
            return started(command, Array(arguments[(index + 1)...]), identify, searchPath: searchPath)
        case .code, .file, .standardInput, .nothing: return .undetermined
        }
    }

    /// What `find` starts: the program its one `-exec`, `-execdir`, `-ok` or `-okdir` runs,
    /// with the words up to ";" or "+". Nil without one, when find runs only its own code;
    /// with more than one, what runs is not one program.
    private static func found(_ arguments: [String], _ identify: (String) -> Identity, searchPath: String) -> LaunchedCode? {
        let runs = arguments.indices.filter { ["-exec", "-execdir", "-ok", "-okdir"].contains(arguments[$0]) }
        guard let run = runs.first else { return nil }
        guard runs.count == 1, run + 1 < arguments.count, let command = located(arguments[run + 1], on: searchPath) else { return .undetermined }
        let words = arguments[(run + 2)...].prefix { $0 != ";" && $0 != "+" }
        return started(command, Array(words), identify, searchPath: searchPath)
    }

    /// What `open` starts: the app `-a` names, or the one app it is given. Its operands are
    /// files and URLs, not commands, and an app runs the documents it opens as it likes: with
    /// a document, what runs is not named. With `-e`, `-t`, `-f`, `-R` or `-h`, another app
    /// opens what it is given: TextEdit, the default text editor, Finder, a header's app.
    private static func opened(_ arguments: [String], _ identify: (String) -> Identity, searchPath: String) -> LaunchedCode {
        var app: String?
        var operands: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            switch argument {
            case "--args": index = arguments.count  // the rest is the app's
            case "--env", "--stderr", "--stdin", "--stdout", "--arch": index += 1
            case _ where argument.count < 2 || !argument.hasPrefix("-"): operands.append(argument)
            case _ where argument.hasPrefix("--"): continue
            default:
                // Letters group, as getopt reads them ("-gR"); -a and -s take the rest of the
                // word, else the next.
                var letters = argument.dropFirst()
                while let letter = letters.popFirst() {
                    switch letter {
                    case "b", "u", "e", "t", "f", "R", "h": return .undetermined
                    case "a", "s":
                        var value: String? = String(letters)
                        if letters.isEmpty {
                            value = index < arguments.count ? arguments[index] : nil
                            index += 1
                        }
                        if letter == "a" { app = value }
                        letters.removeAll()
                    default: continue
                    }
                }
            }
        }
        let opened: String?
        if let app {
            opened = operands.isEmpty ? app : nil
        } else {
            opened = operands.count == 1 && URL(fileURLWithPath: operands[0]).pathExtension == "app" ? operands[0] : nil
        }
        guard let opened, opened.hasPrefix("/") else { return .undetermined }
        return started(opened, [], identify, searchPath: searchPath)
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
        case .operand, .code: return .unnamed(interpreter: name)
        case .standardInput: return .standardInput(interpreter: name)
        case .nothing: return grammar.readsStandardInput ? .standardInput(interpreter: name) : .unnamed(interpreter: name)
        }
    }

    // MARK: - Swift

    /// Apple's swift-frontend is several tools in one file: the toolchain's `swift`, `swiftc`
    /// and `swift-symbolgraph-extract` are links to it, and it picks the tool by argv[0],
    /// without its extension, which a launch item names apart from the file it runs. Apple's
    /// stubs `/usr/bin/swift` and `swiftc` pick the tool by their own name.
    private static func swiftTool(_ name: String, invokedAs: String) -> String? {
        switch name.lowercased() {
        case "swift-frontend": URL(fileURLWithPath: invokedAs).deletingPathExtension().lastPathComponent
        case "swift", "swiftc": name.lowercased()
        default: nil
        }
    }

    /// What swift-frontend runs as `tool`. With `-frontend` first, or as itself, it is the
    /// frontend, which runs a script in immediate mode, `-interpret` anywhere in the line;
    /// otherwise it is the driver a first word `--driver-mode=` or `tool` names, and only the
    /// `swift` driver runs scripts. Any of them runs the compiler plugins its options name.
    private static func swift(executable: String, tool: String, arguments: [String]) -> LaunchedCode {
        let name = URL(fileURLWithPath: executable).lastPathComponent
        var arguments = arguments
        var tool = tool
        let isFrontend: Bool
        if arguments.first == "-frontend" {
            arguments.removeFirst()
            isFrontend = true
        } else if let first = arguments.first, first.hasPrefix("--driver-mode=") {
            tool = String(first.dropFirst("--driver-mode=".count))
            arguments.removeFirst()
            isFrontend = false
        } else {
            isFrontend = tool == "swift-frontend"
        }
        if isFrontend, arguments.contains("-interpret") {
            switch scan(arguments, swiftOptions) {
            case .operand(let index) where !arguments[index].isEmpty: return .script(path: arguments[index], interpreter: name)
            case .standardInput: return .standardInput(interpreter: name)
            case .operand, .code, .file, .nothing: return .unnamed(interpreter: name)
            }
        }
        if !isFrontend, tool == "swift" { return interpreted(by: name, arguments: arguments, swiftOptions) }
        return loadsPlugin(arguments, from: executable) ? .unnamed(interpreter: name) : .program(executable)
    }

    /// Whether `arguments` load a compiler plugin from outside the app or toolchain the
    /// compiler at `executable` is in. The driver gives every job its own toolchain's and
    /// SDK's plugins; any other is someone's code the compiler runs: a macro, an LLVM pass.
    private static func loadsPlugin(_ arguments: [String], from executable: String) -> Bool {
        let home = swiftHome(executable)
        var index = 0
        while index < arguments.count {
            let word = arguments[index].split(separator: "=", maxSplits: 1)
            index += 1
            guard let option = word.first.map(String.init), pluginOptions.contains(option) else { continue }
            let value: String
            if word.count > 1 {
                value = String(word[1])
            } else {
                if index < arguments.count, arguments[index] == "-Xfrontend" { index += 1 }  // as swiftc passes it on
                guard index < arguments.count else { return false }
                value = arguments[index]
                index += 1
            }
            guard let home, !value.split(separator: "/").contains("..") else { return true }
            // "<path>#<path>", and for two of them a last part of module names.
            let parts = value.split(separator: "#", omittingEmptySubsequences: false)
            let paths = pluginOptionsNamingModules.contains(option) && parts.count > 1 ? parts.dropLast() : parts[...]
            if !paths.allSatisfy({ $0.isEmpty || $0.hasPrefix(home + "/") }) { return true }
        }
        return false
    }

    /// Where the compiler's own plugins are: the app it is in (Xcode), else the toolchain over
    /// its `usr/bin`. Nil for a stub in `/usr/bin`, which does not say which toolchain it runs.
    private static func swiftHome(_ executable: String) -> String? {
        let components = executable.split(separator: "/", omittingEmptySubsequences: false)
        if let app = components.firstIndex(where: { $0.hasSuffix(".app") }) { return components[...app].joined(separator: "/") }
        guard let bin = executable.range(of: "/usr/bin/", options: .backwards), bin.lowerBound > executable.startIndex else { return nil }
        return String(executable[..<bin.lowerBound])
    }

    private static let pluginOptions: Set<String> = [
        "-load-plugin-library", "-load-plugin-executable", "-load-resolved-plugin", "-plugin-path", "-external-plugin-path",
        "-in-process-plugin-server-path", "-load-pass-plugin", "-cas-plugin-path",
    ]
    private static let pluginOptionsNamingModules: Set<String> = ["-load-plugin-executable", "-load-resolved-plugin"]

    /// "python3.14", "perl5.34" and "node25" are their interpreters too, and so is the
    /// "Python" in a Python framework's app.
    private static func grammar(of name: String, in table: [String: Grammar]) -> Grammar? {
        let name = name.lowercased()
        return table[name] ?? table[String(name.reversed().drop { $0.isNumber || $0 == "." }.reversed())]
    }

    // MARK: - Options

    private enum Takes {
        /// What runs is not the operand as given: code in the command line (inline, a module
        /// by name, a command in the option's value), the operands run by a shell or a session
        /// (`sudo -s`, `screen -X`), or a program found where the option says (`env -P`).
        case code
        /// The code comes from standard input.
        case standardInput
        /// The option's value is the file the code is in.
        case file
        /// The option takes a value, in the same word or the next.
        case value
        /// The option takes a value only in the same word ("-i.bak"), if at all.
        case attachedValue
        /// The option takes octal digits in the same word ("-l012"), and the letters after
        /// them are options again ("-lne").
        case octal
        /// As `octal`, or "x" and hexadecimal digits ("-0777", "-0x1F").
        case octalOrHex
    }

    private enum OperandsBeforeCommand { case none, one, assignments }

    private struct Grammar {
        var options: [String: Takes]
        /// Single letters group into one word ("-ec").
        var grouped = true
        /// A word that starts with "+" is options turned off ("+o posix"), as in shells.
        /// Elsewhere it is a file name.
        var plusOptions = false
        /// The first operand is a script file, not code (awk) or a class (java).
        var operandIsScript = true
        /// Without code named, the interpreter reads standard input; make reads the makefile
        /// in its working directory.
        var readsStandardInput = true
        /// What comes before the command a wrapper runs: `script`'s transcript file, `login`'s
        /// user, `env`'s assignments.
        var operandsBeforeCommand = OperandsBeforeCommand.none
    }

    private enum Found {
        case code, standardInput, file(String), operand(Int), nothing
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
            case .value: _ = value(attached: attached); return nil
            case .attachedValue, .octal, .octalOrHex: return nil
            }
        }
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--" {
                if index < arguments.count { operand = index }
                break
            }
            if argument == "-" { return .standardInput }
            let isOption = argument.count > 1 && (argument.hasPrefix("-") || (grammar.plusOptions && argument.hasPrefix("+")))
            guard isOption else {
                operand = index - 1
                break
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
                if takes == .octal || takes == .octalOrHex {
                    letters = takes == .octalOrHex && letters.first == "x"
                        ? letters.dropFirst().drop(while: \.isHexDigit)
                        : letters.drop { ("0"..."7").contains($0) }
                    continue
                }
                if let found = taking(takes, attached: letters.isEmpty ? nil : letters) { return found }
                if takes == .value || takes == .attachedValue { break }
            }
        }
        return operand.map(Found.operand) ?? Found.nothing
    }

    /// bash's `-O` takes a shell option; zsh's is a flag of its own (CORRECT_ALL).
    private static let bash = Grammar(options: [
        "-c": .code, "-s": .standardInput, "-o": .value, "-O": .value, "--rcfile": .value, "--init-file": .value,
    ], plusOptions: true)
    private static let zsh = Grammar(options: ["-c": .code, "-s": .standardInput, "-o": .value, "--emulate": .value], plusOptions: true)
    private static let shell = Grammar(options: ["-c": .code, "-s": .standardInput, "-o": .value], plusOptions: true)
    /// The swift driver's options, and the frontend's around a script it runs.
    private static let swiftOptions = Grammar(options: [
        "-e": .code, "-D": .value, "-F": .value, "-I": .value, "-L": .value, "-j": .value,
        "-module-name": .value, "-sdk": .value, "-target": .value, "-Xcc": .value, "-Xlinker": .value,
        "-Xfrontend": .value, "-swift-version": .value, "-enable-upcoming-feature": .value,
        "-plugin-path": .value, "-load-plugin-library": .value, "-load-plugin-executable": .value,
        "-load-resolved-plugin": .value, "-external-plugin-path": .value, "-in-process-plugin-server-path": .value,
        "-cas-plugin-path": .value,
    ], grouped: false)

    /// Interpreters: the code is a script file, inline, or standard input, never their own.
    private static let interpreters: [String: Grammar] = [
        "sh": bash, "bash": bash, "zsh": zsh, "ksh": shell, "csh": shell, "tcsh": shell, "dash": shell,
        "python": Grammar(options: ["-c": .code, "-m": .code, "-W": .value, "-X": .value, "--check-hash-based-pycs": .value]),
        "perl": Grammar(options: [
            "-e": .code, "-E": .code, "-I": .value, "-M": .value, "-m": .value,
            "-i": .attachedValue, "-l": .octal, "-0": .octalOrHex, "-C": .attachedValue,
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
        "wish": Grammar(options: [
            "-encoding": .value, "-colormap": .value, "-display": .value, "-geometry": .value,
            "-name": .value, "-use": .value, "-visual": .value,
        ], grouped: false),
        "make": Grammar(options: [
            "-f": .file, "--file": .file, "--makefile": .file, "-C": .value, "--directory": .value,
            "-I": .value, "--include-dir": .value, "-o": .value, "--old-file": .value, "-W": .value, "--what-if": .value,
        ], operandIsScript: false, readsStandardInput: false),
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
        "sandbox-exec": Grammar(options: ["-f": .value, "-n": .value, "-p": .value, "-D": .value]),
        "arch": Grammar(options: ["-arch": .value, "-d": .value, "-e": .value], grouped: false),
        // env's -P names where to look for the program, a search that is not followed.
        "env": Grammar(options: ["-u": .value, "-P": .code, "-C": .value, "-S": .code], operandsBeforeCommand: .assignments),
        "script": Grammar(options: ["-t": .value, "-T": .value], operandsBeforeCommand: .one),
        "login": Grammar(options: ["-h": .value], operandsBeforeCommand: .one),
        "xcrun": Grammar(options: ["-sdk": .value, "--sdk": .value, "-toolchain": .value, "--toolchain": .value], grouped: false),
        "sudo": Grammar(options: [
            "-C": .value, "-D": .value, "-g": .value, "-h": .value, "-p": .value, "-R": .value, "-r": .value,
            "-T": .value, "-t": .value, "-U": .value, "-u": .value, "-e": .code, "-i": .code, "-s": .code,
            "--close-from": .value, "--chdir": .value, "--group": .value, "--host": .value, "--prompt": .value,
            "--chroot": .value, "--command-timeout": .value, "--other-user": .value, "--user": .value,
            "--edit": .code, "--login": .code, "--shell": .code,
        ], operandsBeforeCommand: .assignments),
        "screen": Grammar(options: [
            "-c": .value, "-e": .value, "-h": .value, "-p": .value, "-S": .value, "-s": .value,
            "-T": .value, "-t": .value, "-X": .code,
        ]),
    ]
}
