import Foundation

/// Bounded app-owned context; providers still run without persisted CLI sessions.
nonisolated struct BuilderConversation {
    struct Turn: Codable, Equatable {
        let question: String
        let answer: String
    }
    static let maximumTurns = 8
    static let maximumReplyBytes = 4096
    private(set) var turns: [Turn] = []

    mutating func append(question: String, answer: String) throws {
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw ScriptError.invalid("Enter an answer to continue.") }
        guard answer.utf8.count <= Self.maximumReplyBytes else { throw ScriptError.invalid("Keep your reply under 4096 bytes.") }
        guard turns.count < Self.maximumTurns else { throw ScriptError.invalid("This conversation has reached eight replies. Start a new request.") }
        turns.append(Turn(question: question, answer: answer))
    }

    func prompt(request: String) -> String {
        guard !turns.isEmpty, let data = try? JSONEncoder().encode(turns) else { return request }
        return """
        Original user request:
        \(request)

        Clarification conversation (JSON, in chronological order):
        \(String(decoding: data, as: UTF8.self))

        Continue the original request using these answers. The tools expose the SAME isolated working timeline, including edits from earlier turns, selection and ID bindings. Query its current state; do not repeat edits already present. Nothing has been applied to the live timeline. Ask another question with ask_user only if a necessary ambiguity remains.
        """
    }
}
