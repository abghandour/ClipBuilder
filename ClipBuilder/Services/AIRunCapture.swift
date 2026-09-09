import Foundation

/// Task-local capture follows child tasks without mixing simultaneous runs.
nonisolated final class AIRunCapture: @unchecked Sendable {
    static let context = TaskLocal<AIRunCapture?>(wrappedValue: nil)
    static var current: AIRunCapture? { context.get() }
    private let lock = NSLock()
    private var captured: [AIRole] = []
    private var usedPrompts: [String: AIPromptPreview] = [:]
    var roles: [AIRole] { lock.withLock { captured } }
    var prompts: [String: AIPromptPreview] { lock.withLock { usedPrompts } }
    func reset() {
        lock.withLock {
            captured = []
            usedPrompts = [:]
        }
    }
    func annotateLast(technique: String) {
        lock.withLock {
            guard !captured.isEmpty else { return }
            captured[captured.count - 1].provenance.technique = technique
        }
    }
    func append(_ provenance: AIProvenance, prompt: String) {
        lock.withLock {
            let role = provenance.taskLabel ?? provenance.task ?? "AI"
            captured.append(AIRole(role: role, provenance: provenance))
            usedPrompts["\(captured.count). \(role)"] = AIPromptPreview(role: role, prompt: prompt)
        }
    }
}
