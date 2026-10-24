@testable import HibiraPush
import XCTest

class SystemVersionTests: XCTestCase {
    func testSystemVersion() {
        XCTAssertNotNil(SystemVersion.version)
    }
}
