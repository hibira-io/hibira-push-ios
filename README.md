# Hibira Push for iOS and macOS

Swift client for [Hibira Push](https://hibira.io), the push notification
service of Hibira. Hibira Push speaks a Beams-compatible device API, and this
package is an MIT-licensed fork of `pusher/push-notifications-swift` 4.1.0
with the host made configurable.

- iOS 15 or macOS 12 and later.
- Delivery uses APNs. Upload your APNs `.p8` key in the Hibira portal (app
  page, Push notifications) and enable the Push Notifications capability in Xcode.

## Installation

Swift Package Manager only. In Xcode choose File > Add Package Dependencies
and enter `https://github.com/hibira-io/hibira-push-ios`, or in `Package.swift`:

```swift
.package(url: "https://github.com/hibira-io/hibira-push-ios", from: "1.0.0")
```

and add the `HibiraPush` product to your target.

## Usage

```swift
import HibiraPush

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        PushNotifications.shared.start(instanceId: "YOUR_INSTANCE_ID")
        PushNotifications.shared.registerForRemoteNotifications()
        try? PushNotifications.shared.addDeviceInterest(interest: "hello")
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushNotifications.shared.registerDeviceToken(deviceToken)
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        PushNotifications.shared.handleNotification(userInfo: userInfo)
        completionHandler(.noData)
    }
}
```

The instance ID is shown in the portal on the app's Push notifications card.

### Authenticated users

```swift
let tokenProvider = PushTokenProvider(authURL: "https://your-backend.example.com/push-auth") {
    AuthData(headers: ["Authorization": "Bearer \(sessionToken)"], queryParams: [:])
}

PushNotifications.shared.setUserId("user-1", tokenProvider: tokenProvider) { error in
    if let error = error { print(error) }
}
```

Your backend returns `{"token": "..."}`, made with `generateToken` from any
Beams-compatible server SDK and your Hibira secret key.

### Host

The SDK uses `https://ws.hibira.io`. Self-hosted servers or another region can
set the host in Info.plist:

```xml
<key>HibiraPushEndpoint</key>
<string>https://push.example.com</string>
```

or in code, before `start`:

```swift
PushNotifications.shared.setEndpoint("https://push.example.com")
```

The value set in code wins over Info.plist. The pre-rename key
`HikibiPushEndpoint` is still read.

## Moving from the Beams Swift SDK

| Before | After |
|---|---|
| `https://github.com/pusher/push-notifications-swift` | `https://github.com/hibira-io/hibira-push-ios` |
| `import PushNotifications` | `import HibiraPush` |
| `BeamsTokenProvider` | `PushTokenProvider` |
| `PusherAlreadyRegisteredError` | `AlreadyRegisteredError` |

`PushNotifications`, `PushNotifications.shared` and the delegate protocols keep
their names. Devices register again on first start with the new SDK.

## Testing

```sh
swift test
```

The unit tests run on macOS. The upstream integration tests needed live
instances and are not included.

## License

MIT. See [LICENSE](LICENSE). Based on
[pusher/push-notifications-swift](https://github.com/pusher/push-notifications-swift),
Copyright (c) 2017 Pusher. Hibira is not affiliated with Pusher.
