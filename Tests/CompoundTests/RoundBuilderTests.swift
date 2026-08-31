import Foundation
import Testing
@testable import Compound

@Suite("RoundBuilder")
struct RoundBuilderTests {
    // Fixed instants so nothing in this suite reads the clock.
    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private static func message(
        _ role: ConversationMessage.Role,
        _ content: String,
        offset: TimeInterval,
        tool: String? = nil
    ) -> ConversationMessage {
        ConversationMessage(
            id: UUID(),
            role: role,
            content: content,
            createdAt: epoch.addingTimeInterval(offset),
            metadata: tool.map { ["tool": $0] } ?? [:]
        )
    }

    private static func transcript() -> [ConversationMessage] {
        [
            message(.user, "what is the launch date", offset: 0),
            message(.assistant, "let me check the calendar", offset: 1),
            message(.tool, "{\"date\":\"soon\"}", offset: 2, tool: "calendar"),
            message(.user, "and who owns it", offset: 3),
            message(.assistant, "the platform team owns it", offset: 4),
        ]
    }

    @Test("a user/assistant/tool/user/assistant transcript forms exactly two rounds")
    func groupsIntoRounds() {
        let messages = Self.transcript()
        let built = RoundBuilder.rounds(from: messages, threadID: "t1")
        #expect(built.rounds.count == 2)
        #expect(built.rounds[0].messageIDs == [messages[0].id, messages[1].id, messages[2].id])
        #expect(built.rounds[1].messageIDs == [messages[3].id, messages[4].id])
        #expect(built.rounds[0].ordinal == 0)
        #expect(built.rounds[1].ordinal == 1)
        #expect(built.nextOrdinal == 2)
        #expect(built.rounds[0].startedAt == messages[0].createdAt)
        #expect(built.rounds[0].endedAt == messages[2].createdAt)
    }

