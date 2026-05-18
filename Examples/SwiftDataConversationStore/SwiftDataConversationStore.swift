// SwiftDataConversationStore.swift
//
// Drop-in SwiftData implementation of Compound's `ConversationStore`
// protocol. Copy this file into your app target and adjust the schema
// if you need additional fields.
//
// This file is intentionally OUTSIDE the main Compound library target:
// the `@Model` and `@ModelActor` macros require the SwiftData compiler
// plugin which is only available in full Xcode, not the
// CommandLineTools-only toolchain. Shipping it inside the library would
// break CI builds that don't have the plugin loaded. As a copy-paste
// template it adapts cleanly to any production iOS / macOS / visionOS
// app on Swift 6.2 / Xcode 26.

import Foundation
import Compound
import SwiftData

/// A SwiftData-backed `ConversationStore`. Pair with
/// `ModelContainer(for: PersistentConversationMessage.self)` in your
/// app's startup code and pass the resulting store to
/// `ConversationContextAssembler`.
///
/// Uses the `@ModelActor` macro so the embedded `ModelContext` is pinned
/// to this actor's serial executor — `ModelContext` is documented as not
/// thread-safe, and a plain `actor` provides only mutual exclusion, not a
/// fixed thread. `@ModelActor` synthesizes a `modelContext` property
/// pinned correctly for SwiftData's contract.
@available(iOS 17.0, macOS 14.0, visionOS 1.0, tvOS 17.0, watchOS 10.0, *)
@ModelActor
public actor SwiftDataConversationStore: ConversationStore {
    public func append(_ message: ConversationMessage) async throws {
        modelContext.insert(PersistentConversationMessage(from: message))
        try modelContext.save()
    }

    public func messages() async throws -> [ConversationMessage] {
        let descriptor = FetchDescriptor<PersistentConversationMessage>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let stored = try modelContext.fetch(descriptor)
        return stored.map(\.asConversationMessage)
    }

    public func clear() async throws {
        try modelContext.delete(model: PersistentConversationMessage.self)
        try modelContext.save()
    }
}

@available(iOS 17.0, macOS 14.0, visionOS 1.0, tvOS 17.0, watchOS 10.0, *)
@Model
public final class PersistentConversationMessage {
    @Attribute(.unique) public var id: UUID
    public var rawRole: String
    public var content: String
    public var createdAt: Date
    public var metadataJSON: String

    public init(
        id: UUID,
        rawRole: String,
        content: String,
        createdAt: Date,
        metadataJSON: String
    ) {
        self.id = id
        self.rawRole = rawRole
        self.content = content
        self.createdAt = createdAt
        self.metadataJSON = metadataJSON
    }

    convenience init(from message: ConversationMessage) {
        let metaJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: message.metadata, options: []),
           let str = String(data: data, encoding: .utf8) {
            metaJSON = str
        } else {
            metaJSON = "{}"
        }
        self.init(
            id: message.id,
            rawRole: message.role.rawValue,
            content: message.content,
            createdAt: message.createdAt,
            metadataJSON: metaJSON
        )
    }

    var asConversationMessage: ConversationMessage {
        let role = ConversationMessage.Role(rawValue: rawRole) ?? .user
        var metadata: [String: String] = [:]
        if let data = metadataJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            metadata = parsed
        }
        return ConversationMessage(
            id: id,
            role: role,
            content: content,
            createdAt: createdAt,
            metadata: metadata
        )
    }
}
