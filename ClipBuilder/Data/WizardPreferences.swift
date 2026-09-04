import Foundation

/// The few output choices a person should make for a Wizard run. These are
/// intentionally outcome-oriented; renderer implementation details stay with
/// the surfaces that own them.
nonisolated enum WizardAudioMode: String, CaseIterable, Sendable {
    case original
    case mix
    case music

    var title: String {
        switch self {
        case .original: "Original audio"
        case .mix: "Original + music"
        case .music: "Music only"
        }
    }

    var useMusic: Bool { self != .original }
    var muteSource: Bool { self == .music }

    static func legacyValue(defaults: UserDefaults = .standard) -> Self {
        let useMusic = defaults.object(forKey: "wizard.useMusic") == nil
            || defaults.bool(forKey: "wizard.useMusic")
        guard useMusic else { return .original }
        return defaults.bool(forKey: "wizard.muteSource") ? .music : .mix
    }
}

nonisolated enum WizardTextMode: String, CaseIterable, Sendable {
    case automatic
    case captions
    case headlines
    case both
    case none

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .captions: "Captions"
        case .headlines: "Headlines"
        case .both: "Captions + headlines"
        case .none: "None"
        }
    }

    /// Automatic favors readable captions for spoken interviews and concise
    /// editorial text for other kinds of reels.
    func output(transcriptsAvailable: Bool, recipe: String) -> (captions: Bool, headlines: Bool) {
        switch self {
        case .automatic:
            let spoken = recipe == "interview" && transcriptsAvailable
            return (spoken, !spoken)
        case .captions:
            return (transcriptsAvailable, false)
        case .headlines:
            return (false, true)
        case .both:
            return (transcriptsAvailable, true)
        case .none:
            return (false, false)
        }
    }

    /// Anyone who ever set either legacy toggle keeps that exact outcome.
    /// Untouched installs deliberately move from the old "no text" default to
    /// Automatic, matching the Auto duration and layout defaults: the recipe
    /// decides between captions and headlines instead of silently rendering
    /// no text at all.
    static func legacyValue(defaults: UserDefaults = .standard) -> Self {
        guard defaults.object(forKey: "wizard.addCaptions") != nil
                || defaults.object(forKey: "wizard.enableTextOverlays") != nil else {
            return .automatic
        }
        let captions = defaults.bool(forKey: "wizard.addCaptions")
        let headlines = defaults.bool(forKey: "wizard.enableTextOverlays")
        switch (captions, headlines) {
        case (true, true): return .both
        case (true, false): return .captions
        case (false, true): return .headlines
        case (false, false): return .none
        }
    }
}

nonisolated enum WizardDurationMode: String, CaseIterable, Sendable {
    case automatic
    case ten
    case twenty
    case thirty
    case custom

    var title: String {
        switch self {
        case .automatic: "Auto"
        case .ten: "10 seconds"
        case .twenty: "20 seconds"
        case .thirty: "30 seconds"
        case .custom: "Custom…"
        }
    }

    var duration: Int? {
        switch self {
        case .automatic: nil
        case .ten: 10
        case .twenty: 20
        case .thirty: 30
        case .custom: nil
        }
    }
}

nonisolated enum WizardLayoutMode: String, CaseIterable, Sendable {
    case singleScene
    case automatic
    case selected

    var title: String {
        switch self {
        case .singleScene: "Single scene"
        case .automatic: "Approved layouts"
        case .selected: "Choose layouts…"
        }
    }
}

nonisolated enum WizardSourceScope: String, CaseIterable, Sendable {
    case all
    case curated
    case batches

    var title: String {
        switch self {
        case .all: "All analyzed scenes"
        case .curated: "Curated scenes only"
        case .batches: "Selected analyze batches"
        }
    }
}

