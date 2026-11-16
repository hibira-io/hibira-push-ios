import Foundation
@testable import HibiraChat
import XCTest

func jwt(_ sub: String, exp: TimeInterval = Date().timeIntervalSince1970 + 3600) -> String {
    func b64(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    return b64(#"{"alg":"HS256"}"#) + "." + b64(#"{"sub":"\#(sub)","exp":\#(Int(exp))}"#) + ".sig"
}

/// Answers requests from a handler, and records them.
final class StubProtocol: URLProtocol {
    struct Recorded {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    static var handler: ((Recorded) -> (Int, String))?
    static var requests: [Recorded] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            stream.close()
        }
        let url = request.url!
        let path = url.path + (url.query.map { "?" + $0 } ?? "")
        let rec = Recorded(method: request.httpMethod ?? "GET", path: path,
                           headers: request.allHTTPHeaderFields ?? [:], body: body)
        StubProtocol.lock.lock()
        StubProtocol.requests.append(rec)
        StubProtocol.lock.unlock()
        let (status, text) = StubProtocol.handler?(rec) ?? (404, #"{"error":"not found"}"#)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

func stubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return URLSession(configuration: config)
}

func msg(_ seq: Int, sender: String = "bob", text: String? = nil) -> String {
    #"{"id":"id\#(seq)","seq":\#(seq),"sender":"\#(sender)","kind":"text","text":"\#(text ?? "m\(seq)")","created_at":"t\#(seq)"}"#
}

final class ChatClientTests: XCTestCase {
    override func setUp() {
        StubProtocol.requests = []
        StubProtocol.handler = nil
    }

    func testReadsTheUserFromTheToken() {
        XCTAssertEqual(ChatClient.tokenUser(jwt("ann")), "ann")
        XCTAssertEqual(ChatClient.tokenUser("nope"), "")
        XCTAssertTrue(ChatClient.expiresSoon(jwt("ann", exp: Date().timeIntervalSince1970 + 5)))
    }

    func testSendsToTheUserRoutes() async throws {
        StubProtocol.handler = { _ in
            (201, #"{"message":{"id":"m1","seq":4,"sender":"ann","text":"hi","metadata":{"reply_to":2},"reactions":{"👍":["bob"]}},"push":{"users":1}}"#)
        }
        let client = ChatClient(appId: "app-1", host: "https://chat.test", session: stubSession()) { jwt("ann") }
        let res = try await client.send("trip 1", text: "hi", metadata: ["reply_to": 2])
        XCTAssertEqual(res.message.seq, 4)
        XCTAssertEqual(res.message.reactions["👍"], ["bob"])
        XCTAssertEqual(res.message.metadata["reply_to"], 2)
        XCTAssertEqual(res.pushedUsers, 1)
        let req = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/apps/app-1/chat/me/conversations/trip 1/messages")
        XCTAssertTrue(req.headers["Authorization"]?.hasPrefix("Bearer ey") ?? false)
        let body = try JSONDecoder().decode([String: JSONValue].self, from: req.body)
        XCTAssertEqual(body["text"], "hi")
        XCTAssertEqual(body["metadata"]?["reply_to"], 2)
        XCTAssertEqual(client.userId, "ann")
    }

    func testFetchesANewTokenAfterA401() async throws {
        var calls = 0
        StubProtocol.handler = { _ in
            calls += 1
            return calls == 1 ? (401, #"{"error":"expired"}"#) : (200, #"{"messages":[\#(msg(1))],"last_seq":1}"#)
        }
        let tokens = Counter()
        let client = ChatClient(appId: "a", host: "https://chat.test", session: stubSession()) {
            await tokens.next()
            return jwt("ann")
        }
        let page = try await client.messages("c", last: 10)
        XCTAssertEqual(page.messages.count, 1)
        let n = await tokens.value
        XCTAssertEqual(n, 2)
        XCTAssertEqual(StubProtocol.requests.last?.path, "/apps/a/chat/me/conversations/c/messages?last=10")
    }

    func testThrowsTheApiError() async {
        StubProtocol.handler = { _ in (403, #"{"error":"you are muted"}"#) }
        let client = ChatClient(appId: "a", host: "https://chat.test", session: stubSession()) { jwt("ann") }
        do {
            try await client.typing("c")
            XCTFail("expected an error")
        } catch let e as ChatError {
            XCTAssertEqual(e.status, 403)
            XCTAssertEqual(e.message, "you are muted")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testSetsTheLanguageAndTranslates() async throws {
        StubProtocol.handler = { req in
            if req.path.hasSuffix("/translations") {
                return (200, #"{"message":{"seq":3,"text":"hi","language":"en","translations":{"ja":"やあ"}}}"#)
            }
            return (200, #"{"user_id":"ann","language":"ja"}"#)
        }
        let client = ChatClient(appId: "a", host: "https://chat.test", session: stubSession()) { jwt("ann") }
        let lang = try await client.setLanguage("ja")
        XCTAssertEqual(lang, "ja")
        XCTAssertEqual(StubProtocol.requests.first?.method, "PUT")
        XCTAssertTrue(["/apps/a/chat/me", "/apps/a/chat/me/"].contains(StubProtocol.requests.first?.path ?? ""))
        let m = try await client.translate("c", seq: 3, language: "ja")
        XCTAssertEqual(m.text(for: "ja"), "やあ")
        XCTAssertEqual(m.text(for: "ko"), "hi")
        XCTAssertEqual(StubProtocol.requests.last?.path, "/apps/a/chat/me/conversations/c/messages/3/translations")
    }

    func testParsesEvents() {
        let e = ChatEvent(name: "chat.read", data: Data(#"{"conversation_id":"c","user_id":"bob","read_seq":7}"#.utf8))
        XCTAssertEqual(e, .read(conversationId: "c", userId: "bob", readSeq: 7))
        XCTAssertNil(ChatEvent(name: "other", data: Data("{}".utf8)))
        XCTAssertNil(ChatEvent(name: "chat.left", data: Data("{}".utf8)))
    }
}

actor Counter {
    var value = 0
    func next() { value += 1 }
}

@MainActor
final class ConversationModelTests: XCTestCase {
    func testLoadsPagesAppliesEventsAndCatchesUp() async throws {
        StubProtocol.requests = []
        StubProtocol.handler = { req in
            let path = req.path.replacingOccurrences(of: "/apps/a/chat/me", with: "")
            func list(_ r: ClosedRange<Int>, last: Int = 120) -> String {
                #"{"messages":[\#(r.map { msg($0) }.joined(separator: ","))],"last_seq":\#(last)}"#
            }
            switch path {
            case "/conversations/c":
                return (200, #"{"conversation":{"id":"c","members":[{"user_id":"ann","read_seq":3},{"user_id":"bob","read_seq":5}],"last_seq":120}}"#)
            case "/conversations/c/messages?last=50": return (200, list(71...120))
            case "/conversations/c/messages?after=20&limit=50": return (200, list(21...70))
            case "/conversations/c/messages?after=0&limit=20": return (200, list(1...20))
            case "/conversations/c/read": return (200, #"{"read_seq":121}"#)
            default:
                if path.hasPrefix("/conversations/c/messages?after=121") { return (200, list(121...121, last: 121)) }
                if path.hasPrefix("/conversations/c/messages?last=") {
                    return (200, #"{"messages":[\#(msg(120, text: "edited")),\#(msg(121))],"last_seq":121}"#)
                }
                return (404, #"{"error":"not found"}"#)
            }
        }
        let client = ChatClient(appId: "a", host: "https://chat.test", session: stubSession()) { jwt("ann") }
        let model = ConversationModel(client: client, conversationId: "c")
        await model.refresh()
        XCTAssertEqual(model.messages.count, 50)
        XCTAssertTrue(model.hasOlder)
        XCTAssertEqual(model.reads["bob"], 5)

        await model.loadOlder()
        await model.loadOlder()
        XCTAssertEqual(model.messages.map(\.seq), Array(1...120))
        XCTAssertFalse(model.hasOlder)

        model.apply(.typing(conversationId: "c", userId: "bob", typing: true))
        XCTAssertEqual(model.typing, ["bob"])
        let m121 = try JSONDecoder().decode(ChatMessage.self, from: Data(msg(121).utf8))
        model.apply(.message(conversationId: "c", message: m121))
        XCTAssertEqual(model.lastSeq, 121)
        XCTAssertTrue(model.typing.isEmpty)
        model.apply(.message(conversationId: "other", message: m121))
        model.apply(.read(conversationId: "c", userId: "bob", readSeq: 121))
        XCTAssertEqual(model.readBy(121), ["bob"])

        await model.refresh()
        XCTAssertEqual(model.messages.first { $0.seq == 120 }?.text, "edited")
        XCTAssertTrue(StubProtocol.requests.contains { $0.path.contains("messages?after=121") })

        try await model.markRead()
        XCTAssertEqual(model.reads["ann"], 121)

        model.apply(.left(conversationId: "c"))
        XCTAssertTrue(model.closed)
    }

    func testListMovesAndCountsUnread() async throws {
        StubProtocol.handler = { _ in
            (200, #"{"conversations":[{"id":"a","last_seq":3,"unread":0},{"id":"b","last_seq":9,"unread":2}],"next":""}"#)
        }
        let client = ChatClient(appId: "a", host: "https://chat.test", session: stubSession()) { jwt("ann") }
        let list = ConversationListModel(client: client)
        await list.refresh()
        XCTAssertEqual(list.conversations.map(\.id), ["a", "b"])
        let m = try JSONDecoder().decode(ChatMessage.self, from: Data(msg(10).utf8))
        list.apply(.message(conversationId: "b", message: m))
        XCTAssertEqual(list.conversations.map(\.id), ["b", "a"])
        XCTAssertEqual(list.unread, 3)
        list.apply(.read(conversationId: "b", userId: "ann", readSeq: 10))
        XCTAssertEqual(list.unread, 0)
        list.apply(.deleted(conversationId: "a"))
        XCTAssertEqual(list.conversations.map(\.id), ["b"])
    }
}

final class ChatSocketTests: XCTestCase {
    func testSignsInSubscribesAndForwardsEvents() async throws {
        let client = ChatClient(appId: "a", host: "https://chat.test", session: stubSession()) { jwt("ann") }
        let socket = ChatSocket(key: "key1", client: client) { sid in
            XCTAssertEqual(sid, "1.2")
            return UserAuth(auth: "key1:sig", userData: #"{"id":"ann"}"#)
        }
        let sent = Outbox()
        socket.transport = { sent.add($0) }
        var events: [ChatEvent] = []
        let sub = client.events.sink { events.append($0) }
        var lives = 0
        let liveSub = client.live.sink { lives += 1 }
        defer { sub.cancel(); liveSub.cancel() }

        socket.handle(#"{"event":"pusher:connection_established","data":"{\"socket_id\":\"1.2\",\"activity_timeout\":120}"}"#)
        for _ in 0..<100 where sent.items.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        let signin = try JSONDecoder().decode([String: JSONValue].self, from: Data(try XCTUnwrap(sent.items.first).utf8))
        XCTAssertEqual(signin["event"], "pusher:signin")
        XCTAssertEqual(signin["data"]?["auth"], "key1:sig")

        socket.handle(#"{"event":"pusher:signin_success","data":"{\"user_data\":\"{\\\"id\\\":\\\"ann\\\"}\"}"}"#)
        let sub2 = try JSONDecoder().decode([String: JSONValue].self, from: Data(sent.items[1].utf8))
        XCTAssertEqual(sub2["data"]?["channel"], "#server-to-user-ann")

        socket.handle(#"{"event":"pusher_internal:subscription_succeeded","channel":"#server-to-user-ann","data":"{}"}"#)
        XCTAssertEqual(socket.state, .live)
        XCTAssertEqual(lives, 1)
        socket.handle(#"{"event":"chat.typing","channel":"#server-to-user-ann","data":"{\"conversation_id\":\"c\",\"user_id\":\"bob\",\"typing\":true}"}"#)
        XCTAssertEqual(events, [.typing(conversationId: "c", userId: "bob", typing: true)])
        socket.handle(#"{"event":"pusher:ping","data":"{}"}"#)
        XCTAssertTrue(sent.items.last?.contains("pusher:pong") ?? false)
    }
}

final class Outbox: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    var items: [String] {
        lock.lock()
        defer { lock.unlock() }
        return list
    }

    func add(_ s: String) {
        lock.lock()
        list.append(s)
        lock.unlock()
    }
}
