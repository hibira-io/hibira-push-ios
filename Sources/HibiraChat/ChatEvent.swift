import Foundation

/// A Chat API event, sent to each member concerned on their `#server-to-user-<id>` channel.
public enum ChatEvent: Hashable, Sendable {
    /// `chat.message`: a new message.
    case message(conversationId: String, message: ChatMessage)
    /// `chat.message_updated`: a message was edited, deleted or its reactions changed.
    case messageUpdated(conversationId: String, message: ChatMessage)
    /// `chat.typing`: another member started or stopped typing.
    case typing(conversationId: String, userId: String, typing: Bool)
    /// `chat.read`: a member's read_seq moved forward.
    case read(conversationId: String, userId: String, readSeq: Int)
    /// `chat.conversation`: the conversation was created or changed, or a member was added.
    case conversation(ChatConversation)
    /// `chat.left`: the user was removed from the conversation.
    case left(conversationId: String)
    /// `chat.deleted`: the conversation was deleted.
    case deleted(conversationId: String)

    /// The event names the Chat API sends.
    public static let names = ["chat.message", "chat.message_updated", "chat.typing", "chat.read",
                               "chat.conversation", "chat.left", "chat.deleted"]

    public var conversationId: String {
        switch self {
        case .message(let id, _), .messageUpdated(let id, _), .typing(let id, _, _), .read(let id, _, _),
             .left(let id), .deleted(let id):
            return id
        case .conversation(let c):
            return c.id
        }
    }

    private struct Payload: Decodable {
        var conversationId: String?
        var message: ChatMessage?
        var userId: String?
        var typing: Bool?
        var readSeq: Int?
        var conversation: ChatConversation?

        enum CodingKeys: String, CodingKey {
            case message, typing, conversation
            case conversationId = "conversation_id", userId = "user_id", readSeq = "read_seq"
        }
    }

    /// Parses an event by name and its JSON data; nil when it is not a chat event.
    public init?(name: String, data: Data) {
        guard ChatEvent.names.contains(name),
              let p = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        let id = p.conversationId ?? ""
        switch name {
        case "chat.message":
            guard let m = p.message else { return nil }
            self = .message(conversationId: id, message: m)
        case "chat.message_updated":
            guard let m = p.message else { return nil }
            self = .messageUpdated(conversationId: id, message: m)
        case "chat.typing":
            self = .typing(conversationId: id, userId: p.userId ?? "", typing: p.typing ?? true)
        case "chat.read":
            self = .read(conversationId: id, userId: p.userId ?? "", readSeq: p.readSeq ?? 0)
        case "chat.conversation":
            guard let c = p.conversation else { return nil }
            self = .conversation(c)
        case "chat.left":
            self = .left(conversationId: id)
        default:
            self = .deleted(conversationId: id)
        }
        if conversationId.isEmpty { return nil }
    }
}
