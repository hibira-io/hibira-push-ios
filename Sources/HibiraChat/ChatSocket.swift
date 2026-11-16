import Combine
import Foundation

/// A signed user, as your user authentication endpoint returns it: `{"auth": ..., "user_data": ...}`.
public struct UserAuth: Sendable {
    public var auth: String
    public var userData: String

    public init(auth: String, userData: String) {
        self.auth = auth
        self.userData = userData
    }
}

/// A realtime connection that signs in as the user (`pusher:signin`) and
/// feeds the Chat API events on `#server-to-user-<id>` to a ``ChatClient``.
/// It speaks the Pusher Channels protocol itself, so it needs no other
/// library; if your app already runs a Pusher client that signs in, forward
/// its user events to ``ChatClient/handleEvent(name:data:)`` instead.
///
/// `key` is the app key (not the app ID). It reconnects with backoff until
/// ``disconnect()``.
public final class ChatSocket: @unchecked Sendable {
    public enum State: Sendable {
        case disconnected, connecting, connected
        /// Signed in and subscribed to the user's channel.
        case live
    }

    public typealias Authenticator = @Sendable (_ socketId: String) async throws -> UserAuth

    public static let defaultHost = "ws.hibira.io"

    /// The connection state; `.live` once chat events can arrive.
    public let statePublisher = CurrentValueSubject<State, Never>(.disconnected)
    public var state: State { statePublisher.value }

    /// The signed-in user's ID, once signed in.
    public var userId: String? { queue.sync { signedInUser } }

    /// The last error the server or the authenticator gave, if any.
    public var lastError: String? { queue.sync { errorText } }

    private let url: URL
    private let client: ChatClient
    private let authenticator: Authenticator
    private let session: URLSession
    private let queue = DispatchQueue(label: "io.hibira.chat.socket")
    private var task: URLSessionWebSocketTask?
    private var generation = 0
    private var wanted = false
    private var socketId: String?
    private var signedInUser: String?
    private var errorText: String?
    private var errorCode: Int?
    private var attempt = 0
    private var lastActivity = Date()
    private var activityTimeout: TimeInterval = 120
    private let pongTimeout: TimeInterval = 30

    /// For tests: replaces the WebSocket when set.
    var transport: ((String) -> Void)?

    public init(key: String, client: ChatClient, host: String = ChatSocket.defaultHost,
                session: URLSession = .shared, authenticator: @escaping Authenticator) {
        var h = host
        while h.hasSuffix("/") { h.removeLast() }
        if !h.hasPrefix("ws://") && !h.hasPrefix("wss://") { h = "wss://" + h }
        url = URL(string: "\(h)/app/\(ChatClient.segment(key))?protocol=7&client=hibira-chat-swift&version=\(ChatClient.version)&flash=false")!
        self.client = client
        self.authenticator = authenticator
        self.session = session
    }

    public func connect() {
        queue.async {
            self.wanted = true
            if self.task == nil { self.open() }
        }
    }

    public func disconnect() {
        queue.async {
            self.wanted = false
            self.generation += 1
            self.task?.cancel(with: .normalClosure, reason: nil)
            self.task = nil
            self.socketId = nil
            self.signedInUser = nil
            self.statePublisher.send(.disconnected)
        }
    }

    // MARK: Connection (on queue)

    private func open() {
        generation += 1
        let g = generation
        errorCode = nil
        statePublisher.send(.connecting)
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receive(t, g)
    }

    private func receive(_ t: URLSessionWebSocketTask, _ g: Int) {
        t.receive { [weak self] result in
            guard let self = self else { return }
            self.queue.async {
                guard g == self.generation else { return }
                switch result {
                case .success(.string(let text)):
                    self.handle(text)
                    self.receive(t, g)
                case .success(.data(let data)):
                    self.handle(String(decoding: data, as: UTF8.self))
                    self.receive(t, g)
                case .success:
                    self.receive(t, g)
                case .failure(let error):
                    self.errorText = self.errorText ?? error.localizedDescription
                    self.dropped(g)
                }
            }
        }
    }

    private func send(_ event: String, _ data: [String: JSONValue]) {
        let msg: JSONValue = ["event": .string(event), "data": .object(data)]
        guard let json = try? JSONEncoder().encode(msg), let text = String(data: json, encoding: .utf8) else { return }
        if let transport = transport {
            transport(text)
        } else {
            task?.send(.string(text)) { _ in }
        }
    }

