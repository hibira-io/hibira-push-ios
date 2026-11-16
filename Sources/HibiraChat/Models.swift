import Foundation

/// A member of a conversation and how far they have read.
public struct ChatMember: Codable, Hashable, Sendable {
    public var userId: String
    public var readSeq: Int
    public var role: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id", readSeq = "read_seq", role
    }

    public init(userId: String, readSeq: Int = 0, role: String? = nil) {
        self.userId = userId
        self.readSeq = readSeq
        self.role = role
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.decode(String.self, forKey: .userId)
        readSeq = try c.decodeIfPresent(Int.self, forKey: .readSeq) ?? 0
        role = try c.decodeIfPresent(String.self, forKey: .role).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// A conversation of the Chat API.
public struct ChatConversation: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String?
    public var metadata: [String: JSONValue]
    public var members: [ChatMember]
    public var lastSeq: Int
    public var createdAt: String?
    public var updatedAt: String?
    /// In conversation lists: messages after the user's read_seq that are not system messages.
    public var unread: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, metadata, members, unread
        case lastSeq = "last_seq", createdAt = "created_at", updatedAt = "updated_at"
    }

    public init(id: String, name: String? = nil, metadata: [String: JSONValue] = [:], members: [ChatMember] = [],
                lastSeq: Int = 0, createdAt: String? = nil, updatedAt: String? = nil, unread: Int? = nil) {
        self.id = id
        self.name = name
        self.metadata = metadata
        self.members = members
        self.lastSeq = lastSeq
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.unread = unread
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name).flatMap { $0.isEmpty ? nil : $0 }
        metadata = try c.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
        members = try c.decodeIfPresent([ChatMember].self, forKey: .members) ?? []
        lastSeq = try c.decodeIfPresent(Int.self, forKey: .lastSeq) ?? 0
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        unread = try c.decodeIfPresent(Int.self, forKey: .unread)
    }

    /// How far `userId` has read, or 0.
    public func readSeq(of userId: String) -> Int {
        members.first { $0.userId == userId }?.readSeq ?? 0
    }
}

/// A file attached to a message. `url` downloads it for an hour.
public struct ChatAttachment: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var contentType: String
    public var size: Int?
    public var url: String?

    enum CodingKeys: String, CodingKey {
        case id, name, size, url, contentType = "content_type"
    }

    public init(id: String, name: String, contentType: String, size: Int? = nil, url: String? = nil) {
        self.id = id
        self.name = name
        self.contentType = contentType
        self.size = size
        self.url = url
    }
}

/// A stored message. A changed message keeps its `seq`.
public struct ChatMessage: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var seq: Int
    /// The sender's user ID; nil for system messages.
    public var sender: String?
    public var name: String?
    /// "text", or "system" for messages your server posts about the conversation.
    public var kind: String
    public var text: String
    public var metadata: [String: JSONValue]
    public var createdAt: String?
    public var editedAt: String?
    public var deletedAt: String?
    /// Each emoji and the members who reacted, in order.
    public var reactions: [String: [String]]
    public var attachments: [ChatAttachment]
    /// The roles this message is limited to (internal notes), if any.
    public var visibleTo: [String]
    /// The language `text` was written in, when the app sets users' languages.
    public var language: String?
    /// `text` translated, by BCP 47 language tag.
    public var translations: [String: String]

    /// The text to show a reader of `lang`: its translation when there is one, else `text`.
    public func text(for lang: String?) -> String {
        guard let lang = lang else { return text }
        return translations[lang] ?? text
    }

    public var isSystem: Bool { kind == "system" }
    public var isDeleted: Bool { deletedAt != nil }
    public var isEdited: Bool { editedAt != nil }

    enum CodingKeys: String, CodingKey {
        case id, seq, sender, name, kind, text, metadata, reactions, attachments
        case createdAt = "created_at", editedAt = "edited_at", deletedAt = "deleted_at", visibleTo = "visible_to"
        case language, translations
    }

    public init(id: String, seq: Int, sender: String? = nil, name: String? = nil, kind: String = "text", text: String = "",
                metadata: [String: JSONValue] = [:], createdAt: String? = nil, editedAt: String? = nil, deletedAt: String? = nil,
                reactions: [String: [String]] = [:], attachments: [ChatAttachment] = [], visibleTo: [String] = [],
                language: String? = nil, translations: [String: String] = [:]) {
        self.id = id
        self.seq = seq
        self.sender = sender
        self.name = name
        self.kind = kind
        self.text = text
        self.metadata = metadata
        self.createdAt = createdAt
        self.editedAt = editedAt
        self.deletedAt = deletedAt
        self.reactions = reactions
        self.attachments = attachments
        self.visibleTo = visibleTo
        self.language = language
        self.translations = translations
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func opt(_ key: CodingKeys) throws -> String? {
            try c.decodeIfPresent(String.self, forKey: key).flatMap { $0.isEmpty ? nil : $0 }
        }
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        seq = try c.decode(Int.self, forKey: .seq)
        sender = try opt(.sender)
        name = try opt(.name)
        kind = try opt(.kind) ?? "text"
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        metadata = try c.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
        createdAt = try opt(.createdAt)
        editedAt = try opt(.editedAt)
        deletedAt = try opt(.deletedAt)
        reactions = try c.decodeIfPresent([String: [String]].self, forKey: .reactions) ?? [:]
        attachments = try c.decodeIfPresent([ChatAttachment].self, forKey: .attachments) ?? []
        visibleTo = try c.decodeIfPresent([String].self, forKey: .visibleTo) ?? []
        language = try opt(.language)
        translations = try c.decodeIfPresent([String: String].self, forKey: .translations) ?? [:]
    }
}

/// A message someone reported.
public struct ChatReport: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var conversationId: String
    public var seq: Int
    public var reportedBy: String
    public var reason: String
    public var message: ChatMessage?

    enum CodingKeys: String, CodingKey {
        case id, seq, reason, message
        case conversationId = "conversation_id", reportedBy = "reported_by"
    }
}

/// A page of the user's conversations, latest activity first. Pass `next` as `before` for the next page.
public struct ChatConversationPage: Sendable {
    public var conversations: [ChatConversation]
    public var next: String
}

/// Messages, oldest first, and the conversation's newest sequence number.
public struct ChatMessagePage: Sendable {
    public var messages: [ChatMessage]
    public var lastSeq: Int
}

/// Search results, newest first. Pass `next` as `before` for more.
public struct ChatSearchPage: Sendable {
    public var messages: [ChatMessage]
    public var next: String
}

/// The answer to a send: the stored message, and how many members were pushed.
public struct ChatSendResult: Sendable {
    public var message: ChatMessage
    public var pushedUsers: Int?
    public var pushError: String?
}

/// An error answered by the Chat API, with its HTTP status (0 when the request did not reach it).
public struct ChatError: Error, LocalizedError, Sendable {
    public var status: Int
    public var message: String

    public init(status: Int, message: String) {
        self.status = status
        self.message = message
    }

    public var errorDescription: String? { message }
}
