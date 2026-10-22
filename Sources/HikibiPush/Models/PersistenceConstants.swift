import Foundation

struct PersistenceConstants {
    struct UserDefaults {
        static func suiteName(instanceId: String?) -> String {
            if instanceId == nil {
                return "PushNotifications"
            } else {
                return "PushNotifications.\(instanceId!)"
            }
        }

        static let globalSuiteName = "PushNotificationsInstances"
        static let metadataSDKVersion = "io.hikibi.push.metadata.sdkVersion"
        static let metadataiOSVersion = "io.hikibi.push.metadata.iosVersion"
        static let metadataMacOSVersion = "io.hikibi.push.metadata.macosVersion"
        static let deviceId = "io.hikibi.push.deviceId"
        static let deviceAPNsToken = "io.hikibi.push.deviceAPNsToken"
        static let instanceId = "io.hikibi.push.instanceId"
    }

    struct PersistenceService {
        static let instanceIdsPrefix = "io.hikibi.push.instanceIds"
        static let prefix = "io.hikibi.push.interests"
        static let userId = "io.hikibi.push.user.id"
        static let hashKey = "interestsHash"
        static let globalScopeId = "io.hikibi.push"
    }

    struct PushNotificationsInstancePersistence {
        static let userId = "io.hikibi.push.pni.user.id.called.with"
        static let startJob = "io.hikibi.push.pni.start.job.enqueued"
    }
}
