import Foundation

nonisolated enum TranslationBatch {
    static func perform(texts: [String], language: String, ai: AIService) async throws -> AIResponse {
        try await ai.call(prompt: prompt(texts: texts, language: language), task: "translate", timeout: 60, log: { _ in })
    }
    static func prompt(texts: [String], language: String) -> String {
        "Translate these captions to \(language). Preserve names and meaning. Return one numbered translation per input, using the same numbers.\n"
            + texts.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    /// Explicit indices prevent a missing answer shifting subsequent captions.
    static func parse(_ answer: String, count: Int) -> [Int: String] {
        var result: [Int: String] = [:]
        for line in answer.components(separatedBy: .newlines) {
            guard let match = line.firstMatch(of: /^\s*(\d+)[.)]\s*(.+)$/),
                  let index = Int(match.1), (1...max(1, count)).contains(index), index <= count
            else { continue }
            let text = String(match.2).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { result[index - 1] = text }
        }
        return result
    }
}
