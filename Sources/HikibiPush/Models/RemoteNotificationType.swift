import Foundation

// swiftlint:disable identifier_name

/**
 Remote Notification Type tells you whether a notification was sent only for the SDK.
 Whenever you receive a push notification, call `handleNotification(userInfo:)`.
 Some notifications are only for the SDK to handle.

 *Values*

 `ShouldIgnore` It's safe to ignore a notification the SDK sent for itself.

 `ShouldProcess` Do not ignore notification as it may contain additional data.
 */
@objc public enum RemoteNotificationType: Int {
    /**
     Ignore a notification the SDK sent for itself.
     */
    case ShouldIgnore
    /**
     Do not ignore notification.
     */
    case ShouldProcess
}
