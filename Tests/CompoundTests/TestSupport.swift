import Foundation
@testable import Compound

// Ergonomic Verdict accessors for tests. Lives in the test target so we
// don't touch Sources/.
extension Verdict {
    var isReject: Bool {
        if case .reject = self { return true }
        return false
    }

    var isRepair: Bool {
        if case .repair = self { return true }
        return false
    }

    var isEscalate: Bool {
        if case .escalate = self { return true }
        return false
    }
}
