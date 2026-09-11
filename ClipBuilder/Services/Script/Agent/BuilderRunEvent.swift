import Foundation

/// Only the server produces tool outcomes. Provider prose never proves a mutation.
nonisolated struct BuilderRunEvent: Codable, Sendable, Equatable, Identifiable {
    enum Outcome: String, Codable, Sendable { case completed, refused, cancelled, failed }
    var runID: String
    var sequence: Int
    var requestID: String?
    var toolName: String?
    var sanitizedArguments: String?
    var argumentBytes: Int = 0
    var outcome: Outcome
    var message: String? = nil
    var resultBytes: Int = 0
    var duration: Double = 0
    var id: Int { sequence }
}

nonisolated struct BuilderRunRedactor: Sendable {
    var secrets: [String] = []

    func text(_ value: String, limit: Int = 2000) -> String {
        var safe = value
        for secret in secrets where !secret.isEmpty {
            safe = safe.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        // Remove credential-shaped fields even when the value wasn't supplied by us.
        // Bearer values go first: in one alternation "Authorization: Bearer x"
        // would match the field form at position 0, consume only "Bearer" and
        // leave the token behind.
        safe = safe.replacingOccurrences(
            of: #"(?i)bearer\s+[^\s\"\\]+"#, with: "[REDACTED]", options: .regularExpression)
        safe = safe.replacingOccurrences(
            of: #"(?i)(?:api[_-]?key|token|authorization|password)\s*[\"':= ]+\S+"#,
            with: "[REDACTED]", options: .regularExpression)
        safe = String(String.UnicodeScalarView(safe.unicodeScalars.filter {
            $0.value == 10 || $0.value == 9 || !CharacterSet.controlCharacters.contains($0)
        }))
        return String(decoding: Data(safe.utf8.prefix(limit)), as: UTF8.self)
    }

    /// Values are deliberately omitted: IDs, byte counts and typed outcomes suffice for audit.
    func arguments(_ keys: [String]) -> String {
        text("Fields: " + keys.sorted().prefix(16).map { text($0, limit: 32) }.joined(separator: ", "), limit: 256)
    }
}
