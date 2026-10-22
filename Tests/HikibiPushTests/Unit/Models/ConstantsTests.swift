@testable import HikibiPush
import XCTest

class ConstantsTests: XCTestCase {
    func testUserDefaultsConstants() {
        XCTAssertEqual(PersistenceConstants.UserDefaults.suiteName(instanceId: nil), "PushNotifications")
        XCTAssertEqual(PersistenceConstants.UserDefaults.suiteName(
            instanceId: "1b880590-6301-4bb5-b34f-45db1c5f5644"),
                       "PushNotifications.1b880590-6301-4bb5-b34f-45db1c5f5644")
        XCTAssertEqual(PersistenceConstants.UserDefaults.metadataSDKVersion, "io.hikibi.push.metadata.sdkVersion")
        XCTAssertEqual(PersistenceConstants.UserDefaults.metadataiOSVersion, "io.hikibi.push.metadata.iosVersion")
        XCTAssertEqual(PersistenceConstants.UserDefaults.metadataMacOSVersion, "io.hikibi.push.metadata.macosVersion")
        XCTAssertEqual(PersistenceConstants.UserDefaults.deviceId, "io.hikibi.push.deviceId")
        XCTAssertEqual(PersistenceConstants.UserDefaults.instanceId, "io.hikibi.push.instanceId")
    }

    func testPersistanceServiceConstants() {
        XCTAssertEqual(PersistenceConstants.PersistenceService.prefix, "io.hikibi.push.interests")
        XCTAssertEqual(PersistenceConstants.PersistenceService.hashKey, "interestsHash")
    }

    func testDispatchQueueConstants() {
        XCTAssertEqual(Constants.DispatchQueue.preIISOperationQueue, "io.hikibi.push.pre.iis.operation.queue")
        XCTAssertEqual(Constants.DispatchQueue.persistenceStorageOperationQueue, "io.hikibi.push.persistence.storage.operation.queue")
    }

    func testReportEventTypeConstants() {
        XCTAssertEqual(Constants.ReportEventType.open, "Open")
        XCTAssertEqual(Constants.ReportEventType.delivery, "Delivery")
    }
}
