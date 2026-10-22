import Foundation

/**
 Error thrown by PushNotifications.

 *Values*

 `instanceId` The instance id was already registered.
 */
public enum AlreadyRegisteredError: Error {
    /**
     Instance id was already registered with Hikibi Push.

     - Parameter: instanceId
     */
    case instanceId(String)
}
