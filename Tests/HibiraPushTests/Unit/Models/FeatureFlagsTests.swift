@testable import HibiraPush
import XCTest

class FeatureFlagsTests: XCTestCase {
    func testFeatureFlagDeliveryTrackingEnabledIsSetToTrue() {
        XCTAssertEqual(FeatureFlags.DeliveryTrackingEnabled, true)
    }
}
