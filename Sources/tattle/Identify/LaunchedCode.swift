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
    /// `-e`), a module or class by name, a package by its folder, or in arguments that cannot
    /// be read; or one of Apple's developer tools, which runs code from where it is told.
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
        /// One of Apple's developer tools: in a toolchain, an Xcode or the Command Line Tools,
        /// or one of the stubs in `/usr/bin` that run them. A compiler loads the plugins and
        /// passes it is told to, a linker the libraries, a debugger the scripts, git a
        /// repository's hooks.
        var isDeveloperTool: Bool

        /// `realPath` is `path` with its links resolved, which the kernel already does for a
        /// process's executable.
        init(path: String, signature: CodeSignature?, realPath: String? = nil) {
            let file = URL(fileURLWithPath: path).lastPathComponent
            isApples = signature?.signer == .apple
            let identifier = isApples ? signature?.identifier : nil
            if let identifier, !Self.stubs.contains(identifier), let last = identifier.split(separator: ".").last {
                name = String(last)
            } else {
                name = file
            }
            isDeveloperTool = isApples
                && (identifier.map(Self.developerStubs.contains) == true || Self.isInDeveloperFolder(realPath ?? path))
        }

        /// A toolchain is a `.xctoolchain` folder wherever it is installed. An Xcode is an app
        /// with a developer folder, whatever it is called; its debugger's server is outside
        /// that folder.
        private static func isInDeveloperFolder(_ path: String) -> Bool {
            if path.hasPrefix("/Library/Developer/CommandLineTools/") { return true }
            if path.split(separator: "/").contains(where: { $0.hasSuffix(".xctoolchain") }) { return true }
            guard let end = path.range(of: ".app/") else { return false }
            let developer = String(path[..<end.lowerBound]) + ".app/Contents/Developer"
            return path.hasPrefix(developer + "/") || FileManager.default.fileExists(atPath: developer)
        }

        /// Apple's stubs that run the developer tool their own file name chooses, from the
        /// Xcode or the Command Line Tools xcode-select chose (`/usr/bin/python3`, `swift`,
        /// `git`, `xcodebuild`, `devicectl`).
        private static let developerStubs: Set<String> = [
            "com.apple.dt.xcode_select.tool-shim-public", "com.apple.dt.xcode_select.xtool-shim-public",
            "com.apple.dt.xcode_select.libdevtool-shim-public",
        ]
        /// They, and `/usr/bin/java`, which runs a Java runtime's: all are known by file name.
        private static let stubs = developerStubs.union(["com.apple.servertool"])
    }

    /// What a running process runs: its executable's code, unless the executable is an
    /// interpreter or one of Apple's developer tools. A wrapper has by then replaced itself
    /// with the program or started it as a process of its own. `arguments` follow argv[0], nil
    /// when they cannot be read.
    static func running(executable: String, arguments: [String]?, identity: Identity) -> LaunchedCode {
        let name = URL(fileURLWithPath: executable).lastPathComponent
        if swiftTools.contains(identity.name.lowercased()) {
            guard let arguments else { return .unnamed(interpreter: name) }
            if let code = swift(name, arguments: arguments) { return code }
        } else if let grammar = grammar(of: identity.name, in: interpreters) {
            return interpreted(by: name, arguments: arguments, grammar)
        }
        return identity.isDeveloperTool ? .unnamed(interpreter: name) : .program(executable)
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
    /// the job's PATH, `environmentPath` when the plist sets it.
    static func started(program: String, arguments: [String], environmentPath: String? = nil, identify: (String) -> Identity) -> LaunchedCode {
        guard let program = located(program, on: standardPath) else { return .undetermined }
        return started(program, arguments, identify, searchPath: environmentPath ?? standardPath)
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

    /// `searchPath` is where a wrapper finds a program named without a path.
    private static func started(_ program: String, _ arguments: [String], _ identify: (String) -> Identity, searchPath: String) -> LaunchedCode {
        let identity = identify(program)
        let code = followed(program, arguments, identity, identify, searchPath: searchPath)
        switch code {
        case .script, .unnamed, .standardInput: return code
        case .program, .undetermined: return identity.isApples ? code : .program(program)
        }
    }

    /// What `program` starts, read by the name `identity` gives it.
    private static func followed(
        _ program: String, _ arguments: [String], _ identity: Identity, _ identify: (String) -> Identity, searchPath: String
    ) -> LaunchedCode {
        if let grammar = grammar(of: identity.name, in: launchers) {
            return interpreted(by: URL(fileURLWithPath: program).lastPathComponent, arguments: arguments, grammar)
        }
        // xargs adds words from its standard input to the command it runs.
        if identity.name == "xargs" { return .undetermined }
        if identity.name == "open" { return opened(arguments, identify, searchPath: searchPath) }
        if identity.name == "find", let code = found(arguments, identify, searchPath: searchPath) { return code }
        guard let grammar = grammar(of: identity.name, in: wrappers) else {
            return running(executable: program, arguments: arguments, identity: identity)
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
            var argument = arguments[index]
            index += 1
            if argument == "--args" { break }  // the rest is the app's
            if argument == "--" {  // the rest are files
                operands += arguments[index...]
                break
            }
            guard argument.count > 1, argument.hasPrefix("-") else {
                operands.append(argument)
                continue
            }
            if argument.hasPrefix("--") {
                // A long option, by its name or a prefix of only one name ("--rev"), with a
                // value after "=" or in the next word, reads as its letter, as getopt_long reads
                // it. open refuses any other, and opens nothing.
                let parts = argument.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let names = (Array(openLongOptions.keys) + openLongValues).filter { $0.hasPrefix(parts[0]) }
                guard let name = names.first(where: { $0 == parts[0] }) ?? (names.count == 1 ? names.first : nil) else {
                    return .undetermined
                }
                guard let letter = openLongOptions[name] else {
                    if parts.count == 1 { index += 1 }
                    continue
                }
                if parts.count > 1, !openValueLetters.contains(letter) { return .undetermined }
                argument = "-\(letter)" + (parts.count > 1 ? parts[1] : "")
            }
            // Letters group, as getopt reads them ("-gR"); one that takes a value takes the rest
            // of the word, else the next.
            var letters = argument.dropFirst()
            while let letter = letters.popFirst() {
                switch letter {
                case "b", "u", "e", "t", "f", "R", "h": return .undetermined
                case _ where openValueLetters.contains(letter):
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
        let opened: String?
        if let app {
            opened = operands.isEmpty ? app : nil
        } else {
            opened = operands.count == 1 && URL(fileURLWithPath: operands[0]).pathExtension == "app" ? operands[0] : nil
        }
        guard let opened, opened.hasPrefix("/") else { return .undetermined }
        return started(opened, [], identify, searchPath: searchPath)
    }

    /// open's options from its usage (`open --help`): the letters that take a value, the long
    /// options and the letters they stand for, and the long options with a value and no letter.
    private static let openValueLetters: Set<Character> = ["a", "s", "i", "o"]
    private static let openLongOptions: [String: Character] = [
        "fresh": "F", "reveal": "R", "wait-apps": "W", "new": "n", "hide": "j", "background": "g", "header": "h",
        "url": "u", "stdin": "i", "stdout": "o",
    ]
    private static let openLongValues = ["stderr", "env", "arch"]

    /// What the interpreter `name` runs with `arguments`.
    private static func interpreted(by name: String, arguments: [String]?, _ grammar: Grammar) -> LaunchedCode {
        guard let arguments else { return .unnamed(interpreter: name) }
        switch scan(arguments, grammar) {
        case .file(let path): return scriptFile(path, interpreter: name)
        case .operand(let index) where grammar.operandIsScript: return scriptFile(arguments[index], interpreter: name)
        case .operand, .code: return .unnamed(interpreter: name)
        case .standardInput: return .standardInput(interpreter: name)
        case .nothing: return grammar.readsStandardInput ? .standardInput(interpreter: name) : .unnamed(interpreter: name)
        }
    }

    /// The script file at `path`, which a folder is not: "node ." runs the package in its
    /// working directory, which the path does not name. Nor is the empty word a process leaves
    /// when it rewrites its own arguments (a node title).
    private static func scriptFile(_ path: String, interpreter: String) -> LaunchedCode {
        let isFolder = path.hasSuffix("/") || [".", ".."].contains(path.split(separator: "/").last ?? ".")
        return path.isEmpty || isFolder ? .unnamed(interpreter: interpreter) : .script(path: path, interpreter: interpreter)
    }

    // MARK: - Swift

    /// Apple's Swift tools, by signing identifier, and the stubs `/usr/bin/swift` and `swiftc`.
    private static let swiftTools: Set<String> = ["swift-frontend", "swift-driver", "swift", "swiftc"]

    /// The script a Swift tool named `name` runs, nil when the command line names none. The
    /// frontend runs one in immediate mode, `-interpret` anywhere in its line or passed on to
    /// it (`-Xfrontend -interpret`); the `swift` driver runs the file it is given, by replacing
    /// itself with the frontend, or a program beside it. The toolchain's `swift` is a link to
    /// the frontend, which acts as the driver its file name says.
    private static func swift(_ name: String, arguments: [String]) -> LaunchedCode? {
        let isDriver = name.lowercased() == "swift"
        guard isDriver || arguments.contains("-interpret") else { return nil }
        // A first word without a "." or "/" names another program beside the driver: `swift
        // build` runs swift-build.
        if isDriver, let first = arguments.first, !first.hasPrefix("-"), !first.contains("."), !first.contains("/") {
            return .unnamed(interpreter: name)
        }
        switch scan(arguments, swiftOptions) {
        case .operand(let index): return scriptFile(arguments[index], interpreter: name)
        case .standardInput: return .standardInput(interpreter: name)
        case .code, .file, .nothing: return .unnamed(interpreter: name)
        }
    }

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
