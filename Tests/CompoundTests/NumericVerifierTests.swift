import Foundation
import Testing
@testable import Compound

@Suite("NumericVerifier")
struct NumericVerifierTests {
    @Test("numeric-range passes inside bounds")
    func passesInsideBounds() async throws {
        let v = NumericRangeVerifier(min: 0, max: 100)
        #expect((try await v.verify(42, context: RunContext())).isPass)
    }

    @Test("numeric-range repairs above max")
    func repairsAboveMax() async throws {
        let v = NumericRangeVerifier(max: 10)
        #expect((try await v.verify(11, context: RunContext())).isRepair)
    }

    @Test("numeric-range honors exclusive bounds")
    func honorsExclusiveBounds() async throws {
        let v = NumericRangeVerifier(min: 0, max: 1, inclusive: false)
        #expect((try await v.verify(1.0, context: RunContext())).isRepair)
        #expect((try await v.verify(0.5, context: RunContext())).isPass)
    }

    @Test("probability passes 0...1")
    func probabilityPasses() async throws {
        let v = ProbabilityVerifier()
        #expect((try await v.verify(0, context: RunContext())).isPass)
        #expect((try await v.verify(0.5, context: RunContext())).isPass)
        #expect((try await v.verify(1, context: RunContext())).isPass)
    }

    @Test("probability rejects out-of-range")
    func probabilityRejects() async throws {
        let v = ProbabilityVerifier()
        for bad in [-0.01, 1.01, Double.nan] {
            let verdict = try await v.verify(bad, context: RunContext())
            #expect(verdict.isRepair, "expected .repair for \(bad)")
        }
    }

    @Test("sum passes within tolerance")
    func sumPasses() async throws {
        let v = SumVerifier()
        let check = SumCheck(total: 1.0, parts: [0.5, 0.3, 0.2])
        #expect((try await v.verify(check, context: RunContext())).isPass)
    }

    @Test("sum repairs when parts disagree")
    func sumRepairs() async throws {
        let v = SumVerifier()
        let check = SumCheck(total: 1.0, parts: [0.5, 0.4])
        #expect((try await v.verify(check, context: RunContext())).isRepair)
    }

    @Test("sum respects custom tolerance")
    func sumCustomTolerance() async throws {
        let v = SumVerifier()
        let check = SumCheck(total: 100.0, parts: [33.34, 33.33, 33.33], tolerance: 0.01)
        #expect((try await v.verify(check, context: RunContext())).isPass)
    }

    @Test("monotonic ascending passes a sorted list")
    func monotonicAscending() async throws {
        let v = MonotonicVerifier<Int>(direction: .ascending)
        #expect((try await v.verify([1, 2, 2, 3], context: RunContext())).isPass)
    }

    @Test("monotonic strict-ascending rejects equal adjacent")
    func monotonicStrictRejects() async throws {
        let v = MonotonicVerifier<Int>(direction: .ascending, strict: true)
        #expect((try await v.verify([1, 2, 2, 3], context: RunContext())).isRepair)
    }

    @Test("monotonic descending catches an upward step")
    func monotonicDescending() async throws {
        let v = MonotonicVerifier<Int>(direction: .descending)
        #expect((try await v.verify([5, 3, 4, 1], context: RunContext())).isRepair)
    }
}
