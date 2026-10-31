import Foundation

nonisolated protocol PageAssistant: Sendable {
    var page: String { get }
    var examples: [String] { get }
    @MainActor func handle(_ text: String, store: AppStore) -> AskAIOutcome
}

nonisolated enum AskAIOutcome: Equatable, Sendable {
    case started(jobTitle: String)
    case handled(String)
    case unavailable(String)

    var summary: String {
        switch self {
        case .started(let title): "Started \(title)"
        case .handled(let message), .unavailable(let message): message
        }
    }
}
