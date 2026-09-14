import Foundation
@testable import Clip_Builder

/// All providers point at this executable, so even failover cannot use the network.
struct StubAI {
    let directory: TempDirectory
    let calls: URL
    let prompts: URL
    let service: AIService

    init(response: String, exitCode: Int = 0) throws {
        let directory = try TempDirectory(prefix: "LocalAIStub")
        self.directory = directory
        calls = directory.url.appendingPathComponent("calls.txt")
        prompts = directory.url.appendingPathComponent("prompts.txt")
        let executable = directory.url.appendingPathComponent("model")
        // The claude stream-json reader keeps the last assistant text and ignores
        // a bare result object, so answer the way the real CLI does.
        let event: [String: Any] = [
            "type": "assistant",
            "message": ["content": [["type": "text", "text": response]]],
        ]
        var output = String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)
        if exitCode != 0 {
            let failure: [String: Any] = ["type": "result", "is_error": true, "result": response]
            output += "\n" + String(decoding: try JSONSerialization.data(withJSONObject: failure), as: UTF8.self)
        }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = "#!/bin/sh\ncat >> \(quote(prompts.path))\nprintf 'call\\n' >> \(quote(calls.path))\nprintf '%s\\n' \(quote(output))\nexit \(exitCode)\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        var config = AIConfig()
        for provider in AICatalog.providers { config.providers[provider.key] = AIProviderSettings(bin: executable.path, model: nil) }
        config.tasks["route"] = "claude"
        config.tasks["soundbites"] = "claude"
        config.tasks["parse"] = "claude"
        config.tasks["translate"] = "claude"
        service = AIService(config: config)
    }
}
