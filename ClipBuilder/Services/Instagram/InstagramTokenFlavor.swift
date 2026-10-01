import Foundation

nonisolated enum InstagramTokenFlavor: String, Codable, Sendable {
    case facebook, instagram

    /// A hint for the first connect probe; the successful host is authoritative.
    static func detect(_ token: String) -> InstagramTokenFlavor {
        token.hasPrefix("IG") ? .instagram : .facebook
    }

    var other: InstagramTokenFlavor { self == .facebook ? .instagram : .facebook }
}
