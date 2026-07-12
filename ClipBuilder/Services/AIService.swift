import Foundation

nonisolated enum AIError: Error, CustomStringConvertible {
    case notConfigured(String)
    case quotaExhausted(String)
    case emptyResponse(String)

    var description: String {
        switch self {
        case .notConfigured(let message): return message
        case .quotaExhausted(let message): return "Quota exhausted: \(message)"
        case .emptyResponse(let provider): return "\(provider) returned an empty response"
        }
    }
}

/// One image frame sent to a multimodal provider.
nonisolated struct AIFrame: Sendable {
    var jpeg: Data
    var label: String   // e.g. "3.5s"
}

/// Provider-agnostic AI dispatch — the Swift port of ai_cli.py. Talks to the
/// locally installed `claude` (stream-json protocol), `gemini`, and `codex`
/// CLIs so it reuses whatever auth the user already has.
actor AIService {
    var config: AIConfig

    init(config: AIConfig) {
        self.config = config
    }

    func updateConfig(_ config: AIConfig) {
        self.config = config
    }

    /// Case-insensitive markers for terminal quota/billing failures — abort
    /// batch loops instead of retrying doomed calls.
    private static let quotaMarkers = [
        "terminalquota", "quota exceeded", "quotaexceeded", "rate limit exceeded",
        "billing", "insufficient_quota", "you exceeded your current quota",
    ]

    private static func isQuotaError(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return quotaMarkers.contains { lowered.contains($0) }
    }

    // MARK: - Resolution

    func providerKey(forTask task: String) -> String {
        if let key = config.tasks[task], AICatalog.provider(key) != nil {
            return key
        }
        return AICatalog.taskDefaults[task] ?? "claude"
    }

    /// The (provider, model) pair a call for `task` would actually use —
    /// stamped into the DB for attribution, mirroring resolve_provider_model().
    func resolveProviderModel(task: String, provider: String? = nil, model: String? = nil) -> (provider: String, model: String?) {
        let key = provider?.isEmpty == false ? provider! : providerKey(forTask: task)
        if let model, !model.isEmpty {
            return (key, model)
        }
        let configured = config.providers[key]?.model
        let fallback = AICatalog.provider(key)?.defaultModel
        return (key, configured?.isEmpty == false ? configured : fallback)
    }

    private func binaryURL(for provider: AICatalog.Provider) -> URL? {
        let configured = config.providers[provider.key]?.bin
        let name = configured?.isEmpty == false ? configured! : provider.bin
        return ProcessRunner.locate(name)
    }

    func isProviderAvailable(_ key: String) -> Bool {
        guard let provider = AICatalog.provider(key) else { return false }
        return binaryURL(for: provider) != nil
    }

    // MARK: - Dispatch

    /// Send a prompt (and optional frames) to the provider configured for
    /// `task`. Returns the model's text response.
    func call(prompt: String,
              task: String,
              frames: [AIFrame]? = nil,
              model: String? = nil,
              provider providerOverride: String? = nil,
              timeout: TimeInterval = 300,
              log: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let emit = log ?? { _ in }
        let key = providerOverride ?? providerKey(forTask: task)
        guard let provider = AICatalog.provider(key) else {
            throw AIError.notConfigured("Unknown AI provider: \(key)")
        }
        guard let binary = binaryURL(for: provider) else {
            throw AIError.notConfigured(
                "\(provider.label) CLI ('\(provider.bin)') not found. Install it or change the provider in Settings → AI.")
        }
        let resolvedModel = resolveProviderModel(task: task, provider: key, model: model).model

        var effectiveFrames = frames
        if frames?.isEmpty == false && !provider.supportsImages {
            emit("\(provider.label) does not support image input — running text-only (analysis quality will degrade).")
            effectiveFrames = nil
        }

        switch key {
        case "claude":
            return try await callClaude(binary: binary, prompt: prompt, frames: effectiveFrames,
                                        model: resolvedModel, timeout: timeout, log: emit)
        case "gemini":
            return try await callGemini(binary: binary, prompt: prompt, frames: effectiveFrames,
                                        model: resolvedModel, timeout: timeout, log: emit)
        case "codex":
            return try await callCodex(binary: binary, prompt: prompt,
                                       model: resolvedModel, timeout: timeout, log: emit)
        default:
            throw AIError.notConfigured("Unknown AI provider: \(key)")
        }
    }

    // MARK: - Claude (stream-json protocol)

    private func callClaude(binary: URL, prompt: String, frames: [AIFrame]?,
                            model: String?, timeout: TimeInterval,
                            log: @Sendable (String) -> Void) async throws -> String {
        var content: [[String: Any]] = []
        for frame in frames ?? [] {
            content.append(["type": "text", "text": "[Frame at \(frame.label)]"])
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": frame.jpeg.base64EncodedString(),
                ],
            ])
        }
        content.append(["type": "text", "text": prompt])
        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": content],
        ]
        let stdin = try JSONSerialization.data(withJSONObject: message)

        var arguments = ["--print",
                         "--input-format", "stream-json",
                         "--output-format", "stream-json",
                         "--verbose"]
        if let model { arguments += ["--model", model] }

        let maxRetries = 2
        for attempt in 0...maxRetries {
            let result: ProcessResult
            do {
                result = try await ProcessRunner.run(executable: binary, arguments: arguments,
                                                     stdin: stdin, timeout: timeout)
            } catch {
                if error is CancellationError { throw error }
                if attempt < maxRetries {
                    log("Attempt failed (\(error)), retrying (\(attempt + 1)/\(maxRetries))...")
                    try await Task.sleep(for: .seconds(5))
                    continue
                }
                throw error
            }

            let raw = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            let stderr = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.exitCode != 0 && raw.isEmpty {
                let errorMessage = stderr.isEmpty ? "unknown error" : String(stderr.prefix(400))
                if Self.isQuotaError(errorMessage) {
                    throw AIError.quotaExhausted(String(errorMessage.prefix(200)))
                }
                let lowered = errorMessage.lowercased()
                if lowered.contains("auth") || lowered.contains("login") || lowered.contains("api key") {
                    throw AIError.notConfigured("Claude CLI not authenticated. Run 'claude' in Terminal to sign in.")
                }
                log("Claude CLI error: \(errorMessage.prefix(200))")
                if attempt < maxRetries {
                    log("Retrying (\(attempt + 1)/\(maxRetries))...")
                    try await Task.sleep(for: .seconds(5))
                    continue
                }
                throw AIError.emptyResponse("Claude")
            }

            // stream-json: one JSON object per line; keep the last assistant text.
            // A `result` event with is_error=true means the CLI failed (auth,
            // quota, …) — its message also appears as a synthetic assistant
            // message, so check the flag before trusting any text.
            var text = ""
            var cliError: String?
            for line in raw.split(separator: "\n") {
                guard let data = line.trimmingCharacters(in: .whitespaces).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if object["type"] as? String == "result", (object["is_error"] as? Bool) == true {
                    cliError = (object["result"] as? String) ?? "unknown error"
                    continue
                }
                guard object["type"] as? String == "assistant",
                      let messageObject = object["message"] as? [String: Any] else { continue }
                if let blocks = messageObject["content"] as? [[String: Any]] {
                    let joined = blocks
                        .filter { $0["type"] as? String == "text" }
                        .compactMap { $0["text"] as? String }
                        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                        .joined(separator: " ")
                    if !joined.trimmingCharacters(in: .whitespaces).isEmpty { text = joined }
                } else if let string = messageObject["content"] as? String,
                          !string.trimmingCharacters(in: .whitespaces).isEmpty {
                    text = string
                }
            }
            if let cliError {
                if Self.isQuotaError(cliError) {
                    throw AIError.quotaExhausted(String(cliError.prefix(200)))
                }
                let lowered = cliError.lowercased()
                if lowered.contains("not logged in") || lowered.contains("login")
                    || lowered.contains("auth") || lowered.contains("api key") {
                    throw AIError.notConfigured("Claude CLI not authenticated. Run 'claude' in Terminal and sign in with /login.")
                }
                log("Claude CLI error: \(cliError.prefix(200))")
                if attempt < maxRetries {
                    log("Retrying (\(attempt + 1)/\(maxRetries))...")
                    try await Task.sleep(for: .seconds(5))
                    continue
                }
                throw AIError.emptyResponse("Claude")
            }
            if !text.isEmpty { return text }
            if attempt < maxRetries {
                log("Empty response, retrying (\(attempt + 1)/\(maxRetries))...")
                try await Task.sleep(for: .seconds(5))
            }
        }
        throw AIError.emptyResponse("Claude")
    }

    // MARK: - Gemini

    private func callGemini(binary: URL, prompt: String, frames: [AIFrame]?,
                            model: String?, timeout: TimeInterval,
                            log: @Sendable (String) -> Void) async throws -> String {
        var arguments: [String] = []
        if let model { arguments += ["-m", model] }

        var temporaryDirectory: URL?
        var fullPrompt = prompt
        if let frames, !frames.isEmpty {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("cb_gemini_\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            temporaryDirectory = dir
            var references: [String] = []
            for (index, frame) in frames.enumerated() {
                let file = dir.appendingPathComponent(String(format: "frame_%03d.jpg", index))
                try frame.jpeg.write(to: file)
                references.append("[Frame at \(frame.label)] @\(file.path)")
            }
            fullPrompt = references.joined(separator: "\n") + "\n\n" + prompt
        }
        defer {
            if let temporaryDirectory {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
        }
        arguments += ["-p", fullPrompt]

        let result = try await ProcessRunner.run(executable: binary, arguments: arguments, timeout: timeout)
        if result.exitCode != 0 {
            let error = String(result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
            if Self.isQuotaError(error) { throw AIError.quotaExhausted(String(error.prefix(200))) }
            let lowered = error.lowercased()
            if lowered.contains("auth") || lowered.contains("login") || lowered.contains("api key") {
                throw AIError.notConfigured("Gemini CLI not authenticated. Run 'gemini auth' in Terminal.")
            }
            log("Gemini CLI error: \(error)")
            throw AIError.emptyResponse("Gemini")
        }
        var text = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip "Loaded cached credentials." style noise some versions emit.
        if let range = text.range(of: #"^[A-Z][^\n]*credentials\.\s*\n+"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        guard !text.isEmpty else { throw AIError.emptyResponse("Gemini") }
        return text
    }

    // MARK: - Codex (text-only)

    private func callCodex(binary: URL, prompt: String, model: String?,
                           timeout: TimeInterval,
                           log: @Sendable (String) -> Void) async throws -> String {
        var arguments = ["exec"]
        if let model { arguments += ["--model", model] }
        arguments.append("-")
        let result = try await ProcessRunner.run(executable: binary, arguments: arguments,
                                                 stdin: Data(prompt.utf8), timeout: timeout)
        if result.exitCode != 0 {
            let error = String(result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
            if Self.isQuotaError(error) { throw AIError.quotaExhausted(String(error.prefix(200))) }
            let lowered = error.lowercased()
            if lowered.contains("auth") || lowered.contains("login") || lowered.contains("api key") {
                throw AIError.notConfigured("Codex CLI not authenticated. Run 'codex login' in Terminal.")
            }
            log("Codex CLI error: \(error)")
            throw AIError.emptyResponse("Codex")
        }
        let text = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIError.emptyResponse("Codex") }
        return text
    }
}

/// Extracts a JSON object/array from an AI response that may be wrapped in
/// markdown fences or prose — the Swift port of analyzer.py's parser.
nonisolated enum AIResponseParser {
    static func jsonObject(from raw: String) -> [String: Any]? {
        guard let data = jsonData(from: raw) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func jsonData(from raw: String) -> Data? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacing(/^\s*```[a-z]*\s*/, with: "")
        text = text.replacing(/\s*```\s*$/, with: "")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Widest {...} span first, then [...], then the raw text.
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end {
            return String(text[start...end]).data(using: .utf8)
        }
        if let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end {
            return String(text[start...end]).data(using: .utf8)
        }
        return text.data(using: .utf8)
    }
}
