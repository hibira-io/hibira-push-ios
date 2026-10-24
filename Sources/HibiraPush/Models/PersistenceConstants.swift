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
        static let metadataSDKVersion = "io.hibira.push.metadata.sdkVersion"
        static let metadataiOSVersion = "io.hibira.push.metadata.iosVersion"
        static let metadataMacOSVersion = "io.hibira.push.metadata.macosVersion"
        static let deviceId = "io.hibira.push.deviceId"
        static let deviceAPNsToken = "io.hibira.push.deviceAPNsToken"
        static let instanceId = "io.hibira.push.instanceId"
    }

    struct PersistenceService {
        static let instanceIdsPrefix = "io.hibira.push.instanceIds"
        static let prefix = "io.hibira.push.interests"
        static let userId = "io.hibira.push.user.id"
        static let hashKey = "interestsHash"
        static let globalScopeId = "io.hibira.push"
    }

    struct PushNotificationsInstancePersistence {
        static let userId = "io.hibira.push.pni.user.id.called.with"
        static let startJob = "io.hibira.push.pni.start.job.enqueued"
    }
}
