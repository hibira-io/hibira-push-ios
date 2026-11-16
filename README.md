# Hibira Push and Chat for iOS and macOS

This package has two libraries: `HibiraPush` for push notifications, and
`HibiraChat` for the [Hibira Chat API](https://hibira.io/chat-api)
(see [Chat](#chat)).

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
.package(url: "https://github.com/hibira-io/hibira-push-ios", from: "1.1.0")
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

The value set in code wins over Info.plist.

## Chat

`HibiraChat` talks to the Chat API's user routes and keeps conversations
live. It has no dependencies: `ChatSocket` connects over
`URLSessionWebSocketTask`, signs in as the user and receives the `chat.*`
events on the user's channel. `ConversationModel` and
`ConversationListModel` are `ObservableObject`s for SwiftUI (or UIKit with
Combine).

Add the `HibiraChat` product of this package to your target
(`from: "1.2.0"`).

### Your server

The app needs two things from your backend, both signed with the app
secret, so the secret never ships in the app:

1. A **user token** for the HTTP calls: an HS256 JWT `{"sub": userId, "exp": ...}`
   (or one from the Chat API's `POST /apps/{app_id}/chat/tokens`).
2. A **user authentication endpoint** for the realtime connection, the same
   one `pusher.signin()` uses. With the Node `pusher` library:

```js
app.post('/chat/token', requireLogin, (req, res) => {
  const token = jwt.sign({ sub: req.user.id }, process.env.HIBIRA_SECRET,
    { algorithm: 'HS256', expiresIn: '1h' });
  res.json({ token });
});

app.post('/pusher/user-auth', requireLogin, (req, res) => {
  res.json(pusher.authenticateUser(req.body.socket_id, { id: req.user.id }));
});
```

Your server also creates conversations and adds members (`PUT
/apps/{app_id}/chat/conversations/{id}`); apps cannot.

### Usage

```swift
import HibiraChat
import SwiftUI

let chat = ChatClient(appId: "YOUR_APP_ID") { try await API.fetchChatToken() }
let socket = ChatSocket(key: "YOUR_APP_KEY", client: chat,
                        authenticator: ChatSocket.endpoint(
                            URL(string: "https://your-backend.example.com/pusher/user-auth")!,
                            headers: ["Authorization": "Bearer \(session)"]))
socket.connect()

struct RoomView: View {
    @StateObject var room: ConversationModel
    @State private var draft = ""

    var body: some View {
        List {
            if room.hasOlder {
                Button("Earlier messages") { Task { await room.loadOlder() } }
            }
            ForEach(room.messages) { m in
                Text(m.isDeleted ? "Message deleted" : "\(m.name ?? m.sender ?? ""): \(m.text)")
            }
            if !room.typing.isEmpty { Text("\(room.typing.sorted().joined(separator: ", ")) typing…") }
        }
        .safeAreaInset(edge: .bottom) {
            TextField("Message", text: $draft)
                .onChange(of: draft) { _ in room.userIsTyping() }
                .onSubmit { Task { try await room.send(draft); draft = "" } }
        }
        .onAppear { room.start() }
        .onDisappear { room.stop() }
        .task(id: room.lastSeq) { try? await room.markRead() }
    }
}

// RoomView(room: ConversationModel(client: chat, conversationId: "trip-1"))
// ConversationListModel(client: chat) lists the user's conversations with unread counts.
```

`ConversationModel` re-reads the newest messages each time the socket comes
back, so edits, deletes and reactions made while the app was offline show
up. `ChatClient` has every user route: `conversations`, `conversation`,
`messages` (`after`, `last`, `limit`), `search`, `send`, `edit`, `delete`,
`react`, `unreact`, `report`, `read`, `typing`, `translate`,
`setLanguage`, `me` and `upload` (straight to storage, up to 25 MB; send
the returned `ChatAttachment` in a message). Errors are `ChatError` with
the HTTP status.

**Translations.** Set the user's language once (`chat.setLanguage("ja")`)
and messages from others arrive translated a moment later
(`chat.message_updated`). `message.text(for: "ja")` gives the translation
when there is one, else the original text; `room.translate(seq, language: "ja")`
translates one message on request. Translation needs a Chat add-on on the
hosted service.

If your app already runs a Pusher client that signs in, skip `ChatSocket`
and pass the user's events to `chat.handleEvent(name:data:)`, then call
`chat.notifyLive()` after each reconnect.

Offline messages arrive as push notifications through `HibiraPush`,
registered under the same user ID (`setUserId`).

### 中文摘要

`HibiraChat` 是 Hibira Chat API 的 iOS / macOS 用戶端，沒有其他相依套件：`ChatClient` 呼叫使用者路由（對話、訊息紀錄、傳送、編輯、刪除、表情回應、檢舉、已讀、輸入中、翻譯、使用者語言、附件上傳），`ChatSocket` 用 `URLSessionWebSocketTask` 連線並以使用者身分登入，收 `chat.*` 即時事件。`ConversationModel`（單一對話：訊息、往前翻頁、輸入中、已讀，重連後自動補齊）和 `ConversationListModel`（含未讀數的對話列表）是可直接給 SwiftUI 用的 `ObservableObject`。App 需要你的後端提供使用者 token（用 app secret 簽的 JWT）和使用者認證端點（`pusher.authenticateUser`）；建立對話、加成員仍由你的後端呼叫。

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
Copyright (c) 2017 Pusher.
