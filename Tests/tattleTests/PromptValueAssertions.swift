import XCTest
@testable import tattle

extension XCTestCase {
    /// What a prompt carries of the facts that could name the user. A development certificate's
    /// summary holds the team and no name, so the panel and a prompt share it. The account
    /// differs: the panel names the login, a prompt says only "you".
    func assertPromptValues(_ facts: [Fact], runsAs: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let signed = facts.first { $0.name == "Signed by" }
        XCTAssertEqual(signed?.value, "Apple Development (ABCDE12345)", file: file, line: line)
        XCTAssertNil(signed?.promptValue, "the panel's value carries no name, so the model gets it too", file: file, line: line)
        guard runsAs else { return }
        let login = String(cString: getpwuid(getuid()).pointee.pw_name)
        let account = facts.first { $0.name == "Runs as" }
        XCTAssertEqual(account?.value, "you (\(login))", file: file, line: line)
        XCTAssertEqual(account?.promptValue, "you", file: file, line: line)
    }
}
