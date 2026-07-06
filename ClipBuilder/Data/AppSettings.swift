import Foundation

/// App-level (profile-independent) settings — mirrors data/app_settings.json
/// from the Python app: analysis mode, transcription provider, AI routing.
nonisolated struct AppSettings: Codable, Sendable {
    var analysisMode: String = "visual"          // visual | speech
    var transcribeProvider: String = "apple"     // apple (SpeechAnalyzer) — cloud providers can be added later
    var transcribeModel: String = ""
    var transcribeHint: String = ""
    var transcribeLanguage: String = ""          // empty = auto/current locale
    var theme: String = "default"
    var ai: AIConfig = AIConfig()

    enum CodingKeys: String, CodingKey {
        case analysisMode = "analysis_mode"
        case transcribeProvider = "transcribe_provider"
        case transcribeModel = "transcribe_model"
        case transcribeHint = "transcribe_hint"
        case transcribeLanguage = "whisper_language"
        case theme
        case ai
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        analysisMode = try container.decodeIfPresent(String.self, forKey: .analysisMode) ?? "visual"
        let provider = try container.decodeIfPresent(String.self, forKey: .transcribeProvider) ?? "apple"
        // Python's local provider is faster-whisper; this app transcribes with
        // Apple SpeechAnalyzer instead.
        transcribeProvider = provider == "whisper" ? "apple" : provider
        transcribeModel = try container.decodeIfPresent(String.self, forKey: .transcribeModel) ?? ""
        transcribeHint = try container.decodeIfPresent(String.self, forKey: .transcribeHint) ?? ""
        transcribeLanguage = try container.decodeIfPresent(String.self, forKey: .transcribeLanguage) ?? ""
        theme = try container.decodeIfPresent(String.self, forKey: .theme) ?? "default"
        ai = try container.decodeIfPresent(AIConfig.self, forKey: .ai) ?? AIConfig()
    }
}

/// AI routing config: which provider handles each task, plus per-provider
/// binary path / default model overrides. Same shape as the "ai" block in
/// the Python app's settings.
nonisolated struct AIConfig: Codable, Sendable {
    var tasks: [String: String] = [:]                      // task → provider key
    var providers: [String: AIProviderSettings] = [:]      // provider key → overrides

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try container.decodeIfPresent([String: String].self, forKey: .tasks) ?? [:]
        providers = try container.decodeIfPresent([String: AIProviderSettings].self, forKey: .providers) ?? [:]
    }

    enum CodingKeys: String, CodingKey { case tasks, providers }
}

nonisolated struct AIProviderSettings: Codable, Sendable {
    var bin: String?
    var model: String?
}

/// Static provider/task metadata ported from ai_cli.py.
nonisolated enum AICatalog {
    static let tasks = ["analysis", "wizard", "captions"]

    static let taskLabels: [String: String] = [
        "analysis": "Video analysis",
        "wizard": "Wizard reasoning",
        "captions": "Caption generation",
    ]

    static let taskDefaults: [String: String] = [
        "analysis": "claude",
        "wizard": "claude",
        "captions": "claude",
    ]

    struct Provider: Sendable {
        var key: String
        var label: String
        var bin: String
        var defaultModel: String
        var supportsImages: Bool
        var models: [String]
    }

    static let providers: [Provider] = [
        Provider(key: "claude", label: "Claude Code", bin: "claude",
                 defaultModel: "claude-haiku-4-5-20251001", supportsImages: true,
                 models: ["claude-haiku-4-5-20251001", "claude-sonnet-4-6", "claude-opus-4-8"]),
        Provider(key: "gemini", label: "Gemini CLI", bin: "gemini",
                 defaultModel: "gemini-2.5-flash", supportsImages: true,
                 models: ["gemini-2.5-flash-lite", "gemini-2.5-flash", "gemini-2.0-flash", "gemini-2.5-pro"]),
        Provider(key: "codex", label: "Codex CLI", bin: "codex",
                 defaultModel: "gpt-5-mini", supportsImages: false,
                 models: ["gpt-5-nano", "gpt-5-mini", "o3-mini", "gpt-5-codex", "o3", "gpt-5"]),
    ]

    static func provider(_ key: String) -> Provider? {
        providers.first { $0.key == key }
    }
}

/// Persists app settings + active profile name under the data folder.
/// Default data folder is `~/Documents/ClipBuilder/data`; point it at a
/// clip-builder checkout's `data/` folder to share databases with the
/// Python app.
nonisolated enum SettingsStore {
    static let dataFolderDefaultsKey = "ClipBuilderDataFolder"

    static var dataDirectory: URL {
        if let custom = UserDefaults.standard.string(forKey: dataFolderDefaultsKey), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return ProfileStore.profilesDirectory.appendingPathComponent("data", isDirectory: true)
    }

    static var settingsURL: URL { dataDirectory.appendingPathComponent("app_settings.json") }
    static var activeProfileURL: URL { dataDirectory.appendingPathComponent("active_profile.json") }
    static var profilesDBDirectory: URL { dataDirectory.appendingPathComponent("profiles_db", isDirectory: true) }
    static var cacheDirectory: URL { dataDirectory.appendingPathComponent(".cache", isDirectory: true) }

    static func databaseURL(profileName: String) -> URL {
        profilesDBDirectory.appendingPathComponent(ProfileStore.sanitize(profileName) + ".db")
    }

    static func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    static func save(_ settings: AppSettings) {
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(settings) {
            try? data.write(to: settingsURL)
        }
    }

    static func loadActiveProfileName() -> String? {
        guard let data = try? Data(contentsOf: activeProfileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["name"] as? String
    }

    static func saveActiveProfileName(_ name: String) {
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: ["name": name]) {
            try? data.write(to: activeProfileURL)
        }
    }
}
