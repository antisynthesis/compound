import Foundation

/// Personal-data detection that stays on-device, using Foundation's
/// `NSDataDetector`. Surfaces phone numbers, email addresses, mailing
/// addresses, dates, links, and transit info. Higher recall than
/// ``PIIVerifier`` for international phone formats and full addresses, and ships
/// free on every Apple platform — no cloud, no third party seeing the data you
/// are trying to protect. Use ``PIIVerifier`` when you need a hard guarantee on
/// the exact categories listed.
public struct NSDataDetectorPIIVerifier: Verifier {
    public typealias Input = String
    public let name: String
    public let cost: VerifierCost = .parse
    /// Active categories.
    public let categories: Set<Category>
    /// Verdict kind on detection.
    public let returnAs: SecretsVerifier.VerdictKind
    private let detector: NSDataDetector

    /// Categories surfaced by `NSDataDetector`.
    public enum Category: Sendable, Hashable, CaseIterable {
        case phoneNumber, address, date, link, transitInformation

        var nsType: NSTextCheckingResult.CheckingType {
            switch self {
            case .phoneNumber: return .phoneNumber
            case .address: return .address
            case .date: return .date
            case .link: return .link
            case .transitInformation: return .transitInformation
            }
        }

        var label: String {
            switch self {
            case .phoneNumber: return "phone"
            case .address: return "address"
            case .date: return "date"
            case .link: return "link"
            case .transitInformation: return "transit"
            }
        }
    }

    /// Creates a verifier with an `NSDataDetector` configured for the
    /// requested categories.
    ///
    /// - Throws: Any error from `NSDataDetector.init(types:)`.
    public init(
        name: String = "pii-detector",
        categories: Set<Category> = [.phoneNumber, .address],
        returnAs: SecretsVerifier.VerdictKind = .repair
    ) throws {
        self.name = name
        self.categories = categories
        self.returnAs = returnAs
        let mask = categories.reduce(NSTextCheckingResult.CheckingType()) { $0.union($1.nsType) }
        self.detector = try NSDataDetector(types: mask.rawValue)
    }

    public func verify(_ input: String, context _: RunContext) async throws -> Verdict {
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        let matches = detector.matches(in: input, range: range)
        var hits: Set<String> = []
        for match in matches {
            for cat in categories where match.resultType.contains(cat.nsType) {
                hits.insert(cat.label)
            }
        }
        if hits.isEmpty { return .pass }
        let msg = "NSDataDetector found PII: \(hits.sorted().joined(separator: ", "))"
        switch returnAs {
        case .repair: return .repair(Diagnostic(verifier: name, message: msg, suggestion: "redact or replace these values"))
        case .reject: return .reject(msg)
        }
    }
}