nonisolated enum WizardBrandingMode: String, CaseIterable, Sendable {
    case standard
    case minimal
    case none

    var title: String {
        switch self {
        case .standard: "Standard"
        case .minimal: "Minimal"
        case .none: "No branding"
        }
    }

    var includeWatermark: Bool { self != .none }
    var includeHeadline: Bool { self == .standard }
    var includeOutro: Bool { self == .standard }

    static func legacyValue(defaults: UserDefaults = .standard) -> Self {
        let keys = ["wizard.includeWatermark", "wizard.includeHeadline", "wizard.includeOutro"]
        guard keys.contains(where: { defaults.object(forKey: $0) != nil }) else {
            return .standard
        }
        let watermark = defaults.object(forKey: "wizard.includeWatermark") == nil
            || defaults.bool(forKey: "wizard.includeWatermark")
        let headline = defaults.object(forKey: "wizard.includeHeadline") == nil
            || defaults.bool(forKey: "wizard.includeHeadline")
        let outro = defaults.object(forKey: "wizard.includeOutro") == nil
            || defaults.bool(forKey: "wizard.includeOutro")
        if !watermark { return .none }
        return headline && outro ? .standard : .minimal
    }
}

nonisolated enum WizardBrandingOverride: String, CaseIterable, Sendable {
    case savedDefault
    case standard
    case minimal
    case none

    var title: String {
        switch self {
        case .savedDefault: "Saved default"
        case .standard: "Standard"
        case .minimal: "Minimal"
        case .none: "No branding"
        }
    }

    func resolved(defaults: UserDefaults = .standard) -> WizardBrandingMode {
        switch self {
        case .savedDefault: WizardDefaults.brandingMode(defaults: defaults)
        case .standard: .standard
        case .minimal: .minimal
        case .none: .none
        }
    }
}

