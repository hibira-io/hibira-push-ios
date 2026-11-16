import Combine
import Foundation

/// The Hibira Chat API as the signed-in user (the client routes under
/// `/apps/{appId}/chat/me`).
///
/// `token` returns a user token: an HS256 JWT your server signs with the app
/// secret (`{"sub": userId, "exp": ...}`), or one from the API's
/// `POST /chat/tokens`. It is called again before the token expires and after
/// a 401.
///
/// Live events come from a ``ChatSocket``, or from your own Pusher client
/// through ``handleEvent(name:data:)``.
public final class ChatClient: @unchecked Sendable {
    public static let defaultHost = "api.hibira.io"
    public static let version = "1.2.0"

    public let appId: String
    private let base: String
    private let session: URLSession
    private let tokenProvider: @Sendable () async throws -> String
    private let lock = NSLock()
    private var cachedToken: String?
    private var pendingToken: Task<String, Error>?

    /// Chat events for this user, from ``handleEvent(name:data:)`` or a ``ChatSocket``.
    public let events = PassthroughSubject<ChatEvent, Never>()

    /// Fires each time the realtime connection is (re)established, so views can read what they missed.
    public let live = PassthroughSubject<Void, Never>()

    public init(appId: String,
                host: String = ChatClient.defaultHost,
                session: URLSession = .shared,
                token: @escaping @Sendable () async throws -> String) {
        self.appId = appId
        self.session = session
        self.tokenProvider = token
        var h = host
        while h.hasSuffix("/") { h.removeLast() }
        if !h.hasPrefix("http://") && !h.hasPrefix("https://") { h = "https://" + h }
        base = "\(h)/apps/\(ChatClient.segment(appId))/chat/me"
    }

    /// The token's user (its `sub`), once a token has been fetched; "" before.
    public var userId: String {
        locked { cachedToken.map(ChatClient.tokenUser) ?? "" }
    }

