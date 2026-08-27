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
    var instagram: InstagramSettings = InstagramSettings()
    var transitions: TransitionSettings = TransitionSettings()

    enum CodingKeys: String, CodingKey {
        case analysisMode = "analysis_mode"
        case transcribeProvider = "transcribe_provider"
        case transcribeModel = "transcribe_model"
        case transcribeHint = "transcribe_hint"
        case transcribeLanguage = "whisper_language"
        case theme
        case ai
        case instagram
        case transitions
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
        instagram = try container.decodeIfPresent(InstagramSettings.self, forKey: .instagram) ?? InstagramSettings()
        transitions = try container.decodeIfPresent(TransitionSettings.self, forKey: .transitions)
            ?? TransitionSettings()
    }
}

/// Transition rendering knobs. `xfadeDuration` replaces the render engine's
/// old hardcoded 0.5s crossfade — action edits live at 0.1-0.3s. Flash cuts
/// and action recipe bridges carry their own fixed timings.
nonisolated struct TransitionSettings: Codable, Sendable {
    /// Seconds a regular crossfade (xfade) overlaps — 0.1 (snappy) to 1.0.
    var xfadeDuration: Double = 0.35
    /// Mix synthesized whoosh/impact/slash sounds under action transitions.
    var sfxEnabled: Bool = true
    /// Snap wizard cut boundaries to detected music beats after planning.
    var beatSnap: Bool = true

    enum CodingKeys: String, CodingKey {
        case xfadeDuration = "xfade_duration"
        case sfxEnabled = "sfx_enabled"
        case beatSnap = "beat_snap"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        xfadeDuration = try container.decodeIfPresent(Double.self, forKey: .xfadeDuration) ?? 0.35
        xfadeDuration = min(1.0, max(0.1, xfadeDuration))
        sfxEnabled = try container.decodeIfPresent(Bool.self, forKey: .sfxEnabled) ?? true
        beatSnap = try container.decodeIfPresent(Bool.self, forKey: .beatSnap) ?? true
    }
}

/// Instagram integration settings — app-level (browser cookies and Meta app
/// credentials are per-machine, not per-brand-profile). The Meta app SECRET
/// and OAuth tokens never live here: app_settings.json is plaintext and
/// shared with the Python app; secrets go to the Keychain (Phase 4).
nonisolated struct InstagramSettings: Codable, Sendable {
    var metaAppID: String = ""
    var redirectURI: String = ""
    var cookieSource: String = "none"     // none | safari | chrome | firefox | file
    var cookieFilePath: String = ""
    var fetchLimit: Int = 12
    var connectedUsername: String = ""    // Graph API account, set on Connect
    var connectedIGUserID: String = ""    // its IG user id — skips discovery

    var isGraphConnected: Bool { !connectedUsername.isEmpty }

    enum CodingKeys: String, CodingKey {
        case metaAppID = "meta_app_id"
        case redirectURI = "redirect_uri"
        case cookieSource = "cookie_source"
        case cookieFilePath = "cookie_file_path"
        case fetchLimit = "fetch_limit"
        case connectedUsername = "connected_username"
        case connectedIGUserID = "connected_ig_user_id"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metaAppID = try container.decodeIfPresent(String.self, forKey: .metaAppID) ?? ""
        redirectURI = try container.decodeIfPresent(String.self, forKey: .redirectURI) ?? ""
        cookieSource = try container.decodeIfPresent(String.self, forKey: .cookieSource) ?? "none"
        cookieFilePath = try container.decodeIfPresent(String.self, forKey: .cookieFilePath) ?? ""
        fetchLimit = try container.decodeIfPresent(Int.self, forKey: .fetchLimit) ?? 12
        connectedUsername = try container.decodeIfPresent(String.self, forKey: .connectedUsername) ?? ""
        connectedIGUserID = try container.decodeIfPresent(String.self, forKey: .connectedIGUserID) ?? ""
    }
}

