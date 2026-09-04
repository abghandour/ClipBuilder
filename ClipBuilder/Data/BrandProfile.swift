import Foundation

/// One learned video type: what a keeper moment looks like for THIS kind of
/// reel (fight highlights, interviews, …), distilled from studied exemplars.
/// Categories emerge from studying — the model classifies each reel and
/// merges its learnings into the matching category.
nonisolated struct TasteCategory: Codable, Sendable, Hashable, Identifiable {
    var key: String
    var label: String
    var rubric: String
    /// Saved exemplar frame paths for this category.
    var exemplarFrames: [String]
    var studiedCount: Int

    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, label, rubric
        case exemplarFrames = "exemplar_frames"
        case studiedCount = "studied_count"
    }

    init(key: String, label: String, rubric: String = "",
         exemplarFrames: [String] = [], studiedCount: Int = 0) {
        self.key = key
        self.label = label
        self.rubric = rubric
        self.exemplarFrames = exemplarFrames
        self.studiedCount = studiedCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decodeIfPresent(String.self, forKey: .key) ?? "general"
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? key
        rubric = try container.decodeIfPresent(String.self, forKey: .rubric) ?? ""
        exemplarFrames = try container.decodeIfPresent([String].self, forKey: .exemplarFrames) ?? []
        studiedCount = try container.decodeIfPresent(Int.self, forKey: .studiedCount) ?? 0
    }
}

