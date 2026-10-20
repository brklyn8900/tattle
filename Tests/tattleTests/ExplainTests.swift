import XCTest
@testable import tattle

final class RedactorTests: XCTestCase {
    private let redactor = Redactor(
        home: "/Users/username", username: "username", machineNames: ["Users-Computer", "users-computer.local"])

    func testHomeAndUsername() {
        XCTAssertEqual(redactor.redact("/Users/username/Library/Foo run by username"), "<home>/Library/Foo run by <user>")
        XCTAssertEqual(redactor.redact("usernamex.example.com"), "usernamex.example.com", "username only at word boundaries")
    }

    func testMachineNames() {
        XCTAssertEqual(redactor.redact("host USERS-COMPUTER.local and Users-Computer"), "host <machine> and <machine>")
    }

    func testPrivateIPsOnly() {
        XCTAssertEqual(redactor.redact("10.0.0.5 172.20.1.1 192.168.1.9 127.0.0.1 169.254.3.3 100.64.0.1"),
                       "<private-ip> <private-ip> <private-ip> <private-ip> <private-ip> <private-ip>")
        XCTAssertEqual(redactor.redact("17.253.144.10 172.32.0.1 8.8.8.8"), "17.253.144.10 172.32.0.1 8.8.8.8")
        XCTAssertEqual(redactor.redact("fe80::1c2b:3d4e%en0 fd12:3456::1 ::1 2a03:2880:f12f::1"),
                       "<private-ip> <private-ip> <private-ip> 2a03:2880:f12f::1")
    }
}

final class LLMAnswerTests: XCTestCase {
    private let bare = #"{"owner":"Apple","purpose":"iCloud sync.","category":"sync","risk":"Low","confidence":"high"}"#

    func testBareObject() throws {
        let answer = try LLMAnswer.parse(bare)
        XCTAssertEqual(answer.owner, "Apple")
        XCTAssertEqual(answer.risk, .low)
        XCTAssertEqual(answer.confidence, .high)
        XCTAssertNil(answer.suggestedPattern)
    }

    func testClaudeEnvelope() throws {
        let envelope = #"{"type":"result","result":"\#(bare.replacingOccurrences(of: "\"", with: "\\\""))","cost":1}"#
        XCTAssertEqual(try LLMAnswer.parse(envelope).purpose, "iCloud sync.")
        let structured = #"{"type":"result","structured_output":\#(bare)}"#
        XCTAssertEqual(try LLMAnswer.parse(structured).purpose, "iCloud sync.")
    }

    func testFencedAndTrailingObject() throws {
        XCTAssertEqual(try LLMAnswer.parse("Sure:\n```json\n\(bare)\n```\n").purpose, "iCloud sync.")
        XCTAssertEqual(try LLMAnswer.parse("[2026] thinking {not json\n\(bare)\ndone").purpose, "iCloud sync.")
    }

