import Foundation
import CryptoKit

extension SHA256HashVerifier {
    /// Builds an ``SHA256HashVerifier`` wired with CryptoKit's SHA256
    /// implementation. The right default for in-app integrity checks on
    /// Apple platforms — the bytes are weighed on the device, in the
    /// user's hand, against nothing but themselves.
    public static func cryptoKit(name: String = "sha256-cryptokit") -> SHA256HashVerifier {
        SHA256HashVerifier(name: name) { data in
            Data(SHA256.hash(data: data))
        }
    }
}
