import Foundation

/// The requested picture; resolved clip plans persist separately from these choices.
nonisolated struct Framing: Codable, Hashable, Sendable {
    var subject: Subject = .auto
    var pullBack: Double = 0
    var moves: Moves = .smooth
    var fit: Fit = .fill
    var feather: Double = 0.08
    var blur: Double = 0.5
    var focusFrame: FreeCropRect?
    /// Nil keeps Original's handle at the canvas aspect; false frees it under blurred fill.
    var lockAspect: Bool?
    /// Who Center stage keeps in the picture. Nil means everyone.
    var people: People?
    /// Person keys treated as the VIPs for this run. Nil follows the People tags.
    var vips: [String]?
    var sourceRoles: [String: String]?
    var layout: String?
    /// Speaker focus's shot: a recipe kind, or nil for the app's pick per scene.
    var speakerShot: CropRecipe.Kind?

    /// The shots Speaker focus can be told to use, in menu order.
    static let speakerShots: [CropRecipe.Kind] = [.talker, .interview, .talkerAndRest, .talkerAndPrevious, .talkerAndRotation]

    enum Subject: String, Codable, CaseIterable, Hashable, Sendable {
        case auto, original, centerStage, vipFocus, speakerFocus, layout

        static func legacy(_ kind: CropRecipe.Kind) -> Self {
            switch kind {
            case .vip, .vipBRoll: .vipFocus
            case .grid: .layout
            case .talker, .interview, .talkerAndRest, .talkerAndPrevious, .talkerAndRotation: .speakerFocus
            }
        }

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            let raw = try value.decode(String.self)
            if let subject = Self(rawValue: raw) { self = subject }
            else if let kind = CropRecipe.Kind(rawValue: raw) { self = Self.legacy(kind) }
            else { throw DecodingError.dataCorruptedError(in: value, debugDescription: "Unknown framing subject: \(raw)") }
        }

        func label(type: VideoType) -> String {
            switch self {
            case .auto: "Auto"
            case .original: "Original"
            case .centerStage: "Center stage"
            case .vipFocus: type == .fight ? "Fighter focus" : "VIP focus"
            case .speakerFocus: "Speaker focus"
            case .layout: "Layout"
            }
        }

        /// One sentence next to the menu: what the viewer sees.
        func summary(type: VideoType) -> String {
            switch self {
            case .auto: "The app picks the best framing for each scene."
            case .original: "The source as recorded. A focus frame makes it a fixed window."
            case .centerStage: "One picture; a calm camera follows everyone or just the VIPs."
            case .vipFocus: type == .fight
                ? "Tracks the tagged fighter, or both fighters when none is tagged."
                : "Keeps the VIP on screen; several VIPs take turns, B-roll breaks when available."
            case .speakerFocus: "Follows whoever is talking. Pull back widens the shot, Moves picks glide or cut."
            case .layout: "Fills a screen layout by role: VIP, others, B-roll, screen, presenter."
            }
        }
    }
    enum People: String, Codable, Hashable, Sendable { case everyone, vips }
    enum Moves: String, Codable, Hashable, Sendable { case smooth, cuts }
    enum Fit: String, Codable, Hashable, Sendable { case fill, blurredFill }

    enum CodingKeys: String, CodingKey {
        case subject, moves, fit, feather, blur, layout, people, vips
        case pullBack = "pull_back"
        case focusFrame = "focus_frame"
        case lockAspect = "lock_aspect"
        case sourceRoles = "source_roles"
        case speakerShot = "speaker_shot"
    }

    init(subject: Subject = .auto, pullBack: Double = 0, moves: Moves = .smooth,
         fit: Fit = .fill, feather: Double = 0.08, blur: Double = 0.5,
         focusFrame: FreeCropRect? = nil, lockAspect: Bool? = nil, people: People? = nil, vips: [String]? = nil,
         layout: String? = nil, sourceRoles: [String: String]? = nil, speakerShot: CropRecipe.Kind? = nil) {
        self.subject = subject
        self.pullBack = pullBack
        self.moves = moves
        self.fit = fit
        self.feather = feather
        self.blur = blur
        self.focusFrame = focusFrame
        self.lockAspect = lockAspect
        self.people = people
        self.vips = vips
        self.layout = layout
        self.sourceRoles = sourceRoles
        self.speakerShot = speakerShot
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subject = try c.decodeIfPresent(Subject.self, forKey: .subject) ?? .auto
        pullBack = try c.decodeIfPresent(Double.self, forKey: .pullBack) ?? 0
        moves = try c.decodeIfPresent(Moves.self, forKey: .moves) ?? .smooth
        fit = try c.decodeIfPresent(Fit.self, forKey: .fit) ?? .fill
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 0.08
        blur = try c.decodeIfPresent(Double.self, forKey: .blur) ?? 0.5
        focusFrame = try c.decodeIfPresent(FreeCropRect.self, forKey: .focusFrame)
        lockAspect = try c.decodeIfPresent(Bool.self, forKey: .lockAspect)
        people = try c.decodeIfPresent(People.self, forKey: .people)
        vips = try c.decodeIfPresent([String].self, forKey: .vips)
        sourceRoles = try c.decodeIfPresent([String: String].self, forKey: .sourceRoles)
        layout = try c.decodeIfPresent(String.self, forKey: .layout)
        speakerShot = try c.decodeIfPresent(CropRecipe.Kind.self, forKey: .speakerShot)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let base = Self()
        if subject != base.subject { try c.encode(subject, forKey: .subject) }
        if pullBack != base.pullBack { try c.encode(pullBack, forKey: .pullBack) }
        if moves != base.moves { try c.encode(moves, forKey: .moves) }
        if fit != base.fit { try c.encode(fit, forKey: .fit) }
        if feather != base.feather { try c.encode(feather, forKey: .feather) }
        if blur != base.blur { try c.encode(blur, forKey: .blur) }
        try c.encodeIfPresent(focusFrame, forKey: .focusFrame)
        try c.encodeIfPresent(lockAspect, forKey: .lockAspect)
        try c.encodeIfPresent(people, forKey: .people)
        try c.encodeIfPresent(vips, forKey: .vips)
        try c.encodeIfPresent(sourceRoles, forKey: .sourceRoles)
        try c.encodeIfPresent(layout, forKey: .layout)
        try c.encodeIfPresent(speakerShot, forKey: .speakerShot)
    }

    /// One scalar for AppStorage, Express memory and the shared preset catalog.
    var joined: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func split(_ string: String?) -> Self? {
        guard let string else { return nil }
        return try? JSONDecoder().decode(Self.self, from: Data(string.utf8))
    }

    /// Idempotent: a stored request always wins over the old controls.
    static func legacy(from options: WizardOptions) -> Self {
        if let framing = options.framing { return framing }
        if options.podcastFraming == .original { return Self(subject: .original) }
        switch options.highlightFraming {
        case .vip, .vipBRoll: return Self(subject: .vipFocus)
        case .talker, .interview, .talkerAndRest, .talkerAndPrevious, .talkerAndRotation:
            return Self(subject: .speakerFocus, pullBack: options.interviewZoom ?? 0,
                        moves: options.interviewCuts == true ? .cuts : .smooth)
        case .grid: return Self(subject: .layout, layout: "Split")
        case nil:
            // splitZoom was the old spelling of grid, still accepted in live options.
            return options.podcastFraming == .splitZoom ? Self(subject: .layout, layout: "Split") : Self()
        }
    }
}