    func testRejectsMissingOrBadFields() {
        XCTAssertThrowsError(try LLMAnswer.parse("no json here")) { XCTAssertEqual($0 as? LLMAnswer.ParseError, .noJSON) }
        XCTAssertThrowsError(try LLMAnswer.parse(#"{"risk":"low","confidence":"low"}"#)) { XCTAssertEqual($0 as? LLMAnswer.ParseError, .missing("purpose")) }
        XCTAssertThrowsError(try LLMAnswer.parse(#"{"purpose":"x","risk":"severe","confidence":"low"}"#)) { XCTAssertEqual($0 as? LLMAnswer.ParseError, .badValue("risk")) }
    }
}

final class PromptTests: XCTestCase {
    func testPromptCarriesItemFactsAndContract() {
        let request = ExplainRequest(kind: .host, key: "Gateway.iCloud.com", facts: [Fact(name: "Signer", value: "Apple")])
        let prompt = Prompt.build(instructions: "Be brief.", request: request)
        XCTAssertTrue(prompt.hasPrefix("Be brief.\n\nItem: host gateway.icloud.com\nFacts:\n- Signer: Apple\n"))
        XCTAssertTrue(prompt.hasSuffix(OutputContract.schema))
        XCTAssertTrue(Prompt.build(instructions: "x", request: ExplainRequest(kind: .port, key: "5000")).contains("Facts: none established."))
    }
}

struct FakeProvider: ExplainProvider {
    let output: String
    let seen: Recorder = Recorder()

    final class Recorder: @unchecked Sendable {
        var prompts: [String] = []
    }

    func explain(_ prompt: String) async throws -> String {
        seen.prompts.append(prompt)
        return output
    }
}

@MainActor
final class ExplainerTests: XCTestCase {
    private var store: RuleStore!
    private var settings: AppSettings!
    private let redactor = Redactor(home: "/Users/username", username: "username", machineNames: ["Users-Computer"])

    override func setUpWithError() throws {
        let database = try AppDatabase.inMemory()
        store = RuleStore(database: database)
        settings = try AppSettings(store: SettingsStore(database: database))
        settings.providerCommand = "fake"
    }

    private func explainer(_ provider: FakeProvider) -> Explainer {
        Explainer(store: store, settings: settings, redactor: redactor, makeProvider: { command in
            XCTAssertEqual(command, "fake")
            return provider
        })
    }

    func testAskStoresExactUnconfirmedLLMRuleAndRedactsPrompt() async throws {
        let provider = FakeProvider(output: #"{"owner":"Acme","purpose":"Update check.","category":"update","risk":"low","confidence":"medium","suggestedPattern":"*.acme.com"}"#)
        settings.promptInstructions = "Go."
        let explainer = explainer(provider)
        let request = ExplainRequest(kind: .process, key: "/Users/username/Applications/Acme.app/Contents/MacOS/Acme",
                                     facts: [Fact(name: "Host", value: "Users-Computer")])
        let rule = try await explainer.ask(request)

        XCTAssertEqual(rule.source, .llm)
        XCTAssertEqual(rule.match, .exact, "the model may suggest a pattern; only the user promotes")
        XCTAssertEqual(rule.pattern, request.key)
        XCTAssertNil(rule.confirmed)
        XCTAssertEqual(rule.owner, "Acme")
        XCTAssertEqual(rule.risk, .low)
        XCTAssertNotNil(rule.id)
        XCTAssertEqual(try store.lookup(kind: .process, key: request.key)?.purpose, "Update check.")

        let sent = try XCTUnwrap(provider.seen.prompts.first)
        XCTAssertFalse(sent.contains("/Users/username"))
        XCTAssertFalse(sent.contains("Users-Computer"))
        XCTAssertTrue(sent.contains("<home>/Applications/Acme.app"))
        XCTAssertTrue(sent.contains("- Host: <machine>"))
        XCTAssertEqual(explainer.lastPrompt, sent)
        XCTAssertTrue(sent.hasPrefix("Go.\n"))
    }

    func testLookupNeverCallsProvider() throws {
        try store.save(Rule(kind: .host, pattern: "a.example", purpose: "known", source: .builtin))
        let provider = FakeProvider(output: "")
        let explainer = explainer(provider)
        XCTAssertEqual(try explainer.lookup(ExplainRequest(kind: .host, key: "a.example"))?.purpose, "known")
        XCTAssertNil(try explainer.lookup(ExplainRequest(kind: .host, key: "b.example")))
        XCTAssertTrue(provider.seen.prompts.isEmpty)
    }

    func testBadAnswerStoresNothing() async throws {
        let explainer = explainer(FakeProvider(output: "I cannot help."))
        do {
            _ = try await explainer.ask(ExplainRequest(kind: .host, key: "a.example"))
            XCTFail("expected a parse error")
        } catch let error as LLMAnswer.ParseError {
            XCTAssertEqual(error, .noJSON)
        }
        XCTAssertTrue(try store.rules().isEmpty)
        XCTAssertNotNil(explainer.lastPrompt, "the prompt was still sent and is shown")
    }
}

final class ShellProviderTests: XCTestCase {
    func testPromptOnStdinAnswerOnStdout() async throws {
        let output = try await ShellProvider(command: "cat").explain("hello")
        XCTAssertEqual(output, "hello")
    }

    func testSchemaPlaceholderAndEmptyWorkingDirectory() async throws {
        let output = try await ShellProvider(command: "printf '%s' {schema} | head -c 1; echo; ls -A | wc -l | tr -d ' '").explain("")
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "{\n0")
    }

    func testFailureCarriesStderr() async {
        do {
            _ = try await ShellProvider(command: "echo boom >&2; exit 3").explain("")
            XCTFail("expected failure")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .failed(status: 3, stderr: "boom"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testFailureMessageFromEnvelopeWhenStderrIsEmpty() async {
        do {
            _ = try await ShellProvider(command: #"echo '{"type":"result","is_error":true,"result":"Not logged in"}'; exit 1"#).explain("")
            XCTFail("expected failure")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .failed(status: 1, stderr: "Not logged in"))
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(ShellProvider.failureMessage(in: "plain text\n"), "plain text")
    }

    func testTimeout() async {
        do {
            _ = try await ShellProvider(command: "sleep 5", timeout: 0.3).explain("")
            XCTFail("expected timeout")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testEmptyCommandIsNotConfigured() async {
        do {
            _ = try await ShellProvider(command: "  ").explain("")
            XCTFail("expected notConfigured")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .notConfigured)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
