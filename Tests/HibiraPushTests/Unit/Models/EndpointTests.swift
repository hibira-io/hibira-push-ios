@testable import HibiraPush
import XCTest

class EndpointTests: XCTestCase {

    override func tearDown() {
        Endpoint.set(nil)
        super.tearDown()
    }

    func testDefaultEndpoint() {
        XCTAssertEqual(Endpoint.current, "https://ws.hibira.io")
        XCTAssertEqual(URL.PushNotifications.devices(instanceId: "abc")?.absoluteString,
                       "https://ws.hibira.io/device_api/v1/instances/abc/devices/apns")
        XCTAssertEqual(URL.PushNotifications.events(instanceId: "abc")?.absoluteString,
                       "https://ws.hibira.io/reporting_api/v2/instances/abc/events")
    }

    func testSetEndpoint() {
        PushNotifications.shared.setEndpoint(" https://push.example.com/ ")
        XCTAssertEqual(PushNotifications.shared.endpoint, "https://push.example.com")
        XCTAssertEqual(URL.PushNotifications.device(instanceId: "abc", deviceId: "d1")?.absoluteString,
                       "https://push.example.com/device_api/v1/instances/abc/devices/apns/d1")

        PushNotifications.shared.setEndpoint("")
        XCTAssertEqual(PushNotifications.shared.endpoint, "https://ws.hibira.io")
    }
}