nonisolated enum FramingMenu {
    static func allowed(type: VideoType) -> [Framing.Subject] {
        switch type {
        case .fight: [.original, .vipFocus]
        case .training: [.original, .centerStage]
        case .podcast: [.auto, .speakerFocus, .centerStage, .layout, .original]
        case .interview: [.speakerFocus, .centerStage, .layout, .auto, .original]
        case .screen: [.layout, .original]
        case .recap, .other: [.speakerFocus, .layout, .original]
        }
    }

    /// Layout picker entries resolved per scene: a grid sized by head count.
    static let everyoneLayout = "Everyone"
    static let vipsLayout = "VIPs"
    static let virtualLayouts = [everyoneLayout, vipsLayout]

    static func virtualLayoutSummary(_ name: String) -> String? {
        switch name {
        case everyoneLayout: "Everybody in frame, grid by head count"
        case vipsLayout: "All VIPs, grid by VIP count"
        default: nil
        }
    }

    static func `default`(type: VideoType) -> Framing {
        Framing(subject: allowed(type: type)[0], fit: type == .fight || type == .training || type == .screen ? .blurredFill : .fill)
    }
}

nonisolated enum FramingHolds {
    static let rotation = 6.0
    static let vipHold = 4.0
    static let tail = 2.5
    static let recipeHold = 1.5
    static let glide = 0.8
}
