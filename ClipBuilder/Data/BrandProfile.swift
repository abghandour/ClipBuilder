import Foundation

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
    var introVideo: String?
    var outroVideo: String?

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
        case introVideo = "intro_video"
        case outroVideo = "outro_video"
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
        introVideo = try container.decodeIfPresent(String.self, forKey: .introVideo)
        outroVideo = try container.decodeIfPresent(String.self, forKey: .outroVideo)
    }

    init(name: String) {
        profileName = name
        brandName = name
        contentDomain = ""
        sourceFolder = "~/Documents/ClipBuilder/\(name)/Input"
        outputFolder = "~/Documents/ClipBuilder/\(name)/Output"
        tagSchema = [:]
        socials = ["instagram": SocialSlot(), "tiktok": SocialSlot(), "youtube": SocialSlot()]
        captions = CaptionStyle()
        introVideo = nil
        outroVideo = nil
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
        FileManager.default.homeDirectoryForCurrentUser
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
        try encoder.encode(profile).write(to: profileURL(name: profile.profileName))
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
