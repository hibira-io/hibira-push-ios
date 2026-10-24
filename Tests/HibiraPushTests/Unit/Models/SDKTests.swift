@testable import HibiraPush
import XCTest

class SDKTests: XCTestCase {
    func testVersionModel() {
        let version = SDK.version
        XCTAssertNotNil(version)
        XCTAssertEqual(version, "1.0.0")
    }
}
