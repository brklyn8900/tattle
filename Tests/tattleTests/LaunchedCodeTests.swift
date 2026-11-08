import XCTest
@testable import tattle

/// A launch item is signed, and a process named, by the code its command line runs: an
/// argument that only looks like that code must not stand in for it.
final class LaunchedCodeTests: XCTestCase {
    /// The signer Startup shows for a command line, where the files in `apple` read as
    /// Apple's, those in `identifiers` as Apple's with that signing identifier, and every
    /// other file as signed by a publisher named for its path.
    private func signer(_ program: String, _ arguments: [String], apple: Set<String> = [], identifiers: [String: String] = [:]) -> CodeSignature.Signer? {
        CodeSignature.read(program: program, arguments: arguments) { path in
            if let identifier = identifiers[path] { return CodeSignature(signer: .apple, identifier: identifier) }
            return CodeSignature(signer: apple.contains(path) ? .apple : .developerID(name: path))
        }?.signer
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
        for (program, arguments, script) in commands {
            XCTAssertEqual(signer(program, arguments), .developerID(name: script), "\(program) \(arguments)")
        }
    }

    func testAScriptThatReadsAsApplesIsAnArgumentMistakenForIt() {
        // Apple's scripts carry no signature, and no interpreter runs a signed binary as its
        // script: an Apple binary in the script's place was read there by mistake.
        let commands: [(String, [String])] = [
            ("/opt/homebrew/bin/node", ["--diagnostic-dir", "/usr/bin/true", "/x/evil.js"]),
            ("/bin/bash", ["/bin/ls"]),
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
            ("/usr/bin/xargs", ["-n", "1", "/x/agent"], "/x/agent"),
            ("/usr/bin/time", ["-o", "/bin/ls", "/x/agent"], "/x/agent"),
            ("/usr/bin/nice", ["-n", "5", "/x/agent"], "/x/agent"),
            ("/usr/bin/sandbox-exec", ["-f", "/bin/ls", "/x/agent"], "/x/agent"),
            ("/usr/bin/env", ["-u", "HOME", "PATH=/bin", "/x/agent"], "/x/agent"),
            ("/usr/bin/script", ["-q", "/dev/null", "/x/agent"], "/x/agent"),
            ("/usr/bin/login", ["-pf", "someone", "/x/agent"], "/x/agent"),
            ("/usr/bin/open", ["-a", "/Applications/X.app", "/bin/ls"], "/Applications/X.app"),
            ("/usr/bin/open", ["/bin/ls", "-a", "/Applications/X.app"], "/Applications/X.app"),
            ("/usr/bin/open", ["-g", "/Applications/X.app", "--args", "/bin/ls"], "/Applications/X.app"),
            ("/usr/bin/nohup", ["/usr/bin/env", "python3", "/x/a.py"], "/x/a.py"),
        ]
        for (program, arguments, code) in commands {
            XCTAssertEqual(signer(program, arguments), .developerID(name: code), "\(program) \(arguments)")
        }
        XCTAssertEqual(signer("/usr/bin/nohup", ["/bin/sh", "-c", "payload", "/bin/ls"]), .script)
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

    func testAProgramThatIsNotApplesNeverReadsAsApplesCode() {
        // A program named like a wrapper runs its own code, whatever it names.
        XCTAssertEqual(signer("/Users/x/nohup", ["/bin/ls"], apple: ["/bin/ls"]), .developerID(name: "/Users/x/nohup"))
        XCTAssertEqual(signer("/Users/x/env", ["/usr/bin/nice", "/bin/ls"], apple: ["/usr/bin/nice", "/bin/ls"]), .developerID(name: "/Users/x/env"))
        XCTAssertEqual(signer("/Users/x/nohup", ["/bin/sh", "-c", "payload"], apple: ["/bin/sh"]), .script, "a script reads as one whoever starts it")
        XCTAssertEqual(signer("/Users/x/nohup", ["/x/agent"]), .developerID(name: "/x/agent"), "followed when what it names is not Apple's")
        XCTAssertEqual(signer("/usr/bin/nohup", ["/bin/ls"], apple: ["/usr/bin/nohup", "/bin/ls"]), .apple)
    }

    func testAWrapperWhoseProgramIsNotNamedHasNoSigner() {
        let commands: [(String, [String])] = [
            ("/usr/bin/open", ["-a", "Safari", "/bin/ls"]),
            ("/usr/bin/open", ["-b", "com.apple.Safari"]),
            ("/usr/bin/env", ["-S", "/bin/sh -c payload", "/bin/ls"]),
            ("/usr/bin/nohup", []),
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

    func testARunningJavaIsAProgramAndAJobRunThroughJavaIsSignedByItsJar() {
        let named = ProcessEntry.name(path: "/Library/Java/JavaVirtualMachines/x.jdk/Contents/Home/bin/java",
                                      arguments: ["java", "-jar", "/x/server.jar"], command: "java")
        XCTAssertEqual(named.name, "java")
        XCTAssertNil(named.interpreter, "a JVM's row is the program, not a script")
        XCTAssertEqual(signer("/usr/bin/java", ["-jar", "/x/server.jar"]), .developerID(name: "/x/server.jar"), "not Apple's /usr/bin/java")
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
