import XCTest
@testable import tattle

final class UserNameTests: XCTestCase {
    func testRootYouDirectoryNamesAndUnknown() {
        XCTAssertEqual(UserName.describe(0), "root")
        let login = String(cString: getpwuid(getuid()).pointee.pw_name)
        XCTAssertEqual(UserName.describe(getuid()), "you (\(login))")
        XCTAssertEqual(UserName.describe(89), "_spotlight", "a system account by its directory name")
        XCTAssertEqual(UserName.describe(4_000_000_000), "user 4000000000")
    }
}
