import Foundation

nonisolated enum BuilderAgentProvider: String, CaseIterable, Sendable, Identifiable {
    case local, claude, codex, gemini
    var id: String { rawValue }
    var label: String { rawValue == "local" ? "Local parser" : rawValue.capitalized }
    var disabledReason: String? {
        switch self {
        case .local, .claude: nil
        case .codex: "Codex is disabled: saved 0.153.4 help does not document per-server tool approvals, and native tool confinement has not passed real-client tests."
        case .gemini: "Gemini is disabled: provision a child-scoped API key or secure OAuth credential route for its isolated home, then pass real-client confinement tests."
        }
    }
}
