import Foundation

nonisolated enum AIError: Error, CustomStringConvertible {
    case notConfigured(String)
    case quotaExhausted(String)
    case emptyResponse(String)
    /// The request exceeded the model's input limit — callers can retry
    /// with fewer frames instead of failing the run.
    case promptTooLong(String)
    /// The provider answered, but the reply couldn't be used (not JSON, or
    /// validation left nothing) — the message says what to check.
    case unusableResponse(String)

    var description: String {
        switch self {
        case .notConfigured(let message): return message
        case .quotaExhausted(let message): return "Quota exhausted: \(message)"
        case .emptyResponse(let provider): return "\(provider) returned an empty response"
        case .promptTooLong(let provider): return "\(provider): the prompt is too long for the model"
        case .unusableResponse(let message): return message
        }
    }
}

/// One image frame sent to a multimodal provider.
nonisolated struct AIFrame: Sendable {
    var jpeg: Data
    var label: String   // e.g. "3.5s"
}

/// Provider-agnostic AI dispatch — the Swift port of ai_cli.py. Talks to the
/// locally installed `claude` (stream-json protocol), `gemini`, `codex`,
/// `qwen`, and `kimi` CLIs so it reuses whatever auth the user already has.
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

    /// The provider rejected the request as exceeding its input limit —
    /// retrying verbatim can never succeed; callers thin the frames instead.
    private static func isPromptTooLong(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("prompt is too long") || lowered.contains("prompt too long")
            || lowered.contains("context length") || lowered.contains("too many tokens")
            || lowered.contains("request too large") || lowered.contains("input is too long")
            || lowered.contains("exceeds the maximum")
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
    /// Per-task model overrides (the dispatcher's choices) beat the
    /// provider-level default, but only for the task's own provider.
    func resolveProviderModel(task: String, provider: String? = nil, model: String? = nil) -> (provider: String, model: String?) {
        let key = provider?.isEmpty == false ? provider! : providerKey(forTask: task)
        if let model, !model.isEmpty {
            return (key, model)
        }
        if key == providerKey(forTask: task),
           let taskModel = config.taskModels[task], !taskModel.isEmpty {
            return (key, taskModel)
        }
        let configured = config.providers[key]?.model
        let fallback = AICatalog.provider(key)?.defaultModel
        return (key, configured?.isEmpty == false ? configured : fallback)
    }

    /// Ordered (provider, model) candidates for a task: the configured choice
    /// first, then the catalog's recommended chain — deduplicated by
    /// provider, restricted to installed CLIs, and to image-capable
    /// providers when frames ride along. Drives dispatch and failover.
    func dispatchCandidates(task: String, providerOverride: String? = nil,
                            model: String? = nil, needsImages: Bool = false)
        -> [(provider: String, model: String?)] {
        var raw: [(String, String?)] = []
        if let providerOverride, !providerOverride.isEmpty {
            raw.append((providerOverride,
                        resolveProviderModel(task: task, provider: providerOverride, model: model).model))
        } else {
            let primary = resolveProviderModel(task: task, model: model)
            raw.append((primary.provider, primary.model))
        }
        for entry in AICatalog.recommendedChains[task] ?? [] {
            raw.append((entry.provider, entry.model))
        }

        var seen = Set<String>()
        var result: [(provider: String, model: String?)] = []
        for (key, model) in raw {
            guard !seen.contains(key), let provider = AICatalog.provider(key) else { continue }
            seen.insert(key)
            if needsImages && !provider.supportsImages { continue }
            guard binaryURL(for: provider) != nil else { continue }
            result.append((key, model))
        }
        return result
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

    /// Send a prompt (and optional frames) to the best available provider
    /// for `task`. The configured choice runs first; if it fails with an AI
    /// error (quota exhausted, not authenticated, empty response) the
    /// dispatcher fails over down the recommended chain, logging the switch,
    /// so a single provider outage never kills a run. The reply carries the
    /// provider/model that actually answered, for provenance stamping.
    func call(prompt: String,
              task: String,
              frames: [AIFrame]? = nil,
              video: URL? = nil,
              model: String? = nil,
              provider providerOverride: String? = nil,
              timeout: TimeInterval = 300,
              webAccess: Bool = false,
              log: (@Sendable (String) -> Void)? = nil) async throws -> AIResponse {
        let emit = log ?? { _ in }
        // Verbose logging (the log panels' checkbox): show exactly what the
        // model receives, for every task.
        if UserDefaults.standard.bool(forKey: "log.verbose") {
            let frameNote = (frames?.count ?? 0) > 0 ? " + \(frames?.count ?? 0) image frames" : ""
            emit("──── prompt (\(AICatalog.taskLabels[task] ?? task)\(frameNote)) ────\n\(prompt)\n──── end prompt ────")
        }
        let candidates = dispatchCandidates(task: task, providerOverride: providerOverride,
                                            model: model, needsImages: frames?.isEmpty == false)
        guard !candidates.isEmpty else {
            throw AIError.notConfigured(
                "No AI provider available for \(AICatalog.taskLabels[task] ?? task). Install the claude, gemini, codex, qwen, or kimi CLI, or check Settings → AI.")
        }
        var lastError: Error?
        var tooLongError: Error?
        for (index, candidate) in candidates.enumerated() {
            if index > 0 {
                let label = AICatalog.provider(candidate.provider)?.label ?? candidate.provider
                emit("Falling back to \(label) (\(candidate.model ?? "default model"))...")
            }
            do {
                let text = try await callProvider(key: candidate.provider, model: candidate.model,
                                                  prompt: prompt, frames: frames, video: video,
                                                  timeout: timeout, webAccess: webAccess, emit: emit)
                // The candidate that answered is the provenance — a
                // prediction made before the call would misattribute
                // anything produced after a failover.
                return AIResponse(text: text, provider: candidate.provider,
                                  model: candidate.model ?? AICatalog.provider(candidate.provider)?.defaultModel,
                                  task: task, fellBack: index > 0)
            } catch let error as AIError {
                lastError = error
                if case .promptTooLong = error { tooLongError = error }
                let label = AICatalog.provider(candidate.provider)?.label ?? candidate.provider
                emit("\(label) failed: \(error)")
            }
        }
        // When ANY candidate choked on prompt size, surface that — the
        // caller can shrink the request and retry, which no amount of
        // provider fallback can do.
        throw tooLongError ?? lastError ?? AIError.emptyResponse("AI dispatch")
    }

    private func callProvider(key: String, model: String?, prompt: String,
                              frames: [AIFrame]?, video: URL? = nil, timeout: TimeInterval,
                              webAccess: Bool = false,
                              emit: @escaping @Sendable (String) -> Void) async throws -> String {
        guard let provider = AICatalog.provider(key) else {
            throw AIError.notConfigured("Unknown AI provider: \(key)")
        }
        guard let binary = binaryURL(for: provider) else {
            throw AIError.notConfigured(
                "\(provider.label) CLI ('\(provider.bin)') not found. Install it or change the provider in Settings → AI.")
        }
        var effectiveFrames = frames
        if frames?.isEmpty == false && !provider.supportsImages {
            emit("\(provider.label) does not support image input — running text-only (analysis quality will degrade).")
            effectiveFrames = nil
        }

        if webAccess && key != "claude" {
            emit("\(provider.label) runs without live web tools here — the research relies on the model's own knowledge.")
        }
        switch key {
        case "claude":
            return try await callClaude(binary: binary, prompt: prompt, frames: effectiveFrames,
                                        model: model, timeout: timeout, webAccess: webAccess, log: emit)
        case "gemini":
            // Gemini is video-native: hand it the actual file (motion,
            // impact, audio) instead of sampled stills when one is offered.
            if video != nil {
                emit("Gemini: analyzing the video file natively")
            }
            return try await callGemini(binary: binary, prompt: prompt, frames: effectiveFrames,
                                        video: video, model: model, timeout: timeout, log: emit)
        case "codex":
            return try await callCodex(binary: binary, prompt: prompt,
                                       model: model, timeout: timeout, log: emit)
        case "qwen":
            return try await callQwen(binary: binary, prompt: prompt,
                                      model: model, timeout: timeout, log: emit)
        case "kimi":
            return try await callKimi(binary: binary, prompt: prompt,
                                      model: model, timeout: timeout, log: emit)
        default:
            throw AIError.notConfigured("Unknown AI provider: \(key)")
        }
    }

    // MARK: - Claude (stream-json protocol)

    private func callClaude(binary: URL, prompt: String, frames: [AIFrame]?,
                            model: String?, timeout: TimeInterval, webAccess: Bool = false,
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
        // Web research tasks: let the headless CLI actually search and read
        // pages instead of answering from memory.
        if webAccess { arguments += ["--allowedTools", "WebSearch,WebFetch"] }
        if let model { arguments += ["--model", model] }
        // Frontier planning models get the maximum extended-thinking budget —
        // the reel plan is the run's brain, and thinking depth shows there.
        let environment: [String: String]? = model?.contains("fable") == true
            ? ["MAX_THINKING_TOKENS": "31999"] : nil

        let maxRetries = 2
        for attempt in 0...maxRetries {
            let result: ProcessResult
            do {
                result = try await ProcessRunner.run(executable: binary, arguments: arguments,
                                                     stdin: stdin, timeout: timeout,
                                                     environment: environment)
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
                if Self.isPromptTooLong(errorMessage) {
                    throw AIError.promptTooLong("Claude")
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
                if Self.isPromptTooLong(cliError) {
                    throw AIError.promptTooLong("Claude")
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
                            video: URL? = nil,
                            model: String?, timeout: TimeInterval,
                            log: @Sendable (String) -> Void) async throws -> String {
        var arguments: [String] = []
        if let model { arguments += ["-m", model] }

        var temporaryDirectory: URL?
        var fullPrompt = prompt
        if let video {
            // The real video beats sampled stills: motion, impacts, and the
            // audio track all inform the analysis. Frames are skipped.
            fullPrompt = "[Video file — watch it directly] @\(video.path)\n"
                + "(The complete video is attached; timestamps in the instructions refer to video time.)\n\n"
                + prompt
        } else if let frames, !frames.isEmpty {
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
            if Self.isPromptTooLong(error) { throw AIError.promptTooLong("Gemini") }
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

    // MARK: - Qwen Code (text-only)

    private func callQwen(binary: URL, prompt: String, model: String?,
                          timeout: TimeInterval,
                          log: @Sendable (String) -> Void) async throws -> String {
        // Gemini CLI fork: headless mode reads the prompt from stdin, which
        // sidesteps argv length limits on long transcripts.
        var arguments: [String] = []
        if let model { arguments += ["-m", model] }
        let result = try await ProcessRunner.run(executable: binary, arguments: arguments,
                                                 stdin: Data(prompt.utf8), timeout: timeout)
        if result.exitCode != 0 {
            let error = String(result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
            if Self.isQuotaError(error) { throw AIError.quotaExhausted(String(error.prefix(200))) }
            if Self.isPromptTooLong(error) { throw AIError.promptTooLong("Qwen") }
            let lowered = error.lowercased()
            if lowered.contains("auth") || lowered.contains("login") || lowered.contains("api key") {
                throw AIError.notConfigured("Qwen Code CLI not authenticated. Run 'qwen' in Terminal to sign in.")
            }
            log("Qwen Code CLI error: \(error)")
            throw AIError.emptyResponse("Qwen")
        }
        var text = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip "Loaded cached credentials." style noise (same as Gemini).
        if let range = text.range(of: #"^[A-Z][^\n]*credentials\.\s*\n+"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        guard !text.isEmpty else { throw AIError.emptyResponse("Qwen") }
        return text
    }

    // MARK: - Kimi (text-only)

    private func callKimi(binary: URL, prompt: String, model: String?,
                          timeout: TimeInterval,
                          log: @Sendable (String) -> Void) async throws -> String {
        // `kimi -p` runs one prompt non-interactively: assistant text goes to
        // stdout; thinking and tool progress go to stderr.
        var arguments: [String] = []
        if let model { arguments += ["--model", model] }
        arguments += ["-p", prompt]
        let result = try await ProcessRunner.run(executable: binary, arguments: arguments, timeout: timeout)
        if result.exitCode != 0 {
            let error = String(result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
            if Self.isQuotaError(error) { throw AIError.quotaExhausted(String(error.prefix(200))) }
            if Self.isPromptTooLong(error) { throw AIError.promptTooLong("Kimi") }
            let lowered = error.lowercased()
            if lowered.contains("auth") || lowered.contains("login") || lowered.contains("api key") {
                throw AIError.notConfigured("Kimi CLI not authenticated. Run 'kimi' in Terminal and sign in with /login.")
            }
            log("Kimi CLI error: \(error)")
            throw AIError.emptyResponse("Kimi")
        }
        let text = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIError.emptyResponse("Kimi") }
        return text
    }
}

/// Filters an AI log stream down to short, human progress lines for a
/// sheet's one-line status: the verbose prompt dumps ("────" blocks) and
/// multi-line payloads that flow through `log:` never reach the UI.
nonisolated enum AIProgressLine {
    static func from(_ message: String) -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("────"),
              !trimmed.contains("\n"), trimmed.count <= 160 else { return nil }
        return trimmed
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
