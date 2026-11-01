import Foundation

/// Ask AI on one page (docs/Page-Assistant-Plan.md). `context` reads the
/// store and the page's published state, never the database; `suggestions`
/// is pure given the context so each page's rules are testable; `actions`
/// are the page's existing visible controls, by id.
nonisolated protocol PageAssistant: Sendable {
    var page: String { get }
    var examples: [String] { get }
    @MainActor func context(store: AppStore) -> AssistantContext
    @MainActor func actions(store: AppStore) -> [AssistantAction]
    /// Rule-based, instant. Pure given the context so it is testable.
    func suggestions(for context: AssistantContext) -> [AssistantSuggestion]
    @MainActor func handle(_ text: String, store: AppStore) -> AskAIOutcome
    /// Settings typed text may change on this page (Phase 3 whitelist).
    /// Empty: the page is action-only. Read only when a request goes to
    /// the AI, so it may do a little work.
    @MainActor func assistSettings(store: AppStore) -> [AssistantSetting]
    /// Apply a validated patch (keys from `assistSettings`, values from
    /// `AssistantSetting.normalize`). Pages whose settings live in view
    /// @State send it through `store.assistant.sendSettings`.
    @MainActor func apply(settings: [String: String], store: AppStore) -> AskAIOutcome
}

nonisolated extension PageAssistant {
    @MainActor func context(store: AppStore) -> AssistantContext { AssistantContext(page: page) }
    @MainActor func actions(store: AppStore) -> [AssistantAction] { [] }
    func suggestions(for context: AssistantContext) -> [AssistantSuggestion] { [] }
    @MainActor func assistSettings(store: AppStore) -> [AssistantSetting] { [] }
    @MainActor func apply(settings: [String: String], store: AppStore) -> AskAIOutcome {
        .unavailable("Ask AI cannot change settings on \(page).")
    }
}

nonisolated enum AskAIOutcome: Equatable, Sendable {
    case started(jobTitle: String)
    case handled(String)
    case unavailable(String)
    /// A typed request went to the AI (`AITask.assist`); `AssistantModel`
    /// replaces it with the real outcome when the answer lands.
    case pending(String)

    var summary: String {
        switch self {
        case .started(let title): "Started \(title)"
        case .handled(let message), .unavailable(let message), .pending(let message): message
        }
    }

    var isPending: Bool {
        if case .pending = self { return true }
        return false
    }
}
