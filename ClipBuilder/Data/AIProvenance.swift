import Foundation

/// Who produced a piece of AI output: the provider that actually answered
/// (after any failover), the model it ran, the task it was doing, and when.
/// Stored next to every AI-made artifact — transcripts, scene batches,
/// curation picks, reel plans, critiques — and rendered by ProvenanceBadge
/// so the model behind any result is one hover away.
nonisolated struct AIProvenance: Codable, Sendable, Hashable {
    /// Provider key: an AICatalog key ("claude", "gemini", …) or "apple" for
    /// on-device Speech/Vision passes.
    var provider: String
    /// Raw model id ("claude-haiku-4-5-20251001"); nil when the provider's
    /// default ran and wasn't recorded.
    var model: String?
    /// AICatalog task key ("analysis", "curate", …) when known.
    var task: String?
    /// When the output was produced, when known.
    var at: Date?
    /// The dispatcher failed over from the configured choice to this one.
    var fellBack: Bool = false

    init(provider: String, model: String? = nil, task: String? = nil,
         at: Date? = nil, fellBack: Bool = false) {
        self.provider = provider
        self.model = model
        self.task = task
        self.at = at
        self.fellBack = fellBack
    }

    /// Nil when nothing was recorded (a pre-provenance row, or a human act).
    init?(provider: String?, model: String?, task: String? = nil,
          at: Date? = nil, fellBack: Bool = false) {
        guard let provider, !provider.isEmpty else { return nil }
        self.init(provider: provider, model: model, task: task, at: at, fellBack: fellBack)
    }

    /// Same as above, for rows that stamp SQLite's `datetime('now')` text.
    init?(provider: String?, model: String?, task: String? = nil, sqliteDate: String?) {
        self.init(provider: provider, model: model, task: task, at: Self.parseDate(sqliteDate))
    }

    // MARK: - Local (non-LLM) engines

    static let appleProvider = "apple"
    static let speechModel = "SpeechTranscriber"
    static let visionModel = "Vision"

    /// On-device Apple SpeechAnalyzer/SpeechTranscriber.
    static func appleSpeech(at: Date? = nil) -> AIProvenance {
        AIProvenance(provider: appleProvider, model: speechModel, task: "transcribe", at: at)
    }

    /// On-device Apple Vision (people boxes, Center Stage tracking).
    static func appleVision(task: String, at: Date? = nil) -> AIProvenance {
        AIProvenance(provider: appleProvider, model: visionModel, task: task, at: at)
    }

    // MARK: - Display

    var brand: AIProviderBrand { AIProviderBrand.brand(for: provider) }

    /// "Haiku 4.5", "SpeechTranscriber", "Vision" — never a raw id when a
    /// friendly name exists.
    var modelDisplayName: String? {
        guard let model, !model.isEmpty else { return nil }
        return AICatalog.modelDisplayName(model)
    }

    /// "Claude · Haiku 4.5" — the badge's inline text.
    var shortLabel: String {
        if let modelDisplayName {
            // Apple's engine names already read as products; brand-prefixed
            // model names (Gemini 2.5 Pro) don't need the brand twice.
            if modelDisplayName.lowercased().hasPrefix(brand.label.lowercased()) {
                return modelDisplayName
            }
            return "\(brand.label) · \(modelDisplayName)"
        }
        return brand.label
    }

    /// Task label from the catalog, with names for the local passes.
    var taskLabel: String? {
        guard let task else { return nil }
        switch task {
        case "transcribe": return "Transcription"
        case "people": return "People detection"
        case "framing": return "Framing (Center Stage)"
        default: return AICatalog.taskLabels[task] ?? task
        }
    }

    /// Multi-line hover text: engine, task, time, fallback note.
    func tooltip(role: String? = nil) -> String {
        var lines: [String] = []
        lines.append("\(role ?? "AI"): \(shortLabel)")
        if brand.vendor != brand.label { lines.append("Vendor: \(brand.vendor)") }
        if let model, model != modelDisplayName { lines.append("Model id: \(model)") }
        if let taskLabel { lines.append("Task: \(taskLabel)") }
        if let at { lines.append("When: \(Self.dateFormatter.string(from: at))") }
        if fellBack { lines.append("Ran as a fallback — the configured provider failed") }
        return lines.joined(separator: "\n")
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// SQLite `datetime('now')` ("2026-08-28 14:02:11", UTC) or ISO 8601.
    static func parseDate(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)
    }
}

/// How a provider is drawn: its product name, vendor, logo asset, and tint.
/// Logos are template images from the asset catalog (ProviderLogos), so
/// they follow the tint and stay crisp at any size.
nonisolated struct AIProviderBrand: Sendable, Hashable {
    var key: String
    /// Product name shown in badges ("Claude", "Gemini").
    var label: String
    /// Company behind it ("Anthropic", "Google").
    var vendor: String
    /// Asset-catalog image name; nil falls back to an SF Symbol.
    var logoAsset: String?
    /// Brand tint as #RRGGBB; nil = the label color (black-on-light marks
    /// like OpenAI's and Apple's stay legible in dark mode that way).
    var tintHex: String?

    static let brands: [AIProviderBrand] = [
        AIProviderBrand(key: "claude", label: "Claude", vendor: "Anthropic",
                        logoAsset: "logo-anthropic", tintHex: "#D97757"),
        AIProviderBrand(key: "gemini", label: "Gemini", vendor: "Google",
                        logoAsset: "logo-gemini", tintHex: "#4285F4"),
        AIProviderBrand(key: "codex", label: "Codex", vendor: "OpenAI",
                        logoAsset: "logo-openai", tintHex: nil),
        AIProviderBrand(key: "qwen", label: "Qwen", vendor: "Alibaba Cloud",
                        logoAsset: "logo-qwen", tintHex: "#615CED"),
        AIProviderBrand(key: "kimi", label: "Kimi", vendor: "Moonshot AI",
                        logoAsset: "logo-moonshot", tintHex: nil),
        AIProviderBrand(key: "apple", label: "Apple", vendor: "Apple",
                        logoAsset: "logo-apple", tintHex: nil),
    ]

    static func brand(for key: String) -> AIProviderBrand {
        let lowered = key.lowercased()
        if let match = brands.first(where: { $0.key == lowered }) { return match }
        // Legacy transcription setting and any unknown key.
        if lowered == "whisper" { return brand(for: "apple") }
        return AIProviderBrand(key: lowered,
                               label: AICatalog.provider(lowered)?.label ?? key,
                               vendor: AICatalog.provider(lowered)?.label ?? key,
                               logoAsset: nil, tintHex: nil)
    }
}

/// An AI reply together with who produced it — what AIService.call returns
/// so every caller can stamp the provider/model that actually answered.
nonisolated struct AIResponse: Sendable {
    var text: String
    var provider: String
    var model: String?
    var task: String
    var fellBack: Bool

    var provenance: AIProvenance {
        AIProvenance(provider: provider, model: model, task: task, at: Date(), fellBack: fellBack)
    }
}

/// A result paired with the provenance of the call that produced it — for
/// report-only features (duplicates, content gaps, search) whose output
/// isn't persisted but should still show its model.
nonisolated struct AIOutcome<Value: Sendable>: Sendable {
    var value: Value
    var provenance: AIProvenance
}
