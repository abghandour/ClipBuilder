import Foundation

/// Accepted source is a value-only editor handoff, never an Apply candidate.
nonisolated struct ScriptAuthorSubmission: Sendable, Equatable {
    let source: String
    let sampleParams: Data
}
