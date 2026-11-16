import Combine
import Foundation

/// The user's conversations kept up to date: new messages move a
/// conversation to the top and count as unread, reads clear the count, and
/// conversations the user joins, leaves or that are deleted come and go.
@MainActor
public final class ConversationListModel: ObservableObject {
    /// Latest activity first, each with `unread`.
    @Published public private(set) var conversations: [ChatConversation] = []
    @Published public private(set) var loading = true
    @Published public private(set) var loadingMore = false
    @Published public private(set) var hasMore = false
    @Published public private(set) var error: Error?

    public let pageSize: Int
    private let client: ChatClient
    private var listeners: [Task<Void, Never>] = []
    private var next = ""

    public init(client: ChatClient, pageSize: Int = 30) {
        self.client = client
        self.pageSize = pageSize
    }

    /// Unread messages across the loaded conversations.
    public var unread: Int { conversations.reduce(0) { $0 + ($1.unread ?? 0) } }

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

    public func stop() {
        listeners.forEach { $0.cancel() }
        listeners.removeAll()
    }

    /// Loads the first page again.
    public func refresh() async {
        do {
            let page = try await client.conversations(limit: pageSize)
            conversations = page.conversations
            next = page.next
            hasMore = !next.isEmpty
            error = nil
        } catch {
            self.error = error
        }
        loading = false
    }

    /// Loads the next page, if there is one.
    public func loadMore() async {
        guard !next.isEmpty, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await client.conversations(limit: pageSize, before: next)
            let have = Set(conversations.map(\.id))
            conversations += page.conversations.filter { !have.contains($0.id) }
            next = page.next
            hasMore = !next.isEmpty
        } catch {
            self.error = error
        }
    }

    /// Applies one event to the list.
    public func apply(_ event: ChatEvent) {
        let me = client.userId
        switch event {
        case .message(let id, let m):
            guard var c = conversations.first(where: { $0.id == id }) else {
                Task { await refresh() }
                return
            }
            c.lastSeq = max(c.lastSeq, m.seq)
            c.updatedAt = m.createdAt ?? c.updatedAt
            if m.sender == me {
                c.unread = 0
            } else if !m.isSystem {
                c.unread = (c.unread ?? 0) + 1
            }
            conversations = [c] + conversations.filter { $0.id != id }
        case .read(let id, let user, let seq):
            guard user == me, let i = conversations.firstIndex(where: { $0.id == id }),
                  seq >= conversations[i].lastSeq else { return }
            conversations[i].unread = 0
        case .conversation(var c):
            if let i = conversations.firstIndex(where: { $0.id == c.id }) {
                c.unread = conversations[i].unread
                conversations[i] = c
            } else {
                c.unread = c.unread ?? 0
                conversations.insert(c, at: 0)
            }
        case .left(let id), .deleted(let id):
            conversations.removeAll { $0.id == id }
        case .messageUpdated, .typing:
            break
        }
    }
}
