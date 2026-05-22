import Foundation

/// One turn of the conversation as a human would recognize it.
///
/// Conversation messages live above the model's internal `Transcript`.
/// A single Compound run may churn through many model-level turns (prompt
/// → tool calls → repair turns → final); the conversation keeps only the
/// turns a person was meant to see. This is the honest record — what gets
/// persisted, shown in chat UIs, and replayed for evaluation.
public struct ConversationMessage: Sendable, Equatable, Identifiable, Codable {
    /// Stable per-message identifier.
    public let id: UUID
    /// Speaker role.
    public let role: Role
    /// Message text.
    public let content: String
    /// Wall-clock instant the message was created.
    public let createdAt: Date
    /// Free-form metadata (tool name, run id, source ids, etc.).
    public let metadata: [String: String]

    /// Speaker role in the conversation. Mirrors the standard
    /// chat-completion shape.
    public enum Role: String, Sendable, Equatable, Codable {
        /// System-level instructions.
        case system
        /// User-supplied prompt.
        case user
        /// Assistant (model) response.
        case assistant
        /// Tool-call result.
        case tool
    }

    /// Creates a message.
    public init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        createdAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.metadata = metadata
    }

    /// Convenience factory for a user-role message.
    public static func user(_ content: String, metadata: [String: String] = [:]) -> ConversationMessage {
        ConversationMessage(role: .user, content: content, metadata: metadata)
    }

    /// Convenience factory for an assistant-role message.
    public static func assistant(_ content: String, metadata: [String: String] = [:]) -> ConversationMessage {
        ConversationMessage(role: .assistant, content: content, metadata: metadata)
    }

    /// Convenience factory for a system-role message.
    public static func system(_ content: String, metadata: [String: String] = [:]) -> ConversationMessage {
        ConversationMessage(role: .system, content: content, metadata: metadata)
    }

    /// Convenience factory for a tool-role message; tags `metadata` with
    /// the originating tool name.
    public static func tool(_ content: String, name: String) -> ConversationMessage {
        ConversationMessage(role: .tool, content: content, metadata: ["tool": name])
    }
}
