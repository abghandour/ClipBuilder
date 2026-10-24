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
    var profileID: UUID?
    var teamID: UUID?
    var teamSyncPaused: Bool?
    var learnedSharing = LearnedSharing()
    var profileName: String
    var brandName: String
    var contentDomain: String
    var sourceFolder: String
    var outputFolder: String
    var tagSchema: [String: [String]]
    var socials: [String: SocialSlot]
    var captions: CaptionStyle
    var captionStyles: [NamedCaptionStyle]?
    /// Person key → named caption style UUID; nil entries follow the run style.
    var personCaptionStyles: [String: String]?
    var tagStyle: TagStyle?
    var tagStyles: [NamedTagStyle]?
    // Brand kit — drives the wizard's watermark, headline, and outro card.
    /// Absolute path to the brand logo image ("" = no logo features).
    var logoPath: String
    /// #hex accent used by branded overlays ("" = default yellow).
    var accentColor: String
    /// Short motto rendered under the logo on the outro card.
    var tagline: String
    /// Caption languages, e.g. ["en", "pt"] — one caption block per language.
    var hashtags: [String] = []
    var captionLanguages: [String]
    var defaultRenderSettings: RenderSettings
    var editing: ProfileEditingDefaults?
    var aiRouting: ProfileAIRouting?
    var defaultPacing: EditPacing
    /// Step 2 music mix level (1–5); old profiles retain the existing 3/5 mix.
    var defaultMusicVolume: Int?
    var useLearnedEditingDefaults: Bool
    var learnedHookStyle: String
    var learnedLayoutPreference: String
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
    /// This judge belongs to the profile; per-Mac routing overrides stay local.
    var criticBriefUse: CriticBriefUse = .automatic
    /// Last successful Instagram publish target for this profile.
    var instagramPublishAccount: String?
    /// Private Mini Wizard instructions, shared by this profile's projects.
    var miniInstructions: String?
    /// Named Express settings; part of the shared team profile document.
    var expressPresets: [MiniWizardPreset]?
    /// Named AI Wizard answers; part of the shared team profile document.
    var wizardPresets: [WizardPreset]?

    static let knownBuzzSources: [(key: String, label: String)] = [
        ("reddit", "Reddit (r/MMA and other MMA subreddits)"),
        ("news", "News coverage (Google News)"),
        ("sherdog", "Sherdog forums"),
    ]

    var id: String { profileName }

    enum CodingKeys: String, CodingKey {
        case profileID = "profile_id"
        case teamID = "team_id"
        case teamSyncPaused = "team_sync_paused"
        case learnedSharing = "learned_sharing"
        case profileName = "profile_name"
        case brandName = "brand_name"
        case contentDomain = "content_domain"
        case sourceFolder = "source_folder"
        case outputFolder = "output_folder"
        case tagSchema = "tag_schema"
        case socials
        case hashtags
        case captions
        case captionStyles = "caption_styles"
        case personCaptionStyles = "person_caption_styles"
        case tagStyle = "tag_style"
        case tagStyles = "tag_styles"
        case logoPath = "logo_path"
        case accentColor = "accent_color"
        case tagline
        case captionLanguages = "caption_languages"
        case defaultRenderSettings = "default_render_settings"
        case editing
        case aiRouting = "ai_routing"
        case defaultPacing = "default_pacing"
        case defaultMusicVolume = "default_music_volume"
        case useLearnedEditingDefaults = "use_learned_editing_defaults"
        case learnedHookStyle = "learned_hook_style"
        case learnedLayoutPreference = "learned_layout_preference"
        case tasteRubric = "taste_rubric"
        case tasteExemplarFrames = "taste_exemplar_frames"
        case tasteCategories = "taste_categories"
        case houseStyle = "house_style"
        case buzzSources = "buzz_sources"
        case buzzExtraSources = "buzz_extra_sources"
        case tasteRubricProvenance = "taste_rubric_provenance"
        case houseStyleProvenance = "house_style_provenance"
        case criticBriefUse = "critic_brief_use"
        case instagramPublishAccount = "instagram_publish_account"
        case miniInstructions = "mini_instructions"
        case expressPresets = "express_presets"
        case wizardPresets = "wizard_presets"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try container.decodeIfPresent(UUID.self, forKey: .profileID)
        teamID = try container.decodeIfPresent(UUID.self, forKey: .teamID)
        teamSyncPaused = try container.decodeIfPresent(Bool.self, forKey: .teamSyncPaused)
        learnedSharing = try container.decodeIfPresent(LearnedSharing.self, forKey: .learnedSharing) ?? LearnedSharing()
        criticBriefUse = try container.decodeIfPresent(CriticBriefUse.self, forKey: .criticBriefUse) ?? .automatic
        instagramPublishAccount = try container.decodeIfPresent(String.self, forKey: .instagramPublishAccount)
        miniInstructions = try container.decodeIfPresent(String.self, forKey: .miniInstructions)
        expressPresets = try container.decodeIfPresent([MiniWizardPreset].self, forKey: .expressPresets)
        wizardPresets = try container.decodeIfPresent([WizardPreset].self, forKey: .wizardPresets)
        profileName = try container.decodeIfPresent(String.self, forKey: .profileName) ?? "Default"
        brandName = try container.decodeIfPresent(String.self, forKey: .brandName) ?? profileName
        contentDomain = try container.decodeIfPresent(String.self, forKey: .contentDomain) ?? ""
        sourceFolder = try container.decodeIfPresent(String.self, forKey: .sourceFolder)
            ?? "~/Documents/ClipBuilder/\(profileName)/Input"
        outputFolder = try container.decodeIfPresent(String.self, forKey: .outputFolder)
            ?? "~/Documents/ClipBuilder/\(profileName)/Output"
        tagSchema = try container.decodeIfPresent([String: [String]].self, forKey: .tagSchema) ?? [:]
        socials = try container.decodeIfPresent([String: SocialSlot].self, forKey: .socials) ?? [:]
        captionStyles = try container.decodeIfPresent([NamedCaptionStyle].self, forKey: .captionStyles)
        personCaptionStyles = try container.decodeIfPresent([String: String].self, forKey: .personCaptionStyles)
        tagStyle = try container.decodeIfPresent(TagStyle.self, forKey: .tagStyle)
        tagStyles = try container.decodeIfPresent([NamedTagStyle].self, forKey: .tagStyles)
        captions = try container.decodeIfPresent(CaptionStyle.self, forKey: .captions) ?? CaptionStyle()
        logoPath = try container.decodeIfPresent(String.self, forKey: .logoPath) ?? ""
        accentColor = try container.decodeIfPresent(String.self, forKey: .accentColor) ?? ""
        tagline = try container.decodeIfPresent(String.self, forKey: .tagline) ?? ""
        hashtags = try container.decodeIfPresent([String].self, forKey: .hashtags) ?? []
        captionLanguages = try container.decodeIfPresent([String].self, forKey: .captionLanguages)
            ?? ["en"]
        defaultRenderSettings = try container.decodeIfPresent(RenderSettings.self, forKey: .defaultRenderSettings)
            ?? RenderSettings()
        editing = try container.decodeIfPresent(ProfileEditingDefaults.self, forKey: .editing)
        aiRouting = try container.decodeIfPresent(ProfileAIRouting.self, forKey: .aiRouting)
        defaultPacing = try container.decodeIfPresent(EditPacing.self, forKey: .defaultPacing) ?? EditPacing()
        defaultMusicVolume = try container.decodeIfPresent(Int.self, forKey: .defaultMusicVolume)
        useLearnedEditingDefaults = try container.decodeIfPresent(Bool.self, forKey: .useLearnedEditingDefaults) ?? false
        learnedHookStyle = try container.decodeIfPresent(String.self, forKey: .learnedHookStyle) ?? ""
        learnedLayoutPreference = try container.decodeIfPresent(String.self, forKey: .learnedLayoutPreference) ?? ""
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
        if let custom = SettingsStore.customDataFolder {
            let root = custom.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
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
        defaultRenderSettings = RenderSettings()
        defaultPacing = EditPacing()
        useLearnedEditingDefaults = false
        learnedHookStyle = ""
        learnedLayoutPreference = ""
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
            "b-roll", "cutaway", "establishing-shot",
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
    var alignment: String?
    var font: String = "sans"          // sans | serif | mono | asset font name
    var color: String = "#ffffff"
    var bgOn: Bool = false
    var bgColor: String = "#000000"
    var position: String = "bottom"    // bottom | middle | top

    // Optional additions preserve profiles and Team Sync documents made before templates.
    var wordsPerPage: Int?
    var highlight: String?
    var highlightColor: String?
    var emphasis: String?
    var emphasisColor: String?
    var uppercase: Bool?
    var weight: String?
    var strokeWidth: Double?
    var shadow: Bool?
    var letterSpacing: Double?
    var animation: String?
    var reveal: String?
    var revealMotion: Bool?
    var emoji: Bool?
    var speakerColors: Bool?
    var highlightFont: String?      // nil: same family as `font`
    var emphasisFont: String?       // nil: same family as `font`

    var text: CaptionWordDecor?
    var highlightDecor: CaptionWordDecor?
    var emphasisDecor: CaptionWordDecor?
    var bgRadius: Double?

    enum WordState: CaseIterable { case text, highlight, emphasis }

    func resolvedDecor(for state: WordState) -> CaptionWordDecor {
        var decor: CaptionWordDecor
        switch state {
        case .text: decor = text ?? CaptionWordDecor()
        case .highlight: decor = highlightDecor ?? CaptionWordDecor()
        case .emphasis: decor = emphasisDecor ?? CaptionWordDecor()
        }
        decor.italic = decor.italic ?? text?.italic ?? false
        decor.underline = decor.underline ?? text?.underline ?? false
        decor.strikethrough = decor.strikethrough ?? text?.strikethrough ?? false
        decor.bgOn = (state == .highlight && resolvedHighlight == "box") || (decor.bgOn ?? false)
        // Typography inherits Text, which in turn falls back to the
        // whole-caption fields older styles stored.
        decor.weight = decor.weight ?? text?.weight ?? weight
        decor.strokeWidth = decor.strokeWidth ?? text?.strokeWidth ?? strokeWidth
        decor.letterSpacing = decor.letterSpacing ?? text?.letterSpacing ?? letterSpacing
        decor.shadow = decor.shadow ?? text?.shadow ?? shadow
        return decor
    }

    func resolvedSize(for state: WordState) -> Double {
        let regular = min(120, max(24, text?.size ?? 49))
        switch state {
        case .text: return regular
        case .highlight:
            return min(120, max(24, highlightDecor?.size ?? regular)) * (resolvedHighlight == "scale" ? 1.12 : 1)
        case .emphasis:
            return min(120, max(24, emphasisDecor?.size ?? regular)) * (["scale", "both"].contains(resolvedEmphasis) ? 1.12 : 1)
        }
    }

    var resolvedPageRadius: Double { min(60, max(0, bgRadius ?? max(6, resolvedSize(for: .text) / 6))) }

    var resolvedWordsPerPage: Int? { wordsPerPage.map { min(8, max(1, $0)) } }
    var resolvedHighlight: String { ["color", "box", "scale"].contains(highlight ?? "") ? highlight! : "none" }
    var resolvedHighlightColor: String { highlightColor ?? "#ffd60a" }
    var resolvedEmphasis: String { ["color", "scale", "both", "font"].contains(emphasis ?? "") ? emphasis! : "none" }
    var resolvedEmphasisColor: String { emphasisColor ?? resolvedHighlightColor }
    var resolvedUppercase: Bool { uppercase ?? false }
    var resolvedWeight: String { ["bold", "black"].contains(weight ?? "") ? weight! : "regular" }
    var resolvedStrokeWidth: Double { min(6, max(0, strokeWidth ?? 1)) }
    var resolvedShadow: Bool { shadow ?? false }
    var resolvedLetterSpacing: Double { min(6, max(-2, letterSpacing ?? 0)) }
    var resolvedAnimation: String { ["pop", "slide-up", "fade"].contains(animation ?? "") ? animation! : "none" }
    var resolvedReveal: String { reveal == "word" ? "word" : "none" }
    var resolvedRevealMotion: Bool { revealMotion ?? false }
    var resolvedEmoji: Bool { emoji ?? false }
    var resolvedSpeakerColors: Bool { speakerColors ?? false }
    var resolvedHighlightFont: String { highlightFont?.isEmpty == false ? highlightFont! : font }
    var resolvedEmphasisFont: String { emphasisFont?.isEmpty == false ? emphasisFont! : font }

    enum CodingKeys: String, CodingKey {
        case font, color, alignment
        case wordsPerPage = "words_per_page"
        case highlight, emphasis, uppercase, weight, shadow, animation, emoji
        case reveal
        case revealMotion = "reveal_motion"
        case highlightColor = "highlight_color"
        case emphasisColor = "emphasis_color"
        case strokeWidth = "stroke_width"
        case letterSpacing = "letter_spacing"
        case speakerColors = "speaker_colors"
        case text = "text_decor"
        case highlightDecor = "highlight_decor"
        case emphasisDecor = "emphasis_decor"
        case bgRadius = "bg_radius"
        case highlightFont = "highlight_font"
        case emphasisFont = "emphasis_font"
        case bgOn = "bg_on"
        case bgColor = "bg_color"
        case position
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(CaptionWordDecor.self, forKey: .text)
        highlightDecor = try container.decodeIfPresent(CaptionWordDecor.self, forKey: .highlightDecor)
        emphasisDecor = try container.decodeIfPresent(CaptionWordDecor.self, forKey: .emphasisDecor)
        bgRadius = try container.decodeIfPresent(Double.self, forKey: .bgRadius)
        alignment = try container.decodeIfPresent(String.self, forKey: .alignment)
        wordsPerPage = try container.decodeIfPresent(Int.self, forKey: .wordsPerPage)
        highlight = try container.decodeIfPresent(String.self, forKey: .highlight)
        highlightColor = try container.decodeIfPresent(String.self, forKey: .highlightColor)
        emphasis = try container.decodeIfPresent(String.self, forKey: .emphasis)
        emphasisColor = try container.decodeIfPresent(String.self, forKey: .emphasisColor)
        uppercase = try container.decodeIfPresent(Bool.self, forKey: .uppercase)
        weight = try container.decodeIfPresent(String.self, forKey: .weight)
        strokeWidth = try container.decodeIfPresent(Double.self, forKey: .strokeWidth)
        shadow = try container.decodeIfPresent(Bool.self, forKey: .shadow)
        letterSpacing = try container.decodeIfPresent(Double.self, forKey: .letterSpacing)
        animation = try container.decodeIfPresent(String.self, forKey: .animation)
        reveal = try container.decodeIfPresent(String.self, forKey: .reveal)
        revealMotion = try container.decodeIfPresent(Bool.self, forKey: .revealMotion)
        emoji = try container.decodeIfPresent(Bool.self, forKey: .emoji)
        speakerColors = try container.decodeIfPresent(Bool.self, forKey: .speakerColors)
        highlightFont = try container.decodeIfPresent(String.self, forKey: .highlightFont)
        emphasisFont = try container.decodeIfPresent(String.self, forKey: .emphasisFont)
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
        if let custom = SettingsStore.customDataFolder {
            return custom.deletingLastPathComponent()
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
