import Foundation
import Synchronization
@testable import Clip_Builder

/// Captures numbered translation requests at the process boundary; never launches a CLI.
nonisolated final class CaptionTranslationStub: Sendable {
    struct Request: Sendable {
        var texts: [String]
        var timeout: TimeInterval?
    }

    private let requests = Mutex<[Request]>([])
    private let messages = Mutex<[String]>([])

    func calls() -> [Request] { requests.withLock { $0 } }
    func log(_ message: String) { messages.withLock { $0.append(message) } }
    func logs() -> [String] { messages.withLock { $0 } }

    func service(response: @escaping @Sendable (Int, [String]) -> String = { _, texts in
        texts.enumerated().map { "\($0.offset + 1). English \($0.element)" }.joined(separator: "\n")
    }) -> AIService {
        var config = AIConfig()
        config.tasks["translate"] = "claude"
        config.providers["claude"] = AIProviderSettings(bin: "/bin/echo", model: "fixture")
        config.onDeviceOverrides["translation-batch"] = false
        return AIService(config: config) { _, _, stdin, timeout, _, _ in
            let object = try JSONSerialization.jsonObject(with: stdin ?? Data()) as? [String: Any]
            let message = object?["message"] as? [String: Any]
            let content = message?["content"] as? [[String: Any]]
            let prompt = content?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
            let texts = prompt.components(separatedBy: "\n").dropFirst().map { line in
                line.firstIndex(of: ".").map { String(line[line.index(after: $0)...]).trimmingCharacters(in: .whitespaces) } ?? line
            }
            let index = self.requests.withLock { calls in
                let index = calls.count
                calls.append(Request(texts: texts, timeout: timeout))
                return index
            }
            let event: [String: Any] = [
                "type": "assistant", "message": ["content": [["type": "text", "text": response(index, texts)]]]
            ]
            return ProcessResult(stdout: try JSONSerialization.data(withJSONObject: event), stderr: Data(), exitCode: 0)
        }
    }
}
