import XCTest
@testable import tattle

/// A launch item is signed, and a process named, by the code its command line runs: an
/// argument that only looks like that code must not stand in for it.
final class LaunchedCodeTests: XCTestCase {
    /// The signer Startup shows for a command line when every file reads as Apple's, and
    /// the files it read.
    private func signer(_ program: String, _ arguments: [String]) -> (signer: CodeSignature.Signer?, read: [String]) {
        var read: [String] = []
        let signature = CodeSignature.read(program: program, arguments: arguments) { read.append($0); return CodeSignature(signer: .apple) }
        return (signature?.signer, read)
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
            let result = signer(program, arguments)
            XCTAssertEqual(result.signer, .script, "\(program) \(arguments)")
            XCTAssertEqual(result.read, [], "\(program) \(arguments)")
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
            let result = signer(program, arguments)
            XCTAssertEqual(result.signer, .apple, "\(program) \(arguments)")
            XCTAssertEqual(result.read, [script], "\(program) \(arguments)")
        }
    }

    func testAScriptTheCommandLineDoesNotLocateIsAScript() {
        for (program, arguments) in [("/bin/bash", ["run.sh"]), ("/bin/sh", []), ("/usr/bin/java", ["-cp", "/x", "Main"])] {
            let result = signer(program, arguments)
            XCTAssertEqual(result.signer, .script, "\(program) \(arguments)")
            XCTAssertEqual(result.read, [], "\(program) \(arguments)")
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
            let result = signer(program, arguments)
            XCTAssertEqual(result.signer, .apple, "\(program) \(arguments)")
            XCTAssertEqual(result.read, [code], "\(program) \(arguments)")
        }
        let inline = signer("/usr/bin/nohup", ["/bin/sh", "-c", "payload", "/bin/ls"])
        XCTAssertEqual(inline.signer, .script)
        XCTAssertEqual(inline.read, [])
    }

    func testAWrapperWhoseProgramIsNotNamedHasNoSigner() {
        let commands: [(String, [String])] = [
            ("/usr/bin/open", ["-a", "Safari", "/bin/ls"]),
            ("/usr/bin/open", ["-b", "com.apple.Safari"]),
            ("/usr/bin/env", ["-S", "/bin/sh -c payload", "/bin/ls"]),
            ("/usr/bin/nohup", []),
        ]
        for (program, arguments) in commands {
            let result = signer(program, arguments)
            XCTAssertNil(result.signer, "\(program) \(arguments)")
            XCTAssertEqual(result.read, [], "\(program) \(arguments)")
        }
    }

    func testAProgramIsSignedByItself() {
        let result = signer("/bin/ls", ["-l", "/x/agent"])
        XCTAssertEqual(result.signer, .apple)
        XCTAssertEqual(result.read, ["/bin/ls"])
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