    /// Fetches the token now (if needed) and returns its user.
    public func currentUser() async throws -> String {
        ChatClient.tokenUser(try await currentToken(force: false))
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func currentToken(force: Bool) async throws -> String {
        let task: Task<String, Error> = locked { () -> Task<String, Error> in
            if !force, let t = cachedToken, !ChatClient.expiresSoon(t) {
                return Task<String, Error> { t }
            }
            if let p = pendingToken { return p }
            let p = Task<String, Error> { [tokenProvider] in try await tokenProvider() }
            pendingToken = p
            return p
        }
        do {
            let t = try await task.value
            locked { () -> Void in
                cachedToken = t
                if pendingToken == task { pendingToken = nil }
            }
            return t
        } catch {
            locked { () -> Void in if pendingToken == task { pendingToken = nil } }
            throw error
        }
    }

    // MARK: Events

    /// Feeds an event received on the user's `#server-to-user-<id>` channel
    /// (after `pusher.signin()`), as its name and JSON data. Returns true when
    /// it was a chat event.
    @discardableResult
    public func handleEvent(name: String, data: String) -> Bool {
        handleEvent(name: name, data: Data(data.utf8))
    }

    @discardableResult
    public func handleEvent(name: String, data: Data) -> Bool {
        guard let event = ChatEvent(name: name, data: data) else { return false }
        events.send(event)
        return true
    }

    /// The chat events from now on, as an async sequence (ends when the task is cancelled).
    public func eventStream() -> AsyncStream<ChatEvent> {
        AsyncStream { continuation in
            let sub = events.sink { continuation.yield($0) }
            continuation.onTermination = { _ in sub.cancel() }
        }
    }

    /// Each (re)connection of the realtime connection from now on.
    public func liveStream() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let sub = live.sink { continuation.yield(()) }
            continuation.onTermination = { _ in sub.cancel() }
        }
    }

    /// Tell views the realtime connection is (back) up, when you feed events from your own client.
    public func notifyLive() {
        live.send(())
    }

    // MARK: Requests

    static func segment(_ s: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/;?#%")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private func conv(_ id: String) -> String { "/conversations/\(ChatClient.segment(id))" }

    func call(_ method: String, _ path: String, body: [String: JSONValue]? = nil,
              query: [String: String?] = [:]) async throws -> Data {
        var comps = URLComponents(string: base + path)!
        let items = query.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }.sorted { $0.name < $1.name }
        if !items.isEmpty {
            comps.queryItems = items
            comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        let payload = try body.map { try JSONEncoder().encode($0) }
        for attempt in 0..<2 {
            let token = try await currentToken(force: attempt > 0)
            var req = URLRequest(url: comps.url!)
            req.httpMethod = method
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("hibira-chat-swift/\(ChatClient.version)", forHTTPHeaderField: "X-Hibira-Client")
            if let payload = payload {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = payload
            }
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await session.data(for: req)
            } catch {
                throw ChatError(status: 0, message: error.localizedDescription)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && attempt == 0 { continue }
            if status >= 400 {
                let err = (try? JSONDecoder().decode([String: JSONValue].self, from: data))?["error"]?.stringValue
                throw ChatError(status: status, message: err ?? "Chat API request failed (\(status))")
            }
            return data
        }
        throw ChatError(status: 401, message: "unauthorized")
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ChatError(status: 0, message: "unexpected answer: \(error)")
        }
    }

    private struct MessageBox: Decodable { var message: ChatMessage }
    private struct ConversationBox: Decodable { var conversation: ChatConversation }
    private struct ReportBox: Decodable { var report: ChatReport }
    private struct ConversationList: Decodable { var conversations: [ChatConversation]?; var next: String? }
    private struct MessageList: Decodable {
        var messages: [ChatMessage]?
        var lastSeq: Int?
        var next: String?
        enum CodingKeys: String, CodingKey { case messages, next, lastSeq = "last_seq" }
    }
    private struct Push: Decodable { var users: Int?; var error: String? }
    private struct Sent: Decodable { var message: ChatMessage; var push: Push? }
    private struct ReadAnswer: Decodable {
        var readSeq: Int?
        enum CodingKeys: String, CodingKey { case readSeq = "read_seq" }
    }
    private struct Upload: Decodable {
        var url: String
        var method: String?
        var headers: [String: String]?
    }
    private struct UploadAnswer: Decodable { var attachment: ChatAttachment; var upload: Upload }

    /// The user's conversations, latest activity first, each with its unread count.
    public func conversations(limit: Int? = nil, before: String? = nil) async throws -> ChatConversationPage {
        let d = try decode(ConversationList.self, try await call("GET", "/conversations",
                                                                 query: ["limit": limit.map { String($0) }, "before": before]))
        return ChatConversationPage(conversations: d.conversations ?? [], next: d.next ?? "")
    }

    public func conversation(_ id: String) async throws -> ChatConversation {
        try decode(ConversationBox.self, try await call("GET", conv(id))).conversation
    }

    /// Messages oldest first: those after `after` (up to `limit`, at most 200), or the newest `last`.
    public func messages(_ id: String, after: Int? = nil, last: Int? = nil, limit: Int? = nil) async throws -> ChatMessagePage {
        let d = try decode(MessageList.self, try await call("GET", conv(id) + "/messages", query: [
            "after": after.map { String($0) }, "last": last.map { String($0) }, "limit": limit.map { String($0) },
        ]))
        return ChatMessagePage(messages: d.messages ?? [], lastSeq: d.lastSeq ?? 0)
    }

    /// Messages containing `query` (inside words, ignoring case), newest first.
    public func search(_ id: String, query q: String, before: String? = nil, limit: Int? = nil) async throws -> ChatSearchPage {
        let d = try decode(MessageList.self, try await call("GET", conv(id) + "/search", query: [
            "q": q, "before": before, "limit": limit.map { String($0) },
        ]))
        return ChatSearchPage(messages: d.messages ?? [], next: d.next ?? "")
    }

    /// Sends a message as the user. `visibleTo` may hold only the user's own role.
    @discardableResult
    public func send(_ id: String, text: String, metadata: [String: JSONValue]? = nil,
                     attachments: [ChatAttachment] = [], name: String? = nil,
                     visibleTo: [String]? = nil) async throws -> ChatSendResult {
        var body: [String: JSONValue] = ["text": .string(text)]
        if let metadata = metadata { body["metadata"] = .object(metadata) }
        if !attachments.isEmpty {
            body["attachments"] = .array(attachments.map {
                .object(["id": .string($0.id), "name": .string($0.name), "content_type": .string($0.contentType)])
            })
        }
        if let name = name { body["name"] = .string(name) }
        if let visibleTo = visibleTo { body["visible_to"] = .array(visibleTo.map(JSONValue.string)) }
        let d = try decode(Sent.self, try await call("POST", conv(id) + "/messages", body: body))
        return ChatSendResult(message: d.message, pushedUsers: d.push?.users, pushError: d.push?.error)
    }

    /// Edits the user's own message; `metadata` nil keeps it.
    @discardableResult
    public func edit(_ id: String, seq: Int, text: String, metadata: [String: JSONValue]? = nil) async throws -> ChatMessage {
        var body: [String: JSONValue] = ["text": .string(text)]
        if let metadata = metadata { body["metadata"] = .object(metadata) }
        return try decode(MessageBox.self, try await call("PUT", conv(id) + "/messages/\(seq)", body: body)).message
    }

    /// Deletes the user's own message; it keeps its place with `deletedAt` set.
    @discardableResult
    public func delete(_ id: String, seq: Int) async throws -> ChatMessage {
        try decode(MessageBox.self, try await call("DELETE", conv(id) + "/messages/\(seq)")).message
    }

    @discardableResult
    public func react(_ id: String, seq: Int, emoji: String) async throws -> ChatMessage {
        try decode(MessageBox.self, try await call("POST", conv(id) + "/messages/\(seq)/reactions",
                                                   body: ["emoji": .string(emoji)])).message
    }

    @discardableResult
    public func unreact(_ id: String, seq: Int, emoji: String) async throws -> ChatMessage {
        try decode(MessageBox.self, try await call("DELETE", conv(id) + "/messages/\(seq)/reactions",
                                                   query: ["emoji": emoji])).message
    }

    @discardableResult
    public func report(_ id: String, seq: Int, reason: String = "") async throws -> ChatReport {
        try decode(ReportBox.self, try await call("POST", conv(id) + "/messages/\(seq)/reports",
                                                  body: ["reason": .string(reason)])).report
    }

    /// Marks the conversation read up to `seq`; returns the user's read_seq (it never goes back).
    @discardableResult
    public func read(_ id: String, seq: Int) async throws -> Int {
        try decode(ReadAnswer.self, try await call("POST", conv(id) + "/read",
                                                   body: ["seq": .number(Double(seq))])).readSeq ?? seq
    }

    /// Tells the other members the user is typing (or stopped). Nothing is stored.
    public func typing(_ id: String, _ typing: Bool = true) async throws {
        _ = try await call("POST", conv(id) + "/typing", body: ["typing": .bool(typing)])
    }

    /// Translates message `seq` into `language` (a BCP 47 tag) and keeps it on
    /// the message. Needs a Chat add-on on the hosted service (403 on the free
    /// allowance, 429 past the monthly cap).
    @discardableResult
    public func translate(_ id: String, seq: Int, language: String) async throws -> ChatMessage {
        try decode(MessageBox.self, try await call("POST", conv(id) + "/messages/\(seq)/translations",
                                                   body: ["language": .string(language)])).message
    }

    /// The user's settings: `user_id` and `language`.
    public func me() async throws -> [String: JSONValue] {
        try decode([String: JSONValue].self, try await call("GET", "/"))
    }

    /// Sets the language messages are translated into for this user (a BCP 47
    /// tag such as `ja` or `zh-TW`; nil for none). Returns the language kept.
    @discardableResult
    public func setLanguage(_ language: String?) async throws -> String? {
        let d = try decode([String: JSONValue].self,
                           try await call("PUT", "/", body: ["language": language.map(JSONValue.string) ?? .null]))
        guard let l = d["language"]?.stringValue, !l.isEmpty else { return nil }
        return l
    }

    /// Uploads a file (up to 25 MB) straight to storage; send the returned
    /// attachment in a message's `attachments`.
    public func upload(_ id: String, name: String, contentType: String, data: Data) async throws -> ChatAttachment {
        let d = try decode(UploadAnswer.self, try await call("POST", conv(id) + "/attachments", body: [
            "name": .string(name), "content_type": .string(contentType), "size": .number(Double(data.count)),
        ]))
        guard let url = URL(string: d.upload.url) else { throw ChatError(status: 0, message: "no upload URL") }
        var req = URLRequest(url: url)
        req.httpMethod = d.upload.method ?? "PUT"
        d.upload.headers?.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (_, response) = try await session.upload(for: req, from: data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw ChatError(status: status, message: "upload failed (\(status))") }
        return d.attachment
    }

    // MARK: Tokens

    /// The user ID (`sub`) inside a user token, or "" when it cannot be read.
    public static func tokenUser(_ token: String) -> String {
        claims(token)["sub"]?.stringValue ?? ""
    }

    static func claims(_ token: String) -> [String: JSONValue] {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return [:] }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return [:] }
        return obj
    }

    static func expiresSoon(_ token: String) -> Bool {
        guard let exp = claims(token)["exp"]?.numberValue else { return false }
        return exp - Date().timeIntervalSince1970 < 30
    }
}
