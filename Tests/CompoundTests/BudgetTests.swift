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
}
