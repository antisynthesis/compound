import Foundation

/// The boundary where conversation history is kept — and where you decide
/// who keeps it.
///
/// Deliberately minimal: append, read, clear. That refusal to assume is
/// the point — drop in CoreData, SwiftData, SQLite, or a network store
/// without the rest of the framework noticing, and keep the history under
/// your own control rather than someone else's. The bundled
/// ``InMemoryConversationStore`` is the right default for short-lived
/// sessions, tests, and demos.
public protocol ConversationStore: Sendable {
    /// Appends `message` to the back of the history.
    func append(_ message: ConversationMessage) async throws
    /// Returns the messages in append order.
    func messages() async throws -> [ConversationMessage]
    /// Removes every message.
    func clear() async throws
}

/// Process-local conversation store: nothing touches the disk, nothing
/// outlives the process. Optionally caps the message count; once exceeded,
/// the oldest messages are dropped FIFO.
public actor InMemoryConversationStore: ConversationStore {
    private var entries: [ConversationMessage] = []
    /// Optional cap on retained messages.
    public let cap: Int?

    /// Creates an empty store.
    public init(cap: Int? = nil) {
        self.cap = cap
    }

    /// Appends `message` and trims excess entries from the front.
    public func append(_ message: ConversationMessage) async {
        entries.append(message)
        if let cap, entries.count > cap {
            entries.removeFirst(entries.count - cap)
        }
    }

    /// Returns the messages in append order.
    public func messages() async -> [ConversationMessage] {
        entries
    }

    /// Removes every message.
    public func clear() async {
        entries.removeAll()
    }

    /// Number of retained messages.
    public var count: Int { entries.count }
}

/// File-backed conversation store. Appends each message as a JSONL row —
/// a format you can read with your own eyes and grep with your own tools,
/// no proprietary blob between you and your history. Crash-safe in the
/// usual append-only sense, trivially diffable and inspectable on disk.
public actor JSONLConversationStore: ConversationStore {
    /// File the store reads and appends to.
    public let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Creates a store at `fileURL`, creating the file if it does not
    /// already exist.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    /// Encodes `message` as JSON and appends a newline-terminated row.
    public func append(_ message: ConversationMessage) async throws {
        let data = try encoder.encode(message) + Data([0x0A])
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// Reads the entire file and decodes one message per line. Lines
    /// that fail to decode are skipped silently to keep the store
    /// recoverable from partial writes.
    public func messages() async throws -> [ConversationMessage] {
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return [] }
        var out: [ConversationMessage] = []
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            if let msg = try? decoder.decode(ConversationMessage.self, from: line) {
                out.append(msg)
            }
        }
        return out
    }

    /// Truncates the file to zero bytes.
    public func clear() async throws {
        try Data().write(to: fileURL)
    }
}
