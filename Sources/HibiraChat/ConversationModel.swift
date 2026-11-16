import Combine
import Foundation


/// One conversation kept up to date for SwiftUI or UIKit: the newest page of
/// messages, older pages on demand, live messages, edits, reactions, typing
/// and read receipts, and a catch-up read each time the realtime connection
/// comes back.
@MainActor
public final class ConversationModel: ObservableObject {
    public let conversationId: String
    public let pageSize: Int

    @Published public private(set) var conversation: ChatConversation?
    /// Loaded messages ordered by seq, without repeats.
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var loading = true
    @Published public private(set) var loadingOlder = false
    /// Older messages can be loaded with ``loadOlder()``.
    @Published public private(set) var hasOlder = false
    /// Members typing right now (not the user).
    @Published public private(set) var typing: Set<String> = []
    /// Each member's read_seq, kept live from `chat.read`.
    @Published public private(set) var reads: [String: Int] = [:]
    /// The conversation was deleted or the user removed from it.
    @Published public private(set) var closed = false
    @Published public private(set) var error: Error?

    /// How long a typing indicator shows without another `chat.typing`.
    public static let typingShowSeconds: TimeInterval = 8

    private let client: ChatClient
    private var listeners: [Task<Void, Never>] = []
    private var typingTimers: [String: Task<Void, Never>] = [:]
    private var floor = Int.max
    private var refreshing = false
    private var refreshAgain = false
    private var lastTypingSent: Date?
    private var typingOff: Task<Void, Never>?

    public init(client: ChatClient, conversationId: String, pageSize: Int = 50) {
        self.client = client
        self.conversationId = conversationId
        self.pageSize = pageSize
    }

    public var lastSeq: Int { messages.last?.seq ?? 0 }

    /// Members other than the user who have read message `seq`.
    public func readBy(_ seq: Int) -> [String] {
        let me = client.userId
        return reads.filter { $0.key != me && $0.value >= seq }.map { $0.key }.sorted()
    }

    /// Starts loading and listening; safe to call again.
    public func start() {
        guard listeners.isEmpty else { return }
        let events = client.eventStream(), live = client.liveStream()
        listeners = [
            Task { [weak self] in
                for await event in events {
                    guard let self = self else { return }
                    self.apply(event)
                }
            },
            Task { [weak self] in
                for await _ in live {
                    guard let self = self else { return }
                    await self.refresh()
                }
            },
        ]
        Task { await refresh() }
    }

    /// Stops listening.
    public func stop() {
        listeners.forEach { $0.cancel() }
        listeners.removeAll()
        typingTimers.values.forEach { $0.cancel() }
        typingTimers.removeAll()
    }

    private func merge(_ page: [ChatMessage]) {
        guard !page.isEmpty else { return }
        var bySeq = Dictionary(messages.map { ($0.seq, $0) }, uniquingKeysWith: { $1 })
        page.forEach { bySeq[$0.seq] = $0 }
        messages = bySeq.values.sorted { $0.seq < $1.seq }
    }