    private static func decode(_ value: JSONValue?) -> JSONValue? {
        if case .string(let s)? = value, let v = try? JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) {
            return v
        }
        return value
    }

    /// Handles one protocol message (on the queue).
    func handle(_ text: String) {
        lastActivity = Date()
        guard let msg = try? JSONDecoder().decode([String: JSONValue].self, from: Data(text.utf8)),
              let event = msg["event"]?.stringValue else { return }
        let data = ChatSocket.decode(msg["data"])
        let channel = msg["channel"]?.stringValue ?? ""
        switch event {
        case "pusher:connection_established":
            socketId = data?["socket_id"]?.stringValue
            if let t = data?["activity_timeout"]?.numberValue { activityTimeout = min(120, t) }
            attempt = 0
            statePublisher.send(.connected)
            scheduleWatchdog(generation)
            signIn(generation)
        case "pusher:signin_success":
            guard let userData = ChatSocket.decode(data?["user_data"]),
                  let id = userData["id"]?.stringValue ?? userData["id"]?.numberValue.map({ String(Int($0)) }) else { return }
            signedInUser = id
            send("pusher:subscribe", ["channel": .string("#server-to-user-\(id)")])
        case "pusher:error":
            errorText = data?["message"]?.stringValue ?? "error"
            errorCode = data?["code"]?.numberValue.map { Int($0) }
            if let code = errorCode, (4000..<4100).contains(code) { wanted = false }
        case "pusher:ping":
            send("pusher:pong", [:])
        case "pusher:pong":
            break
        default:
            guard channel.hasPrefix("#server-to-user-") else { return }
            if event == "pusher_internal:subscription_succeeded" {
                statePublisher.send(.live)
                client.notifyLive()
            } else if !event.hasPrefix("pusher") {
                let payload: Data
                if case .string(let s)? = msg["data"] {
                    payload = Data(s.utf8)
                } else {
                    payload = (try? JSONEncoder().encode(msg["data"] ?? .null)) ?? Data()
                }
                client.handleEvent(name: event, data: payload)
            }
        }
    }

    private func signIn(_ g: Int) {
        guard let sid = socketId else { return }
        let authenticator = self.authenticator
        Task {
            do {
                let auth = try await authenticator(sid)
                self.queue.async {
                    guard g == self.generation, sid == self.socketId else { return }
                    self.send("pusher:signin", ["auth": .string(auth.auth), "user_data": .string(auth.userData)])
                }
            } catch {
                self.queue.async { self.errorText = "sign-in failed: \(error.localizedDescription)" }
            }
        }
    }

    private func scheduleWatchdog(_ g: Int) {
        queue.asyncAfter(deadline: .now() + activityTimeout) { [weak self] in
            guard let self = self, g == self.generation, self.task != nil else { return }
            if Date().timeIntervalSince(self.lastActivity) < self.activityTimeout {
                self.scheduleWatchdog(g)
                return
            }
            self.send("pusher:ping", [:])
            self.queue.asyncAfter(deadline: .now() + self.pongTimeout) {
                guard g == self.generation else { return }
                if Date().timeIntervalSince(self.lastActivity) >= self.activityTimeout + self.pongTimeout {
                    self.task?.cancel(with: .goingAway, reason: nil)
                    self.dropped(g)
                } else {
                    self.scheduleWatchdog(g)
                }
            }
        }
    }

    private func dropped(_ g: Int) {
        guard g == generation else { return }
        generation += 1
        task = nil
        socketId = nil
        signedInUser = nil
        statePublisher.send(.disconnected)
        let code = errorCode ?? 0
        guard wanted, !(4000..<4100).contains(code) else { return }
        let wait: TimeInterval = (4200..<4300).contains(code) ? 0 : min(30, pow(2, Double(min(attempt, 5))))
        attempt += 1
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self = self, self.wanted, self.task == nil else { return }
            self.open()
        }
    }

    /// An authenticator that POSTs `socket_id` as a form to your endpoint
    /// (the one pusher-js uses for `pusher.signin()`), with extra `headers`
    /// such as your session's `Authorization`.
    public static func endpoint(_ url: URL, headers: [String: String] = [:],
                                session: URLSession = .shared) -> Authenticator {
        return { socketId in
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
            let sid = socketId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? socketId
            req.httpBody = Data("socket_id=\(sid)".utf8)
            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = try? JSONDecoder().decode([String: JSONValue].self, from: data)
            guard status == 200, let auth = body?["auth"]?.stringValue, let userData = body?["user_data"] else {
                throw ChatError(status: status, message: body?["error"]?.stringValue ?? "user auth endpoint answered \(status)")
            }
            let userDataText: String
            if case .string(let s) = userData {
                userDataText = s
            } else {
                userDataText = String(decoding: try JSONEncoder().encode(userData), as: UTF8.self)
            }
            return UserAuth(auth: auth, userData: userDataText)
        }
    }
}
