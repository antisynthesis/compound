import Foundation
import Testing
@testable import Compound

@Suite("Budget")
struct BudgetTests {
    @Test("budget default has positive turns")
    func defaultPositiveTurns() {
        #expect(Budget.default.maxTurns > 0)
    }

    @Test("budget tracks exhaustion by turns")
    func tracksExhaustionByTurns() {
        let b = Budget(maxTurns: 2, maxToolCalls: 10, maxRepairAttempts: 10, wallClock: .seconds(60))
        var u = BudgetUsage()
        #expect(b.remaining(u) == nil)
        u.recordTurn()
        #expect(b.remaining(u) == nil)
        u.recordTurn()
        #expect(b.remaining(u) == .turns)
    }

    @Test("budget tracks exhaustion by tool calls")
    func tracksExhaustionByToolCalls() {
        let b = Budget(maxTurns: 100, maxToolCalls: 1, maxRepairAttempts: 10, wallClock: .seconds(60))
        var u = BudgetUsage()
        u.recordToolCall()
        #expect(b.remaining(u) == .toolCalls)
    }

    @Test("budget tracks exhaustion by repairs")
    func tracksExhaustionByRepairs() {
        let b = Budget(maxTurns: 100, maxToolCalls: 100, maxRepairAttempts: 0, wallClock: .seconds(60))
        var u = BudgetUsage()
        u.recordRepair()
        #expect(b.remaining(u) == .repairAttempts)
    }

    @Test("budget tracks exhaustion by wall clock")
    func tracksExhaustionByWallClock() {
        let b = Budget(maxTurns: 100, maxToolCalls: 100, maxRepairAttempts: 100, wallClock: .seconds(1))
        var u = BudgetUsage()
        u.recordElapsed(.seconds(2))
        #expect(b.remaining(u) == .wallClock)
    }

    @Test("budget tracks exhaustion by tokens")
    func tracksExhaustionByTokens() {
        let b = Budget(maxTurns: 100, maxToolCalls: 100, maxRepairAttempts: 100, wallClock: .seconds(60), maxTotalOutputTokens: 100)
        var u = BudgetUsage()
        u.recordOutputTokens(150)
        #expect(b.remaining(u) == .outputTokens)
    }

    // MARK: - exhaustion(afterAdding:to:) — cap = number of allowed occurrences

    @Test("maxTurns 1 allows the first turn and refuses the second")
    func exhaustionAfterAddingTurns() {
        let b = Budget(maxTurns: 1, maxToolCalls: 10, maxRepairAttempts: 10, wallClock: .seconds(60))
        var u = BudgetUsage()
        #expect(b.exhaustion(afterAdding: .turns, to: u) == nil)
        u.recordTurn()
        #expect(b.exhaustion(afterAdding: .turns, to: u) == .turns)
    }

    @Test("maxRepairAttempts 1 allows the first repair and refuses the second")
    func exhaustionAfterAddingRepairs() {
        let b = Budget(maxTurns: 10, maxToolCalls: 10, maxRepairAttempts: 1, wallClock: .seconds(60))
        var u = BudgetUsage()
        #expect(b.exhaustion(afterAdding: .repairAttempts, to: u) == nil)
        u.recordRepair()
        #expect(b.exhaustion(afterAdding: .repairAttempts, to: u) == .repairAttempts)
    }

    @Test("maxToolCalls 0 does not trip runs that make no tool calls")
    func zeroToolCallsIsHarmlessForToolFreeRuns() {
        let b = Budget(maxTurns: 5, maxToolCalls: 0, maxRepairAttempts: 5, wallClock: .seconds(60))
        let u = BudgetUsage()
        #expect(b.exhaustion(afterAdding: .turns, to: u) == nil)
        #expect(b.exhaustion(afterAdding: .repairAttempts, to: u) == nil)
        #expect(b.exhaustion(afterAdding: .toolCalls, to: u) == .toolCalls)
    }

    @Test("continuous dimensions trip regardless of the dimension being added")
    func continuousDimensionsAlwaysChecked() {
        let b = Budget(maxTurns: 10, maxToolCalls: 10, maxRepairAttempts: 10, wallClock: .seconds(1), maxTotalOutputTokens: 10)
        var u = BudgetUsage()
        u.recordElapsed(.seconds(2))
        #expect(b.exhaustion(afterAdding: .turns, to: u) == .wallClock)
        u.recordElapsed(.zero)
        u.recordOutputTokens(10)
        #expect(b.exhaustion(afterAdding: .repairAttempts, to: u) == .outputTokens)
    }

    // MARK: - ToolCallMeter

    @Test("ToolCallMeter allows exactly limit calls then throws .toolCalls")
    func toolCallMeterEnforcesLimit() async throws {
        let meter = ToolCallMeter(limit: 2)
        let first = try await meter.record()
        #expect(first == 1)
        let second = try await meter.record()
        #expect(second == 2)
        do {
            _ = try await meter.record()
            Issue.record("expected budgetExhausted(.toolCalls)")
        } catch CompoundError.budgetExhausted(let kind, let usage) {
            #expect(kind == .toolCalls)
            #expect(usage.toolCalls == 2)
        }
        let count = await meter.count
        #expect(count == 2)
    }

    @Test("ToolCallMeter without a limit never throws")
    func toolCallMeterUnlimited() async throws {
        let meter = ToolCallMeter()
        for _ in 0..<50 { try await meter.record() }
        let count = await meter.count
        #expect(count == 50)
    }
}