/// Brand profile — mirrors the JSON files the Python app keeps at
/// `~/Documents/ClipBuilder/<name>.json` so both apps can share profiles.
nonisolated struct BrandProfile: Codable, Sendable, Hashable, Identifiable {
    var profileName: String
    var brandName: String
    var contentDomain: String
    var sourceFolder: String
    var outputFolder: String
    var tagSchema: [String: [String]]
    var socials: [String: SocialSlot]
    var captions: CaptionStyle
    // Brand kit — drives the wizard's watermark, headline, and outro card.
    /// Absolute path to the brand logo image ("" = no logo features).
    var logoPath: String
    /// #hex accent used by branded overlays ("" = default yellow).
    var accentColor: String
    /// Short motto rendered under the logo on the outro card.
    var tagline: String
    /// Caption languages, e.g. ["en", "pt"] — one caption block per language.
    var captionLanguages: [String]
    /// Editable "what a keeper moment looks like" rules, distilled from
    /// exemplar reels the user picked; injected into analysis and planning.
    var tasteRubric: String
    /// Saved frames from exemplar reels (absolute JPEG paths) — attached to
    /// analysis calls as visual definitions of the rubric.
    var tasteExemplarFrames: [String]
    /// Learned video types, each with its own rubric and exemplars.
    var tasteCategories: [TasteCategory]
    /// House style distilled across EVERY analyzed Instagram reel (weighted
    /// by performance): typical hook types, duration band, cut cadence,
    /// structure, and overlay usage. Injected into every wizard plan.
    var houseStyle: String
    /// Fight-research sources the crawler fetches for fan reactions (known
    /// keys: "reddit", "sherdog" — only sources reachable with plain HTTP,
    /// no logins; X/Instagram are login-walled and not offered).
    var buzzSources: [String]
    /// Freeform extra sources — subreddits ("r/ufc") crawl via Reddit's API,
    /// domains ("mmamania.com") via site-scoped search, URLs fetch directly.
    var buzzExtraSources: String
    /// The model that wrote the taste rubric (profile starter); nil when
    /// hand-written or predating provenance.
    var tasteRubricProvenance: AIProvenance?
    /// The model that distilled the house style.
    var houseStyleProvenance: AIProvenance?

    static let knownBuzzSources: [(key: String, label: String)] = [
        ("reddit", "Reddit (r/MMA and other MMA subreddits)"),
        ("news", "News coverage (Google News)"),
        ("sherdog", "Sherdog forums"),
    ]

    var id: String { profileName }

    enum CodingKeys: String, CodingKey {
        case profileName = "profile_name"
        case brandName = "brand_name"
        case contentDomain = "content_domain"
        case sourceFolder = "source_folder"
        case outputFolder = "output_folder"
        case tagSchema = "tag_schema"
        case socials
        case captions
        case logoPath = "logo_path"
        case accentColor = "accent_color"
        case tagline
        case captionLanguages = "caption_languages"
        case tasteRubric = "taste_rubric"
        case tasteExemplarFrames = "taste_exemplar_frames"
        case tasteCategories = "taste_categories"
        case houseStyle = "house_style"
        case buzzSources = "buzz_sources"
        case buzzExtraSources = "buzz_extra_sources"
        case tasteRubricProvenance = "taste_rubric_provenance"
        case houseStyleProvenance = "house_style_provenance"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileName = try container.decodeIfPresent(String.self, forKey: .profileName) ?? "Default"
        brandName = try container.decodeIfPresent(String.self, forKey: .brandName) ?? profileName
        contentDomain = try container.decodeIfPresent(String.self, forKey: .contentDomain) ?? ""
        sourceFolder = try container.decodeIfPresent(String.self, forKey: .sourceFolder)
            ?? "~/Documents/ClipBuilder/\(profileName)/Input"
        outputFolder = try container.decodeIfPresent(String.self, forKey: .outputFolder)
            ?? "~/Documents/ClipBuilder/\(profileName)/Output"
        tagSchema = try container.decodeIfPresent([String: [String]].self, forKey: .tagSchema) ?? [:]
        socials = try container.decodeIfPresent([String: SocialSlot].self, forKey: .socials) ?? [:]
        captions = try container.decodeIfPresent(CaptionStyle.self, forKey: .captions) ?? CaptionStyle()
        logoPath = try container.decodeIfPresent(String.self, forKey: .logoPath) ?? ""
        accentColor = try container.decodeIfPresent(String.self, forKey: .accentColor) ?? ""
        tagline = try container.decodeIfPresent(String.self, forKey: .tagline) ?? ""
        captionLanguages = try container.decodeIfPresent([String].self, forKey: .captionLanguages) ?? ["en"]
        tasteRubric = try container.decodeIfPresent(String.self, forKey: .tasteRubric) ?? ""
        tasteExemplarFrames = try container.decodeIfPresent([String].self, forKey: .tasteExemplarFrames) ?? []
        tasteCategories = try container.decodeIfPresent([TasteCategory].self, forKey: .tasteCategories) ?? []
        houseStyle = try container.decodeIfPresent(String.self, forKey: .houseStyle) ?? ""
        var storedSources = try container.decodeIfPresent([String].self, forKey: .buzzSources)
            ?? Self.knownBuzzSources.map(\.key)
        // Lists saved before the news source existed carried the (never
        // crawlable) x/instagram keys — swap them for news.
        if storedSources.contains("x") || storedSources.contains("instagram") {
            storedSources.removeAll { $0 == "x" || $0 == "instagram" }
            if !storedSources.contains("news") { storedSources.append("news") }
        }
        buzzSources = storedSources
        buzzExtraSources = try container.decodeIfPresent(String.self, forKey: .buzzExtraSources) ?? ""
        tasteRubricProvenance = try container.decodeIfPresent(AIProvenance.self, forKey: .tasteRubricProvenance)
        houseStyleProvenance = try container.decodeIfPresent(AIProvenance.self, forKey: .houseStyleProvenance)
    }

    init(name: String) {
        profileName = name
        brandName = name
        contentDomain = ""
        if let custom = UserDefaults.standard.string(forKey: SettingsStore.dataFolderDefaultsKey),
           !custom.isEmpty {
            let root = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
                .deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
            sourceFolder = root.appendingPathComponent("Input", isDirectory: true).path
            outputFolder = root.appendingPathComponent("Output", isDirectory: true).path
        } else {
            sourceFolder = "~/Documents/ClipBuilder/\(name)/Input"
            outputFolder = "~/Documents/ClipBuilder/\(name)/Output"
        }
        tagSchema = [:]
        socials = ["instagram": SocialSlot(), "tiktok": SocialSlot(), "youtube": SocialSlot()]
        captions = CaptionStyle()
        logoPath = ""
        accentColor = ""
        tagline = ""
        captionLanguages = ["en"]
        tasteRubric = ""
        tasteExemplarFrames = []
        tasteCategories = []
        houseStyle = ""
        buzzSources = Self.knownBuzzSources.map(\.key)
        buzzExtraSources = ""
        tasteRubricProvenance = nil
        houseStyleProvenance = nil
    }

    var logoURL: URL? {
        logoPath.isEmpty ? nil : URL(fileURLWithPath: (logoPath as NSString).expandingTildeInPath)
    }

    var sourceFolderURL: URL { URL(fileURLWithPath: (sourceFolder as NSString).expandingTildeInPath) }
    var outputFolderURL: URL { URL(fileURLWithPath: (outputFolder as NSString).expandingTildeInPath) }

    /// The analyzer tag vocabulary: profile schema if set, else built-in defaults.
    var effectiveTags: [String: [String]] {
        tagSchema.values.contains(where: { !$0.isEmpty }) ? tagSchema : Self.defaultTags
    }

    /// Domain string used in AI prompts ("MMA", "cooking", ...).
    var effectiveDomain: String {
        contentDomain.isEmpty ? "general" : contentDomain
    }

    /// Default tag schema ported from app_config.DEFAULT_TAGS (MMA-oriented).
    static let defaultTags: [String: [String]] = [
        "activity": [
            "grappling", "striking", "punching", "kicking", "takedown", "submission",
            "ground-and-pound", "clinch", "sprawl", "guard-pass", "sweep", "mount",
            "back-control", "arm-bar", "choke", "triangle", "knee-bar", "leg-lock",
            "wrestling", "judo-throw", "elbow", "knee-strike",
            "training", "sparring", "drilling", "pad-work", "bag-work", "warm-up",
            "stretching", "conditioning", "weightlifting", "running",
            "interview", "press-conference", "weigh-in", "face-off",
            "walkout", "entrance", "celebration", "corner-advice",
            "crowd", "audience-reaction", "referee", "judges",
            "promo", "graphic", "text-overlay", "logo", "intro", "outro",
            "behind-the-scenes", "travel", "eating", "lifestyle",
            "slow-motion", "replay", "highlight-reel", "talking", "posing", "photo",
        ],
        "setting": [
            "octagon", "cage", "ring", "gym", "outdoor", "beach", "street", "hotel",
            "arena", "backstage", "locker-room", "studio",
        ],
        "camera": [
            "close-up", "medium-shot", "wide-shot", "overhead", "pov", "handheld",
            "steady", "tracking", "slow-pan",
        ],
        "energy": [
            "high-energy", "medium-energy", "low-energy",
        ],
        "quality": [
            "low-quality",
        ],
    ]
}