    /// Reads what is new, and re-reads the newest messages for edits, deletes
    /// and reactions made while the connection was down.
    public func refresh() async {
        if refreshing {
            refreshAgain = true
            return
        }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshAgain = false
            await load()
        } while refreshAgain
    }

    private func load() async {
        do {
            if conversation == nil || messages.isEmpty {
                let c = try await client.conversation(conversationId)
                conversation = c
                for m in c.members { reads[m.userId] = max(reads[m.userId] ?? 0, m.readSeq) }
            }
            var after = lastSeq
            if after > 0 {
                while true {
                    let page = try await client.messages(conversationId, after: after, limit: 200)
                    merge(page.messages)
                    guard page.messages.count == 200, let last = page.messages.last else { break }
                    after = last.seq
                }
            }
            let page = try await client.messages(conversationId, last: min(200, max(pageSize, messages.count)))
            if floor == Int.max { floor = page.messages.first?.seq ?? page.lastSeq + 1 }
            merge(page.messages)
            hasOlder = floor > 1
            loading = false
            error = nil
        } catch let e as ChatError where e.status == 404 {
            closed = true
            loading = false
            error = e
        } catch {
            loading = false
            self.error = error
        }
    }

    /// Loads the page of messages before the oldest one loaded.
    public func loadOlder() async {
        guard floor > 1, floor != Int.max, !loadingOlder else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        do {
            let after = max(0, floor - 1 - pageSize)
            let page = try await client.messages(conversationId, after: after, limit: floor - 1 - after)
            floor = after + 1
            merge(page.messages)
            hasOlder = floor > 1
        } catch {
            self.error = error
        }
    }

    /// Sends a message and adds the stored copy.
    @discardableResult
    public func send(_ text: String, metadata: [String: JSONValue]? = nil,
                     attachments: [ChatAttachment] = []) async throws -> ChatMessage {
        await stopTyping()
        let sent = try await client.send(conversationId, text: text, metadata: metadata, attachments: attachments).message
        merge([sent])
        return sent
    }

    @discardableResult
    public func edit(_ seq: Int, text: String) async throws -> ChatMessage {
        let m = try await client.edit(conversationId, seq: seq, text: text)
        merge([m])
        return m
    }

    @discardableResult
    public func delete(_ seq: Int) async throws -> ChatMessage {
        let m = try await client.delete(conversationId, seq: seq)
        merge([m])
        return m
    }

    /// Adds the user's reaction, or takes it back if they already reacted with `emoji`.
    @discardableResult
    public func toggleReaction(_ seq: Int, emoji: String) async throws -> ChatMessage {
        let me = try await client.currentUser()
        let mine = messages.first { $0.seq == seq }?.reactions[emoji]?.contains(me) ?? false
        let m: ChatMessage
        if mine {
            m = try await client.unreact(conversationId, seq: seq, emoji: emoji)
        } else {
            m = try await client.react(conversationId, seq: seq, emoji: emoji)
        }
        merge([m])
        return m
    }

    /// Marks everything loaded as read, when it is not already.
    public func markRead() async throws {
        let seq = lastSeq
        let me = try await client.currentUser()
        guard seq > 0, (reads[me] ?? 0) < seq else { return }
        let readSeq = try await client.read(conversationId, seq: seq)
        reads[me] = max(readSeq, reads[me] ?? 0)
    }

    /// Call on every keystroke: tells the others the user is typing at most
    /// every 3 seconds, and that they stopped after 5 seconds without one.
    public func userIsTyping() {
        let now = Date()
        if lastTypingSent.map({ now.timeIntervalSince($0) > 3 }) ?? true {
            lastTypingSent = now
            let client = self.client, id = conversationId
            Task { try? await client.typing(id, true) }
        }
        typingOff?.cancel()
        typingOff = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.stopTyping()
        }
    }

    /// Tells the others the user stopped typing (sent only if they were told it started).
    public func stopTyping() async {
        typingOff?.cancel()
        guard lastTypingSent != nil else { return }
        lastTypingSent = nil
        try? await client.typing(conversationId, false)
    }

    private func setRead(_ user: String, _ seq: Int) {
        if seq > (reads[user] ?? 0) { reads[user] = seq }
    }

    private func clearTyping(_ user: String?) {
        guard let user = user else { return }
        typingTimers.removeValue(forKey: user)?.cancel()
        if typing.contains(user) { typing.remove(user) }
    }

    /// Applies one event to this conversation (events of other conversations are ignored).
    public func apply(_ event: ChatEvent) {
        guard event.conversationId == conversationId else { return }
        switch event {
        case .message(_, let m):
            clearTyping(m.sender)
            if let s = m.sender { setRead(s, m.seq) }
            merge([m])
        case .messageUpdated(_, let m):
            if messages.contains(where: { $0.seq == m.seq }) { merge([m]) }
        case .typing(_, let user, let on):
            guard user != client.userId else { return }
            if on {
                typing.insert(user)
                typingTimers[user]?.cancel()
                typingTimers[user] = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(ConversationModel.typingShowSeconds * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self?.clearTyping(user)
                }
            } else {
                clearTyping(user)
            }
        case .read(_, let user, let seq):
            setRead(user, seq)
        case .conversation(let c):
            conversation = c
            c.members.forEach { setRead($0.userId, $0.readSeq) }
        case .left, .deleted:
            closed = true
        }
    }
}
