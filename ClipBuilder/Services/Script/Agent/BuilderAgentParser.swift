import Foundation

nonisolated enum BuilderAgentMessage: Sendable, Equatable {
    case progress(String)
    case final(String)
    case model(String)
    case terminalError(String)
    case toolObserved(String)
}

/// Byte-oriented framing preserves UTF-8 split across arbitrary pipe reads.
/// This value is owned exclusively by the pipe reader, never the UI task.
nonisolated struct BuilderAgentParser: Sendable {
    let provider: BuilderAgentProvider
    var maximumLineBytes = 256 * 1024
    private var pending = Data()
    private var terminal = false
    private var providerText = ""
    private var sawClaudeTextDelta = false
    private var validatedInventory = false

    init(provider: BuilderAgentProvider, maximumLineBytes: Int = 256 * 1024) {
        self.provider = provider; self.maximumLineBytes = maximumLineBytes
    }

    mutating func feed(_ chunk: Data) throws -> [BuilderAgentMessage] {
        var messages: [BuilderAgentMessage] = []
        // Bounded even when one chunk contains many lines or a huge partial line.
        for byte in chunk {
            if byte == 10 {
                if !pending.isEmpty { messages += try line(pending) }
                pending.removeAll(keepingCapacity: true)
            } else {
                guard pending.count < maximumLineBytes else { throw ScriptError.invalid("Agent JSONL line exceeds limit.") }
                pending.append(byte)
            }
        }
        return messages
    }

    mutating func finish() throws -> [BuilderAgentMessage] {
        var messages: [BuilderAgentMessage] = []
        if !pending.isEmpty { messages = try line(pending); pending.removeAll() }
        guard terminal else { throw ScriptError.invalid("Agent stream ended without a terminal result.") }
        return messages
    }

    private mutating func line(_ data: Data) throws -> [BuilderAgentMessage] {
        guard String(data: data, encoding: .utf8) != nil,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { throw ScriptError.invalid("Malformed agent JSONL.") }
        if terminal { throw ScriptError.invalid("Agent emitted data after its terminal result.") }
        switch provider {
        case .local: throw ScriptError.invalid("Local parser has no CLI stream.")
        case .claude: return try claude(type, object)
        case .codex: return try codex(type, object)
        case .gemini: return try gemini(type, object)
        }
    }

    private mutating func claude(_ type: String, _ value: [String: Any]) throws -> [BuilderAgentMessage] {
        switch type {
        case "system":
            var messages: [BuilderAgentMessage] = []
            if let tools = value["tools"] as? [String] {
                guard tools.allSatisfy(Self.allowedTool) else { throw ScriptError.invalid("Claude exposed an unconfined tool inventory.") }
                validatedInventory = true
            }
            if let model = value["model"] as? String { messages.append(.model(model)) }
            return messages
        case "stream_event":
            let event = value["event"] as? [String: Any] ?? [:]
            if let delta = event["delta"] as? [String: Any], let text = delta["text"] as? String {
                sawClaudeTextDelta = true
                return [.progress(text)]
            }
            if let block = event["content_block"] as? [String: Any], block["type"] as? String == "tool_use" {
                return [try observed(block["name"] as? String)]
            }
            return []
        case "assistant":
            let message = value["message"] as? [String: Any] ?? [:]
            defer { sawClaudeTextDelta = false }
            let messages: [BuilderAgentMessage] = try (message["content"] as? [[String: Any]] ?? []).compactMap { block in
                if block["type"] as? String == "tool_use" { return try observed(block["name"] as? String) }
                if !sawClaudeTextDelta, let text = block["text"] as? String { return .progress(text) }
                return nil
            }
            return messages + [.progress("\n")]
        case "result":
            terminal = true
            if value["is_error"] as? Bool == true || value["subtype"] as? String != "success" {
                return [.terminalError("Claude reported a terminal failure.")]
            }
            guard validatedInventory else { throw ScriptError.invalid("Claude did not disclose a confined tool inventory.") }
            return [.final(value["result"] as? String ?? "")]
        case "error": terminal = true; return [.terminalError("Claude reported an error.")]
        default: return []
        }
    }

    private mutating func codex(_ type: String, _ value: [String: Any]) throws -> [BuilderAgentMessage] {
        switch type {
        case "item.started", "item.updated", "item.completed":
            let item = value["item"] as? [String: Any] ?? [:]
            switch item["type"] as? String {
            case "agent_message":
                providerText = item["text"] as? String ?? ""
                guard providerText.utf8.count <= maximumLineBytes else { throw ScriptError.invalid("Final response exceeds limit.") }
                return [.progress(providerText)]
            case "mcp_tool_call":
                guard item["server"] as? String == "clipbuilder" else { throw ScriptError.invalid("Unrelated MCP server observed.") }
                return [try observed("mcp__clipbuilder__" + (item["tool"] as? String ?? ""))]
            case "command_execution", "file_change", "web_search": throw ScriptError.invalid("Native Codex tool observed.")
            default: return []
            }
        case "turn.completed": terminal = true; return [.final(providerText)]
        case "turn.failed", "error": terminal = true; return [.terminalError("Codex reported a terminal failure.")]
        default: return []
        }
    }

    private mutating func gemini(_ type: String, _ value: [String: Any]) throws -> [BuilderAgentMessage] {
        switch type {
        case "init": return (value["model"] as? String).map { [.model($0)] } ?? []
        case "message":
            guard value["role"] as? String == "assistant" else { return [] }
            let text = value["content"] as? String ?? ""
            guard providerText.utf8.count + text.utf8.count <= maximumLineBytes else { throw ScriptError.invalid("Final response exceeds limit.") }
            providerText += text
            return [.progress(text)]
        case "tool_use": return [try observed(value["tool_name"] as? String)]
        case "result":
            terminal = true
            return value["status"] as? String == "success" ? [.final(providerText)] : [.terminalError("Gemini reported a terminal failure.")]
        case "error": terminal = true; return [.terminalError("Gemini reported an error.")]
        default: return []
        }
    }

    private func observed(_ name: String?) throws -> BuilderAgentMessage {
        guard provider != .claude || validatedInventory else { throw ScriptError.invalid("Tool event preceded Claude's confined inventory.") }
        guard let name, Self.allowedTool(name) else { throw ScriptError.invalid("Agent attempted an unconfined tool.") }
        return .toolObserved(name)
    }
    private static func allowedTool(_ name: String) -> Bool {
        // Every tool the endpoint can ever advertise, in edit, find or author mode.
        ["query", "run_script", "get_document_summary", "report_scenes", "script_reference", "submit_script",
         "ensure_transcript", "ensure_people", "ensure_analysis"]
            .contains { name == "mcp__clipbuilder__" + $0 }
    }
}

/// ProcessRunner calls this synchronously on its single reader. The lock also
/// protects finish(), called after the process has drained, from test callers.
nonisolated final class BuilderAgentStream: @unchecked Sendable {
    private let lock = NSLock()
    private var parser: BuilderAgentParser
    let continuation: AsyncThrowingStream<BuilderAgentMessage, any Error>.Continuation
    init(provider: BuilderAgentProvider, continuation: AsyncThrowingStream<BuilderAgentMessage, any Error>.Continuation) {
        parser = BuilderAgentParser(provider: provider); self.continuation = continuation
    }
    func consume(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        try yield(parser.feed(data))
    }
    func finish() throws {
        lock.lock(); defer { lock.unlock() }
        try yield(parser.finish())
        continuation.finish()
    }
    private func yield(_ messages: [BuilderAgentMessage]) throws {
        for message in messages {
            switch continuation.yield(message) {
            case .enqueued, .dropped: break
            case .terminated: throw ScriptError.invalid("Agent event consumer stopped.")
            @unknown default: break
            }
        }
    }
}