/// AI routing config: which provider handles each task, plus per-provider
/// binary path / default model overrides. Same shape as the "ai" block in
/// the Python app's settings.
nonisolated struct AIConfig: Codable, Sendable {
    var tasks: [String: String] = [:]                      // task → provider key
    /// task → model, so two tasks on the same provider can use different
    /// models (planning on Sonnet while parsing runs on Haiku).
    var taskModels: [String: String] = [:]
    var providers: [String: AIProviderSettings] = [:]      // provider key → overrides
    /// Dispatch-plan prompts the user muted with "remember my choices"
    /// ("analyze", "generate"). Reset from Settings → AI.
    var mutedDispatchPlans: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try container.decodeIfPresent([String: String].self, forKey: .tasks) ?? [:]
        taskModels = try container.decodeIfPresent([String: String].self, forKey: .taskModels) ?? [:]
        providers = try container.decodeIfPresent([String: AIProviderSettings].self, forKey: .providers) ?? [:]
        mutedDispatchPlans = try container.decodeIfPresent([String].self, forKey: .mutedDispatchPlans) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case tasks, providers
        case taskModels = "task_models"
        case mutedDispatchPlans = "muted_dispatch_plans"
    }
}

nonisolated struct AIProviderSettings: Codable, Sendable {
    var bin: String?
    var model: String?
}