/// Centralized persistence and migration for the Wizard's output defaults.
/// Keeping the keys here prevents the execution form from becoming the owner
/// of asset, branding, and rendering preferences again.
nonisolated enum WizardDefaults {
    static let audioModeKey = "wizard.audioMode"
    static let textModeKey = "wizard.textMode"
    static let durationModeKey = "wizard.durationMode"
    static let customDurationKey = "wizard.targetDuration"
    static let layoutModeKey = "wizard.layoutMode"
    static let brandingModeKey = "wizard.brandingMode"
    static let brandingOverrideKey = "wizard.brandingOverride"

    static let useScreenCropsKey = "wizard.useScreenCrops"
    static let screenCropLayoutsKey = "wizard.screenCropLayouts"
    /// Comma-joined layout names for the Wizard's "Choose layouts…" mode.
    static let selectedLayoutsKey = "wizard.selectedLayouts"
    static let limitTransitionsKey = "wizard.limitTransitions"
    static let allowedTransitionsKey = "wizard.allowedTransitions"

    static func migrateLegacy(defaults: UserDefaults = .standard) {
        if defaults.object(forKey: audioModeKey) == nil {
            defaults.set(WizardAudioMode.legacyValue(defaults: defaults).rawValue, forKey: audioModeKey)
        }
        if defaults.object(forKey: textModeKey) == nil {
            defaults.set(WizardTextMode.legacyValue(defaults: defaults).rawValue, forKey: textModeKey)
        }
        // Auto lets the selected recipe, account benchmarks, and reference
        // templates set the right duration. The old 10-second default made
        // every run an unintended hard override.
        if defaults.object(forKey: durationModeKey) == nil {
            defaults.set(WizardDurationMode.automatic.rawValue, forKey: durationModeKey)
        }
        if defaults.object(forKey: layoutModeKey) == nil {
            defaults.set(WizardLayoutMode.automatic.rawValue, forKey: layoutModeKey)
        }
        if defaults.object(forKey: brandingModeKey) == nil {
            defaults.set(WizardBrandingMode.legacyValue(defaults: defaults).rawValue,
                         forKey: brandingModeKey)
        }
        // Source scope is a single choice now; the old form allowed both
        // toggles at once, and batch scope wins in the UI. Drop the hidden
        // curated filter so what the picker reports is what the run uses.
        if defaults.bool(forKey: "wizard.limitToSelection"), defaults.bool(forKey: "wizard.curatedOnly") {
            defaults.set(false, forKey: "wizard.curatedOnly")
        }
        if defaults.object(forKey: brandingOverrideKey) == nil {
            defaults.set(WizardBrandingOverride.savedDefault.rawValue, forKey: brandingOverrideKey)
        }
    }

    static func audioMode(defaults: UserDefaults = .standard) -> WizardAudioMode {
        migrateLegacy(defaults: defaults)
        return WizardAudioMode(rawValue: defaults.string(forKey: audioModeKey) ?? "") ?? .mix
    }

    static func textMode(defaults: UserDefaults = .standard) -> WizardTextMode {
        migrateLegacy(defaults: defaults)
        return WizardTextMode(rawValue: defaults.string(forKey: textModeKey) ?? "") ?? .automatic
    }

    static func durationMode(defaults: UserDefaults = .standard) -> WizardDurationMode {
        migrateLegacy(defaults: defaults)
        return WizardDurationMode(rawValue: defaults.string(forKey: durationModeKey) ?? "") ?? .automatic
    }

    static func brandingMode(defaults: UserDefaults = .standard) -> WizardBrandingMode {
        migrateLegacy(defaults: defaults)
        return WizardBrandingMode(rawValue: defaults.string(forKey: brandingModeKey) ?? "") ?? .standard
    }

    static func brandingOverride(defaults: UserDefaults = .standard) -> WizardBrandingOverride {
        migrateLegacy(defaults: defaults)
        return WizardBrandingOverride(rawValue: defaults.string(forKey: brandingOverrideKey) ?? "")
            ?? .savedDefault
    }

    /// Layouts a run may use under the given mode: none for single scene,
    /// the approved set from Resources, or the run's own pick (only names
    /// that still exist).
    static func screenCropLayouts(for mode: WizardLayoutMode, defaults: UserDefaults = .standard) -> [String] {
        switch mode {
        case .singleScene: return []
        case .automatic: return approvedScreenCropLayouts(defaults: defaults)
        case .selected:
            let chosen = Set((defaults.string(forKey: selectedLayoutsKey) ?? "")
                .split(separator: ",").map(String.init))
            return ScreenCropStore.all().filter { !$0.areas.isEmpty && chosen.contains($0.name) }.map(\.name)
        }
    }

    static func approvedScreenCropLayouts(defaults: UserDefaults = .standard) -> [String] {
        guard defaults.bool(forKey: useScreenCropsKey) else { return [] }
        let existing = ScreenCropStore.all().filter { !$0.areas.isEmpty }.map(\.name)
        let saved = Set((defaults.string(forKey: screenCropLayoutsKey) ?? "")
            .split(separator: ",").map(String.init))
        // An empty legacy selection means every available layout.
        return saved.isEmpty ? existing : existing.filter(saved.contains)
    }

    static func setScreenCropAvailability(_ selected: Set<String>, all names: [String],
                                           defaults: UserDefaults = .standard) {
        let valid = selected.intersection(Set(names))
        defaults.set(!valid.isEmpty, forKey: useScreenCropsKey)
        // Keep the old empty-means-all representation so existing installs
        // and the option reader share one unambiguous source of truth.
        defaults.set(valid.count == names.count ? "" : valid.sorted().joined(separator: ","),
                     forKey: screenCropLayoutsKey)
    }

    static func allowedTransitions(defaults: UserDefaults = .standard) -> [String]? {
        guard defaults.bool(forKey: limitTransitionsKey) else { return nil }
        let valid = Set(RenderEngine.allTransitions)
        return (defaults.string(forKey: allowedTransitionsKey) ?? "")
            .split(separator: ",").map(String.init).filter(valid.contains)
    }

    static func transitionAvailability(all names: [String], defaults: UserDefaults = .standard) -> Set<String> {
        guard defaults.bool(forKey: limitTransitionsKey) else { return Set(names) }
        return Set((defaults.string(forKey: allowedTransitionsKey) ?? "")
            .split(separator: ",").map(String.init)).intersection(Set(names))
    }

    static func setTransitionAvailability(_ selected: Set<String>, all names: [String],
                                          defaults: UserDefaults = .standard) {
        let valid = selected.intersection(Set(names))
        // No limit means the AI can use every effect; an empty limited set
        // deliberately means hard cuts only.
        defaults.set(valid.count != names.count, forKey: limitTransitionsKey)
        defaults.set(valid.sorted().joined(separator: ","), forKey: allowedTransitionsKey)
    }

    static var fallbackFramingCamera: String {
        guard let camera = UserDefaults.standard.string(forKey: "analysis.framingCamera"),
              ["smooth", "balanced", "fast"].contains(camera) else {
            return "balanced"
        }
        return camera
    }
}