    @Test("display text is role-prefixed, unfenced, and names the tool")
    func displayTextShape() {
        let built = RoundBuilder.rounds(from: Self.transcript(), threadID: "t1")
        let lines = built.rounds[0].displayText.components(separatedBy: "\n")
        #expect(lines == [
            "user: what is the launch date",
            "assistant: let me check the calendar",
            "tool[calendar]: {\"date\":\"soon\"}",
        ])
        // Fencing is PromptFrame's job; double-fencing would show the model
        // escape sequences instead of the conversation.
        #expect(!built.rounds[0].displayText.contains("<source"))
    }

    @Test("messages before the first user turn form their own leading round")
    func leadingNonUserMessages() {
        let messages = [
            Self.message(.system, "you are a helpful assistant", offset: 0),
            Self.message(.assistant, "hello", offset: 1),
            Self.message(.user, "hi", offset: 2),
        ]
        let built = RoundBuilder.rounds(from: messages, threadID: "t1")
        #expect(built.rounds.count == 2)
        #expect(built.rounds[0].ordinal == 0)
        #expect(built.rounds[0].messageIDs == [messages[0].id, messages[1].id])
        #expect(built.rounds[1].messageIDs == [messages[2].id])
    }

    @Test("empty input yields no rounds and leaves the ledger untouched")
    func emptyInput() {
        let built = RoundBuilder.rounds(from: [], threadID: "t1", ordinals: [:], nextOrdinal: 7)
        #expect(built.rounds.isEmpty)
        #expect(built.ordinals.isEmpty)
        #expect(built.nextOrdinal == 7)
    }

    @Test("re-running over the same messages reproduces byte-identical rounds")
    func ordinalIdempotence() {
        let messages = Self.transcript()
        let first = RoundBuilder.rounds(from: messages, threadID: "t1")
        let second = RoundBuilder.rounds(
            from: messages,
            threadID: "t1",
            ordinals: first.ordinals,
            nextOrdinal: first.nextOrdinal
        )
        #expect(first.rounds == second.rounds)
        #expect(second.nextOrdinal == first.nextOrdinal)
    }

    @Test("appending new turns keeps the shared rounds' ids fixed")
    func ordinalIdempotenceWithNewTail() {
        let messages = Self.transcript()
        let first = RoundBuilder.rounds(from: messages, threadID: "t1")
        var extended = messages
        extended.append(Self.message(.user, "thanks", offset: 5))
        let second = RoundBuilder.rounds(
            from: extended,
            threadID: "t1",
            ordinals: first.ordinals,
            nextOrdinal: first.nextOrdinal
        )
        #expect(second.rounds.count == 3)
        #expect(Array(second.rounds.prefix(2)) == first.rounds)
        #expect(second.rounds[2].ordinal == 2)
    }

    @Test("a re-run over a shifted window does not renumber surviving rounds")
    func ordinalsSurviveWindowShift() {
        let messages = Self.transcript()
        let first = RoundBuilder.rounds(from: messages, threadID: "t1")
        // A later archival pass sees only the tail of the transcript.
        let shifted = RoundBuilder.rounds(
            from: Array(messages.suffix(2)),
            threadID: "t1",
            ordinals: first.ordinals,
            nextOrdinal: first.nextOrdinal
        )
        #expect(shifted.rounds.count == 1)
        #expect(shifted.rounds[0] == first.rounds[1])
        #expect(shifted.nextOrdinal == first.nextOrdinal)
    }

    @Test("chunk ids match a hand-computed DocumentChunker derivation")
    func chunkIDDerivationIsPinned() {
        let built = RoundBuilder.rounds(from: Self.transcript(), threadID: "t1")
        for round in built.rounds {
            let expected = DocumentChunker.chunkID(
                documentID: "compound.memory.archive.v1|t1",
                ordinal: round.ordinal,
                content: round.indexText
            )
            #expect(round.id == expected)
            #expect(round.chunk.id == expected)
            #expect(round.chunk.content == round.indexText)
        }
    }

    @Test("index text is display text plus exactly the key line")
    func indexTextIsDisplayPlusKey() {
        let display = "user: Alice met Bob in Berlin on March 3, 2024."
        let key = RoundBuilder.keyLine(for: display)
        #expect(!key.isEmpty)
        let messages = [Self.message(.user, "Alice met Bob in Berlin on March 3, 2024.", offset: 0)]
        let built = RoundBuilder.rounds(from: messages, threadID: "t1")
        #expect(built.rounds[0].displayText == display)
        #expect(built.rounds[0].indexText == display + "\n" + key)
    }

    @Test("key line is deterministic across 100 calls")
    func keyLineDeterminism() {
        let text = "user: Alice met Bob in Berlin on March 3, 2024 and walked 12 km.\nassistant: The Platform Team confirmed it."
        let first = RoundBuilder.keyLine(for: text)
        for _ in 0..<100 {
            #expect(RoundBuilder.keyLine(for: text) == first)
        }
    }

    @Test("key line is sorted and deduplicated")
    func keyLineSortedAndDeduplicated() {
        let text = "user: Berlin is not Berlin.\nassistant: I like Berlin and Munich."
        let key = RoundBuilder.keyLine(for: text)
        let tokens = key.components(separatedBy: " ")
        #expect(tokens == tokens.sorted())
        #expect(Set(tokens).count == tokens.count)
    }

    @Test("an absolutely-specified date appears as an ISO day string")
    func keyLineExtractsISODay() {
        let key = RoundBuilder.keyLine(for: "user: we shipped on March 3, 2024.")
        #expect(key.contains("2024-03-03"), "key line was: \(key)")
    }

    @Test("a relative date is not a key, because it would depend on when archiving ran")
    func keyLineSkipsRelativeDates() {
        let key = RoundBuilder.keyLine(for: "user: let us meet tomorrow.")
        // Whatever else the key line holds, it must carry no resolved day:
        // "tomorrow" resolves against the clock, and a clock-dependent key
        // would re-mint the chunk id on every archival pass.
        #expect(!key.contains(#/[0-9]{4}-[0-9]{2}-[0-9]{2}/#))
    }

    @Test("sentence-initial capitalized words are not entity keys")
    func keyLineSkipsSentenceInitial() {
        let key = RoundBuilder.keyLine(for: "user: Berlin is nice. Munich is nicer than Hamburg.")
        // "Berlin" and "Munich" open their sentences; only "Hamburg" is
        // capitalized mid-sentence.
        #expect(key.contains("Hamburg"))
        #expect(!key.contains("Munich"))
    }

    @Test("multi-token entity runs are captured, capped at three tokens")
    func keyLineCapturesEntityRuns() {
        let key = RoundBuilder.keyLine(for: "user: it was the North American Free Trade deal.")
        #expect(key.contains("North American Free"))
        #expect(!key.contains("North American Free Trade"))
    }

    @Test("numeric literals with adjacent units become keys")
    func keyLineCapturesQuantities() {
        let key = RoundBuilder.keyLine(for: "user: we ran 12 km and lifted 30kg.")
        #expect(key.contains("12 km"), "key line was: \(key)")
        #expect(key.contains("30 kg"), "key line was: \(key)")
    }

    @Test("truncation drops whole keys, never a partial token")
    func keyLineTruncatesAtTokenBoundary() {
        let text = "user: it named Alpha, Bravo, Charlie, Delta, Echo, Foxtrot, Golf and Hotel."
        let full = RoundBuilder.keyLine(for: text)
        let truncated = RoundBuilder.keyLine(for: text, maxCharacters: 20)
        #expect(truncated.count <= 20)
        #expect(truncated.count < full.count)
        let fullKeys = Set(full.components(separatedBy: " "))
        for key in truncated.components(separatedBy: " ") where !key.isEmpty {
            #expect(fullKeys.contains(key), "truncation produced a partial token: \(key)")
        }
    }

    @Test("a round with no keyable content indexes exactly its display text")
    func emptyKeyLineLeavesIndexTextAlone() {
        let messages = [Self.message(.user, "ok", offset: 0)]
        let built = RoundBuilder.rounds(from: messages, threadID: "t1")
        #expect(RoundBuilder.keyLine(for: built.rounds[0].displayText).isEmpty)
        #expect(built.rounds[0].indexText == built.rounds[0].displayText)
    }

    @Test("archival document ids are disjoint from plain document chunk ids")
    func archivalIDsAreDisjoint() {
        let content = "user: hello"
        let archival = DocumentChunker.chunkID(
            documentID: RoundBuilder.documentID(threadID: "t1"),
            ordinal: 0,
            content: content
        )
        let plain = DocumentChunker.chunkID(documentID: "t1", ordinal: 0, content: content)
        #expect(archival != plain)
    }
}
