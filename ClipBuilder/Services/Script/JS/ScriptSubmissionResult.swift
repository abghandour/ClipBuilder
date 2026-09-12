import Foundation

nonisolated struct ScriptSubmissionResult: Codable, Sendable {
    let status: String
    let diagnostics: [ScriptDiagnostic]
    let partial: Bool
    let message: String
}