/// Static provider/task metadata ported from ai_cli.py.
nonisolated enum AICatalog {
    // "wizard" stays the planning task's key for config back-compat.
    static let tasks = ["analysis", "wizard", "critique", "research", "fight_research", "parse", "captions", "distill", "overlay"]

    static let taskLabels: [String: String] = [
        "analysis": "Video analysis",
        "wizard": "Reel planning",
        "critique": "Reel critique",
        "research": "Reels research",
        "fight_research": "Fight research",
        "parse": "Request parsing",
        "captions": "Caption generation",
        "distill": "Lesson distillation",
        "overlay": "Overlay extraction",
    ]

    static let taskDefaults: [String: String] = [
        "analysis": "claude",
        "wizard": "claude",
        "critique": "claude",
        "research": "claude",
        "fight_research": "claude",
        "parse": "claude",
        "captions": "claude",
        "distill": "claude",
        "overlay": "claude",
    ]

    /// The smart dispatcher's curated preference chains: best first, each a
    /// concrete (provider, model). The dispatcher walks a chain skipping
    /// providers whose CLI isn't installed; the same order drives mid-run
    /// failover when a provider errors out.
    static let recommendedChains: [String: [(provider: String, model: String)]] = [
        // Frame tagging: multimodal + cheap matters most — 30 images/video.
        "analysis": [("gemini", "gemini-2.5-flash"),
                     ("claude", "claude-sonnet-4-6"),
                     ("claude", "claude-haiku-4-5-20251001")],
        // Planning is the run's brain: strongest reasoning first — Fable at
        // maximum thinking (AIService raises the thinking budget for it).
        "wizard": [("claude", "claude-fable-5"),
                   ("claude", "claude-sonnet-4-6"),
                   ("gemini", "gemini-2.5-pro"),
                   ("codex", "gpt-5"),
                   ("kimi", "kimi-code/kimi-for-coding"),
                   ("qwen", "qwen3-coder-plus")],
        // Post-render critique: a multimodal judge that watches the rendered
        // frames. Deliberately leads with a DIFFERENT model than planning so
        // the planner isn't grading its own work.
        "critique": [("claude", "claude-sonnet-4-6"),
                     ("gemini", "gemini-2.5-pro"),
                     ("claude", "claude-fable-5")],
        "research": [("claude", "claude-sonnet-4-6"),
                     ("gemini", "gemini-2.5-flash"),
                     ("codex", "gpt-5-mini"),
                     ("qwen", "qwen3-coder-flash"),
                     ("kimi", "kimi-code/kimi-for-coding")],
        // Fight research: turns crawled fan chatter into the reel's story —
        // strong summarization matters more than speed.
        "fight_research": [("claude", "claude-sonnet-4-6"),
                           ("gemini", "gemini-2.5-pro"),
                           ("codex", "gpt-5"),
                           ("qwen", "qwen3-coder-plus"),
                           ("kimi", "kimi-code/kimi-for-coding")],
        // Structured extraction: fast + cheap is plenty.
        "parse": [("claude", "claude-haiku-4-5-20251001"),
                  ("gemini", "gemini-2.5-flash"),
                  ("codex", "gpt-5-mini"),
                  ("qwen", "qwen3-coder-flash"),
                  ("kimi", "kimi-code/kimi-for-coding")],
        "captions": [("claude", "claude-haiku-4-5-20251001"),
                     ("gemini", "gemini-2.5-flash"),
                     ("codex", "gpt-5-mini"),
                     ("qwen", "qwen3-coder-flash"),
                     ("kimi", "kimi-code/kimi-for-coding")],
        "distill": [("claude", "claude-fable-5"),
                    ("claude", "claude-sonnet-4-6"),
                    ("gemini", "gemini-2.5-pro"),
                    ("codex", "gpt-5"),
                    ("kimi", "kimi-code/kimi-for-coding"),
                    ("qwen", "qwen3-coder-plus")],
        // Reading overlay layout from one image: multimodal, precision over
        // speed — a stronger model gets positions and colors right.
        "overlay": [("claude", "claude-sonnet-4-6"),
                    ("gemini", "gemini-2.5-pro"),
                    ("gemini", "gemini-2.5-flash")],
    ]

    struct Provider: Sendable {
        var key: String
        var label: String
        var bin: String
        var defaultModel: String
        var supportsImages: Bool
        var models: [String]
    }

    /// Friendly display names so raw model IDs never reach the UI.
    static let modelDisplayNames: [String: String] = [
        "claude-haiku-4-5-20251001": "Haiku 4.5",
        "claude-sonnet-4-6": "Sonnet 4.6",
        "claude-opus-4-8": "Opus 4.8",
        "claude-fable-5": "Fable 5",
        "gemini-2.5-flash-lite": "Gemini 2.5 Flash Lite",
        "gemini-2.5-flash": "Gemini 2.5 Flash",
        "gemini-2.0-flash": "Gemini 2.0 Flash",
        "gemini-2.5-pro": "Gemini 2.5 Pro",
        "gpt-5-nano": "GPT-5 nano",
        "gpt-5-mini": "GPT-5 mini",
        "gpt-5-codex": "GPT-5 Codex",
        "gpt-5": "GPT-5",
        "o3-mini": "o3-mini",
        "o3": "o3",
        "qwen3-coder-flash": "Qwen3 Coder Flash",
        "qwen3-coder-plus": "Qwen3 Coder Plus",
        "kimi-code/kimi-for-coding": "Kimi for Coding",
    ]

    static func modelDisplayName(_ model: String) -> String {
        modelDisplayNames[model] ?? model
    }

    static let providers: [Provider] = [
        Provider(key: "claude", label: "Claude Code", bin: "claude",
                 defaultModel: "claude-haiku-4-5-20251001", supportsImages: true,
                 models: ["claude-haiku-4-5-20251001", "claude-sonnet-4-6", "claude-opus-4-8",
                          "claude-fable-5"]),
        Provider(key: "gemini", label: "Gemini CLI", bin: "gemini",
                 defaultModel: "gemini-2.5-flash", supportsImages: true,
                 models: ["gemini-2.5-flash-lite", "gemini-2.5-flash", "gemini-2.0-flash", "gemini-2.5-pro"]),
        Provider(key: "codex", label: "Codex CLI", bin: "codex",
                 defaultModel: "gpt-5-mini", supportsImages: false,
                 models: ["gpt-5-nano", "gpt-5-mini", "o3-mini", "gpt-5-codex", "o3", "gpt-5"]),
        Provider(key: "qwen", label: "Qwen Code", bin: "qwen",
                 defaultModel: "qwen3-coder-plus", supportsImages: false,
                 models: ["qwen3-coder-flash", "qwen3-coder-plus"]),
        Provider(key: "kimi", label: "Kimi Code CLI", bin: "kimi",
                 defaultModel: "kimi-code/kimi-for-coding", supportsImages: false,
                 models: ["kimi-code/kimi-for-coding"]),
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

    /// Saved taste-exemplar frames: taste/<profile>/exemplar-*.jpg.
    static func tasteFramesDirectory(profileName: String) -> URL {
        dataDirectory.appendingPathComponent("taste/\(ProfileStore.sanitize(profileName))",
                                             isDirectory: true)
    }

    /// Per-account Instagram cache: thumbs/<media_id>.jpg, videos/<media_id>.mp4.
    static func instagramCacheDirectory(username: String) -> URL {
        cacheDirectory.appendingPathComponent("instagram/\(ProfileStore.sanitize(username))", isDirectory: true)
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
