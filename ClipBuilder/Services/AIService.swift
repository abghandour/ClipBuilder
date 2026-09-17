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
    /// The CLI's sign-in is missing or stale. `provider` is the catalog key
    /// so the alert can offer to open that CLI's login; `detail` is what
    /// the CLI actually said.
    case notAuthenticated(provider: String, detail: String)

    var description: String {
        switch self {
        case .notConfigured(let message): return message
        case .notAuthenticated(let provider, let detail):
            let label = AICatalog.provider(provider)?.label ?? provider
            let said = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(label) is not signed in. Use Sign In to open its login in Terminal."
                + (said.isEmpty ? "" : " The CLI said: \(said)")
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
    /// Instance-scoped process boundary for testing dispatch and retry behavior.
    typealias ProcessExecutor = @Sendable (URL, [String], Data?, TimeInterval?, [String: String]?) async throws -> ProcessResult

    private let executeProcess: ProcessExecutor
    private var unavailableProviders = Set<String>()
    private var loggedUnavailableProviders = Set<String>()
    var config: AIConfig

    /// A provider that just failed is left alone for a while so a batch does
    /// not pay a doomed call (and its timeout) on every item. Explicit
    /// provider choices still run; the cooldown only steers automatic dispatch.
    struct Cooldown: Sendable, Equatable {
        var until: Date
        var reason: String
    }
    private var cooldowns: [String: Cooldown] = [:]

    init(config: AIConfig, executeProcess: @escaping ProcessExecutor = { executable, arguments, stdin, timeout, environment in
        try await ProcessRunner.run(executable: executable, arguments: arguments,
                                    stdin: stdin, timeout: timeout, environment: environment)
    }) {
        self.config = config
        self.executeProcess = executeProcess
    }

    func updateConfig(_ config: AIConfig) {
        self.config = config
        // Changing providers, models or binaries is the user acting on the
        // failure; start fresh rather than keep skipping the fixed provider.
        cooldowns.removeAll()
    }

    /// Active cooldowns by provider key (expired entries are dropped).
    func activeCooldowns(now: Date = Date()) -> [String: Cooldown] {
        cooldowns = cooldowns.filter { $0.value.until > now }
        return cooldowns
    }

    /// Ends a provider's cooldown, e.g. after the user signs in again.
    func clearCooldown(provider: String) { cooldowns[provider] = nil }

    private func startCooldown(provider: String, reason: String) {
        let minutes = config.providerCooldownMinutes
        guard minutes > 0 else { return }
        cooldowns[provider] = Cooldown(until: Date().addingTimeInterval(Double(minutes) * 60), reason: reason)
    }

    /// Failures that describe the provider rather than this request.
    static func deservesCooldown(_ error: Error) -> Bool {
        if let error = error as? AIError {
            switch error {
            case .promptTooLong, .unusableResponse: return false
            case .notConfigured, .notAuthenticated, .quotaExhausted, .emptyResponse: return true
            }
        }
        // Timeouts scale with the request (Analyzer thins frames and retries
        // the same provider), so they do not cool a provider down.
        return false
    }

    private static func cooldownText(_ cooldown: Cooldown, now: Date = Date()) -> String {
        let minutes = max(1, Int((cooldown.until.timeIntervalSince(now) / 60).rounded(.up)))
        return "cooling down for \(minutes) more minute\(minutes == 1 ? "" : "s") after: \(cooldown.reason)"
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

    static func isProviderUnavailable(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return ["ineligibletiererror", "no longer supported", "migrate to the antigravity"]
            .contains { lowered.contains($0) }
    }

    static func firstCLIErrorLine(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("at ") } ?? "Unknown CLI error"
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

    /// An auth-looking CLI failure becomes `.notAuthenticated` only when the
    /// CLI's own status check agrees (or can't answer). A CLI that says it
    /// is signed in had some other problem, which the caller logs and
    /// handles like any other error. The raw text is always logged so a
    /// bug report shows what the CLI really said.
    private static func authFailure(provider key: String, binary: URL, raw: String,
                                    log: @Sendable (String) -> Void) async -> AIError? {
        guard ProviderAuth.isAuthFailure(raw) else { return nil }
        let label = AICatalog.provider(key)?.label ?? key
        let detail = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        log("\(label) CLI error: \(detail)")
        if await ProviderAuth.status(provider: key, binary: binary) == .signedIn {
            log("\(label) says it is signed in — treating this as a request failure, not a sign-in problem")
            return nil
        }
        return .notAuthenticated(provider: key, detail: detail)
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
    /// What a model alias resolved to on its last call ("fable" →
    /// "claude-fable-5-1"), so provenance names the model that answered.
    private var resolvedModels: [String: String] = [:]

    func resolveProviderModel(task: String, provider: String? = nil, model: String? = nil) -> (provider: String, model: String?) {
        let key = provider?.isEmpty == false ? provider! : providerKey(forTask: task)
        if let model, !model.isEmpty {
            return (key, model)
        }
        if key == providerKey(forTask: task),
           let taskModel = config.taskModels[task], !taskModel.isEmpty {
            return (key, taskModel)
        }
        if task == "route", let recommended = AICatalog.recommendedChains[task]?.first(where: { $0.provider == key }) {
            return (key, recommended.model)
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
                            model: String? = nil, needsImages: Bool = false,
                            log: (@Sendable (String) -> Void)? = nil)
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
        var cooling: [(provider: String, model: String?)] = []
        let active = activeCooldowns()
        for (key, requestedModel) in raw {
            guard !seen.contains(key), let provider = AICatalog.provider(key) else { continue }
            // A model the CLI no longer lists (an old catalog entry, a stale
            // setting) becomes the provider's default when that is offered,
            // else the first model the CLI does list; nothing offered skips
            // the provider rather than sending a call bound to fail.
            var model = requestedModel
            if let stale = requestedModel, !AICatalog.offers(provider: key, model: stale) {
                let replacement = [config.providers[key]?.model, provider.defaultModel]
                    .compactMap { $0 }.first { !$0.isEmpty && AICatalog.offers(provider: key, model: $0) }
                    ?? AICatalog.models(for: key).first { AICatalog.offers(provider: key, model: $0) }
                guard let replacement else {
                    log?("Skipping \(provider.label): it no longer offers \(AICatalog.modelDisplayName(stale))")
                    continue
                }
                log?("\(provider.label) no longer offers \(AICatalog.modelDisplayName(stale)) — using \(AICatalog.modelDisplayName(replacement))")
                model = replacement
            }
            seen.insert(key)
            if unavailableProviders.contains(key) {
                if let log, loggedUnavailableProviders.insert(key).inserted {
                    log("Skipping \(provider.label): unavailable for this account")
                }
                continue
            }
            if needsImages && !provider.supportsImages { continue }
            guard binaryURL(for: provider) != nil else { continue }
            // The user's explicit choice always runs; automatic chains skip
            // a provider that just failed.
            if let cooldown = active[key], key != providerOverride {
                log?("Skipping \(provider.label): \(Self.cooldownText(cooldown))")
                cooling.append((key, model))
                continue
            }
            result.append((key, model))
        }
        // Nothing left is worse than a doomed retry: fall back to the
        // cooling providers rather than fail outright.
        if result.isEmpty, !cooling.isEmpty {
            log?("Every provider is cooling down — trying them anyway")
            return cooling
        }
        return result
    }

    private func binaryURL(for provider: AICatalog.Provider) -> URL? {
        let configured = config.providers[provider.key]?.bin
        let name = configured?.isEmpty == false ? configured! : provider.bin
        return ProcessRunner.locate(name)
    }

    /// The located CLI for a provider key, honoring the Settings override.
    func binaryURL(forProvider key: String) -> URL? {
        guard let provider = AICatalog.provider(key) else { return nil }
        return binaryURL(for: provider)
    }

    func isProviderAvailable(_ key: String) -> Bool {
        guard !unavailableProviders.contains(key), let provider = AICatalog.provider(key) else { return false }
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
              fallbackFrames: (@Sendable () async throws -> [AIFrame])? = nil,
              model: String? = nil,
              provider providerOverride: String? = nil,
              timeout: TimeInterval = 300,
              timeoutForFrameCount: (@Sendable (Int) -> TimeInterval)? = nil,
              webAccess: Bool = false,
              maximumAttempts: Int? = nil,
              log: (@Sendable (String) -> Void)? = nil,
              waiting: (@Sendable (_ provider: String, _ timeout: TimeInterval) -> Void)? = nil) async throws -> AIResponse {
        let emit = log ?? { _ in }
        // Timed from here so a failover's wasted attempt counts: this is the
        // wait the user actually sat through.
        let started = ContinuousClock.now
        // Verbose logging (the log panels' checkbox): show exactly what the
        // model receives, for every task.
        if UserDefaults.standard.bool(forKey: "log.verbose") {
            let frameNote = (frames?.count ?? 0) > 0 ? " + \(frames?.count ?? 0) image frames" : ""
            emit("──── prompt (\(AICatalog.taskLabels[task] ?? task)\(frameNote)) ────\n\(prompt)\n──── end prompt ────")
        }
        let candidates = dispatchCandidates(task: task, providerOverride: providerOverride,
                                            model: model, needsImages: frames?.isEmpty == false || video != nil, log: emit)
        guard !candidates.isEmpty else {
            let label = AICatalog.taskLabels[task] ?? task
            let key = providerOverride?.isEmpty == false ? providerOverride! : providerKey(forTask: task)
            let needsImages = frames?.isEmpty == false || video != nil
            if let provider = AICatalog.provider(key), needsImages, !provider.supportsImages {
                throw AIError.notConfigured(
                    "\(label) is routed to \(provider.label), which cannot take image frames, and no image-capable fallback is installed. Choose Claude Code, Gemini CLI or Codex CLI for \(label) in Settings → AI → Task Routing.")
            }
            if let provider = AICatalog.provider(key), binaryURL(for: provider) == nil {
                throw AIError.notConfigured(
                    "\(label) is routed to \(provider.label), whose CLI ('\(provider.bin)') is not installed, and no fallback is installed either. Install it or change the provider in Settings → AI.")
            }
            throw AIError.notConfigured(
                "No AI provider available for \(label). Install the claude, gemini, codex, qwen, or kimi CLI, or check Settings → AI.")
        }
        var loadedFallbackFrames: [AIFrame]?
        var lastError: Error?
        var tooLongError: Error?
        for (index, candidate) in candidates.prefix(maximumAttempts.map { max(1, $0) } ?? candidates.count).enumerated() {
            if index > 0 {
                let label = AICatalog.provider(candidate.provider)?.label ?? candidate.provider
                emit("Falling back to \(label) (\(candidate.model ?? "default model"))...")
            }
            do {
                try Task.checkCancellation()
                var candidateFrames = frames
                var candidateVideo = video
                if video != nil, candidate.provider != "gemini" {
                    if let fallbackFrames {
                        if loadedFallbackFrames == nil { loadedFallbackFrames = try await fallbackFrames() }
                        candidateFrames = loadedFallbackFrames
                    }
                    guard candidateFrames?.isEmpty == false else {
                        throw AIError.notConfigured("\(candidate.provider) cannot accept native video. A still-frame fallback is required.")
                    }
                    candidateVideo = nil
                }
                let candidateTimeout = candidateVideo == nil
                    ? (timeoutForFrameCount?(candidateFrames?.count ?? 0) ?? timeout) : timeout
                waiting?(AICatalog.provider(candidate.provider)?.label ?? candidate.provider, candidateTimeout)
                let text = try await callProvider(key: candidate.provider, model: candidate.model,
                                                  prompt: prompt, frames: candidateFrames, video: candidateVideo,
                                                  timeout: candidateTimeout,
                                                  webAccess: webAccess,
                                                  maximumRetries: maximumAttempts.map { max(0, $0 - 1) } ?? 2, emit: emit)
                // The candidate that answered is the provenance — a
                // prediction made before the call would misattribute
                // anything produced after a failover.
                cooldowns[candidate.provider] = nil
                let response = AIResponse(text: text, provider: candidate.provider,
                                  model: candidate.model.map { resolvedModels[$0] ?? $0 }
                                      ?? AICatalog.provider(candidate.provider)?.defaultModel,
                                  task: task, fellBack: index > 0,
                                  duration: (ContinuousClock.now - started).seconds)
                AIRunCapture.current?.append(response.provenance, prompt: prompt)
                return response
            } catch let error as AIError {
                lastError = error
                if case .promptTooLong = error { tooLongError = error }
                let label = AICatalog.provider(candidate.provider)?.label ?? candidate.provider
                emit("\(label) failed: \(error)")
                if Self.deservesCooldown(error) { startCooldown(provider: candidate.provider, reason: String(describing: error).prefix(120).description) }
            } catch {
                if Self.deservesCooldown(error) { startCooldown(provider: candidate.provider, reason: String(describing: error).prefix(120).description) }
                if error is CancellationError || video == nil { throw error }
                // A timed-out still fallback must reach Analyzer for thinning,
                // even when this dispatch began as a native-video request.
                if candidate.provider == "claude",
                   let processError = error as? ProcessRunnerError, case .timedOut = processError {
                    throw processError
                }
                lastError = error
                emit("\(candidate.provider) native-video request failed: \(error)")
            }
        }
        // When ANY candidate choked on prompt size, surface that — the
        // caller can shrink the request and retry, which no amount of
        // provider fallback can do.
        throw tooLongError ?? lastError ?? AIError.emptyResponse("AI dispatch")
    }

    private func callProvider(key: String, model: String?, prompt: String,
                              frames: [AIFrame]?, video: URL? = nil, timeout: TimeInterval,
                              webAccess: Bool = false, maximumRetries: Int = 2,
                              emit: @escaping @Sendable (String) -> Void) async throws -> String {
        guard let provider = AICatalog.provider(key) else {
            throw AIError.notConfigured("Unknown AI provider: \(key)")
        }
        guard let binary = binaryURL(for: provider) else {
            throw AIError.notConfigured(
                "\(provider.label) CLI ('\(provider.bin)') not found. Install it or change the provider in Settings → AI.")
        }
        guard video == nil || key == "gemini" else {
            throw AIError.notConfigured("\(provider.label) cannot accept native video. Supply still frames or choose Gemini.")
        }
        guard frames?.isEmpty != false || provider.supportsImages else {
            throw AIError.notConfigured("\(provider.label) cannot accept image input. Choose an image-capable provider.")
        }
        let effectiveFrames = frames

        if webAccess && key != "claude" {
            emit("\(provider.label) runs without live web tools here — the research relies on the model's own knowledge.")
        }
        switch key {
        case "claude":
            return try await callClaude(binary: binary, prompt: prompt, frames: effectiveFrames,
                                        model: model, timeout: timeout, webAccess: webAccess, maxRetries: maximumRetries, log: emit)
        case "gemini":
            // Gemini is video-native: hand it the actual file (motion,
            // impact, audio) instead of sampled stills when one is offered.
            if video != nil {
                emit("Gemini: analyzing the video file natively")
            }
            return try await callGemini(binary: binary, prompt: prompt, frames: effectiveFrames,
                                        video: video, model: model, timeout: timeout, log: emit)
        case "codex":
            return try await callCodex(binary: binary, prompt: prompt, frames: effectiveFrames,
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

    private func runRequest(executable: URL, arguments: [String], stdin: Data? = nil,
                            timeout: TimeInterval?, environment: [String: String]? = nil) async throws -> ProcessResult {
        let timing = PerfSignpost.begin("AIRemoteWait", metadata: executable.lastPathComponent)
        defer { PerfSignpost.end(timing) }
        return try await executeProcess(executable, arguments, stdin, timeout, environment)
    }

    // MARK: - Claude (stream-json protocol)

    private func callClaude(binary: URL, prompt: String, frames: [AIFrame]?,
                            model: String?, timeout: TimeInterval, webAccess: Bool = false, maxRetries: Int = 2,
                            log: @Sendable (String) -> Void) async throws -> String {
        var preparation = PerfSignpost.begin("AIInput", metadata: "claude")
        defer { PerfSignpost.end(preparation) }
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

        PerfSignpost.end(preparation)
        preparation = nil
        for attempt in 0...maxRetries {
            let result: ProcessResult
            do {
                result = try await runRequest(executable: binary, arguments: arguments,
                                                     stdin: stdin, timeout: timeout,
                                                     environment: environment)
            } catch {
                if error is CancellationError { throw error }
                if let processError = error as? ProcessRunnerError, case .timedOut = processError {
                    throw processError
                }
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
                if let failure = await Self.authFailure(provider: "claude", binary: binary,
                                                        raw: errorMessage, log: log) {
                    throw failure
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
                // The session's opening line names the model that actually
                // answers, so an alias ("fable") is recorded as the real one.
                if object["type"] as? String == "system", let requested = model,
                   let actual = object["model"] as? String, !actual.isEmpty {
                    resolvedModels[requested] = actual
                    continue
                }
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
                if let failure = await Self.authFailure(provider: "claude", binary: binary,
                                                        raw: cliError, log: log) {
                    throw failure
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
        var preparation = PerfSignpost.begin("AIInput", metadata: "gemini")
        defer { PerfSignpost.end(preparation) }
        var arguments: [String] = []
        if let model { arguments += ["-m", model] }

        var temporaryDirectory: URL?
        var fullPrompt = prompt
        if let video {
            // The real video beats sampled stills: motion, impacts, and the
            // audio track all inform the analysis. Auxiliary note/identity
            // frames still ride along; the sampled fallback grid is lazy.
            fullPrompt = "[Video file — watch it directly] @\(video.path)\n"
                + "(The complete video is attached; timestamps in the instructions refer to video time.)\n\n"
                + prompt
        }
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
            fullPrompt = references.joined(separator: "\n") + "\n\n" + fullPrompt
        }
        defer {
            if let temporaryDirectory {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
        }
        arguments += ["-p", fullPrompt]

        PerfSignpost.end(preparation)
        preparation = nil
        let result = try await runRequest(executable: binary, arguments: arguments, timeout: timeout)
        if result.exitCode != 0 {
            let rawError = result.stderrText + "\n" + result.stdoutText
            let error = Self.firstCLIErrorLine(rawError)
            if Self.isProviderUnavailable(rawError) {
                unavailableProviders.insert("gemini")
                log("Gemini CLI error: \(error)")
                throw AIError.notConfigured(
                    "Gemini CLI is no longer available for this account (Google: \(error)). Choose another analysis provider in Settings → AI.")
            }
            if Self.isQuotaError(rawError) { throw AIError.quotaExhausted(String(error.prefix(200))) }
            if Self.isPromptTooLong(rawError) { throw AIError.promptTooLong("Gemini") }
            if let failure = await Self.authFailure(provider: "gemini", binary: binary, raw: rawError, log: log) {
                throw failure
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

    /// Codex attaches images to the prompt with `--image`, one file each,
    /// in order; the prompt opens with the list of what each image is so
    /// the model can tie a frame to its timestamp.
    private func callCodex(binary: URL, prompt: String, frames: [AIFrame]?, model: String?,
                           timeout: TimeInterval,
                           log: @Sendable (String) -> Void) async throws -> String {
        let preparation = PerfSignpost.begin("AIInput", metadata: "codex")
        var arguments = ["exec"]
        if let model { arguments += ["--model", model] }
        var fullPrompt = prompt
        var temporaryDirectory: URL?
        if let frames, !frames.isEmpty {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("cb_codex_\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            temporaryDirectory = dir
            var legend: [String] = []
            for (index, frame) in frames.enumerated() {
                let file = dir.appendingPathComponent(String(format: "frame_%03d.jpg", index))
                try frame.jpeg.write(to: file)
                arguments += ["--image", file.path]
                legend.append("Image \(index + 1): \(frame.label)")
            }
            fullPrompt = "The attached images, in order:\n" + legend.joined(separator: "\n") + "\n\n" + prompt
        }
        defer {
            if let temporaryDirectory {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
        }
        arguments.append("-")
        let stdin = Data(fullPrompt.utf8)
        PerfSignpost.end(preparation)
        let result = try await runRequest(executable: binary, arguments: arguments,
                                                 stdin: stdin, timeout: timeout)
        if result.exitCode != 0 {
            let error = String(result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
            if Self.isQuotaError(error) { throw AIError.quotaExhausted(String(error.prefix(200))) }
            if let failure = await Self.authFailure(provider: "codex", binary: binary, raw: error, log: log) {
                throw failure
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
        let preparation = PerfSignpost.begin("AIInput", metadata: "qwen")
        // Gemini CLI fork: headless mode reads the prompt from stdin, which
        // sidesteps argv length limits on long transcripts.
        var arguments: [String] = []
        if let model { arguments += ["-m", model] }
        let stdin = Data(prompt.utf8)
        PerfSignpost.end(preparation)
        let result = try await runRequest(executable: binary, arguments: arguments,
                                                 stdin: stdin, timeout: timeout)
        if result.exitCode != 0 {
            let error = String(result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
            if Self.isQuotaError(error) { throw AIError.quotaExhausted(String(error.prefix(200))) }
            if Self.isPromptTooLong(error) { throw AIError.promptTooLong("Qwen") }
            if let failure = await Self.authFailure(provider: "qwen", binary: binary, raw: error, log: log) {
                throw failure
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
        let preparation = PerfSignpost.begin("AIInput", metadata: "kimi")
        // `kimi -p` runs one prompt non-interactively: assistant text goes to
        // stdout; thinking and tool progress go to stderr.
        var arguments: [String] = []
        if let model { arguments += ["--model", model] }
        arguments += ["-p", prompt]
        PerfSignpost.end(preparation)
        let result = try await runRequest(executable: binary, arguments: arguments, timeout: timeout)
        if result.exitCode != 0 {
            let error = String(result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
            if Self.isQuotaError(error) { throw AIError.quotaExhausted(String(error.prefix(200))) }
            if Self.isPromptTooLong(error) { throw AIError.promptTooLong("Kimi") }
            if let failure = await Self.authFailure(provider: "kimi", binary: binary, raw: error, log: log) {
                throw failure
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
