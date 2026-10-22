@testable import HikibiPush
import XCTest

class SystemVersionTests: XCTestCase {
    func testSystemVersion() {
        XCTAssertNotNil(SystemVersion.version)
    }
}