nonisolated struct SocialSlot: Codable, Sendable, Hashable {
    var handle: String = ""
    var url: String = ""
    var cookies: String = ""

    init(handle: String = "", url: String = "", cookies: String = "") {
        self.handle = handle
        self.url = url
        self.cookies = cookies
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        handle = try container.decodeIfPresent(String.self, forKey: .handle) ?? ""
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        cookies = try container.decodeIfPresent(String.self, forKey: .cookies) ?? ""
    }
}

/// Burn-in caption style persisted with the profile (captions key).
nonisolated struct CaptionStyle: Codable, Sendable, Hashable {
    var font: String = "sans"          // sans | serif | mono | asset font name
    var color: String = "#ffffff"
    var bgOn: Bool = false
    var bgColor: String = "#000000"
    var position: String = "bottom"    // bottom | middle | top

    enum CodingKeys: String, CodingKey {
        case font, color
        case bgOn = "bg_on"
        case bgColor = "bg_color"
        case position
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        font = try container.decodeIfPresent(String.self, forKey: .font) ?? "sans"
        color = try container.decodeIfPresent(String.self, forKey: .color) ?? "#ffffff"
        bgOn = try container.decodeIfPresent(Bool.self, forKey: .bgOn) ?? false
        bgColor = try container.decodeIfPresent(String.self, forKey: .bgColor) ?? "#000000"
        position = try container.decodeIfPresent(String.self, forKey: .position) ?? "bottom"
    }
}

/// Loads, saves, and enumerates profiles at ~/Documents/ClipBuilder/*.json.
nonisolated enum ProfileStore {
    static var profilesDirectory: URL {
        // A custom data folder represents the shared app-data directory. Its
        // parent contains profile JSON, matching the normal ClipBuilder/data
        // and ClipBuilder/*.json layout.
        if let custom = UserDefaults.standard.string(forKey: SettingsStore.dataFolderDefaultsKey),
           !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
                .deletingLastPathComponent()
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/ClipBuilder", isDirectory: true)
    }

    private static let unsafeCharacters = /[^A-Za-z0-9_\-. ]/

    static func sanitize(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let safe = trimmed.replacing(unsafeCharacters, with: "_")
        return safe.isEmpty ? "default" : safe
    }

    static func profileURL(name: String) -> URL {
        profilesDirectory.appendingPathComponent(sanitize(name) + ".json")
    }

    static func listProfiles() -> [BrandProfile] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: profilesDirectory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(BrandProfile.self, from: data)
            }
            .sorted { $0.profileName.localizedCaseInsensitiveCompare($1.profileName) == .orderedAscending }
    }

    static func load(name: String) -> BrandProfile? {
        guard let data = try? Data(contentsOf: profileURL(name: name)) else { return nil }
        return try? JSONDecoder().decode(BrandProfile.self, from: data)
    }

    static func save(_ profile: BrandProfile) throws {
        try FileManager.default.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profile).write(to: profileURL(name: profile.profileName), options: .atomic)
    }

    static func delete(name: String) throws {
        try FileManager.default.removeItem(at: profileURL(name: name))
    }

    /// Guarantee the undeletable fallback profile exists, and create its
    /// Input/Output folders so the folder watcher has something to watch.
    static func ensureDefaultProfile() -> BrandProfile {
        if let existing = load(name: "Default") {
            ensureFolders(for: existing)
            return existing
        }
        let profile = BrandProfile(name: "Default")
        try? save(profile)
        ensureFolders(for: profile)
        return profile
    }

    static func ensureFolders(for profile: BrandProfile) {
        try? FileManager.default.createDirectory(at: profile.sourceFolderURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: profile.outputFolderURL, withIntermediateDirectories: true)
    }
}
