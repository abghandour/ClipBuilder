import Foundation

/// One named set of AI Wizard answers: the same JSON shape the paste bar
/// exchanges between runs, minus anything about sources or a project.
nonisolated struct WizardPreset: NamedPreset, Hashable {
    var name: String
    var savedAt: Date
    var settings: [String: JSONSetting]

    var id: String { name.lowercased() }
}

/// Saved Wizard answers live on the brand profile (`wizard_presets`), so
/// Team Sync shares them with every member through the profile document.
/// The answers themselves stay in the `wizard.*` defaults the pipeline,
/// the paste bar and resource bundles already read; a preset is a snapshot
/// of those keys, and loading one writes them back.
nonisolated enum WizardPresetStore {
    /// Fields a preset never carries: they describe one project's footage
    /// or one run, not how the user likes reels made.
    static let excludedFields: Set<String> = [
        "projectID", "sourceSceneSelection", "sourcesRestricted", "selectedRunIDs", "sourcePeople",
        "favoritesOnly", "stackLevel", "sourceProfile", "sourceVideoPaths", "sourceSceneIDs",
        "templateJSON", "templateLabel", "pinnedOverlayText", "modelOverride", "aiInstructions",
    ]

    static func lastUsedKey(profileName: String) -> String { "wizard.\(profileName).presetName" }
    static func baselineKey(profileName: String) -> String { "wizard.\(profileName).presetBaseline" }
    /// Where a profile's answers rest while another profile is active.
    static func answersKey(profileName: String) -> String { "wizard.\(profileName).answers" }

    struct Loaded: Equatable, Sendable {
        var name: String
        var settings: [String: JSONSetting]
    }

    static func rememberLoaded(_ loaded: Loaded?, profileName: String, defaults: UserDefaults = .standard) {
        guard let loaded else {
            defaults.removeObject(forKey: lastUsedKey(profileName: profileName))
            defaults.removeObject(forKey: baselineKey(profileName: profileName))
            return
        }
        defaults.set(loaded.name, forKey: lastUsedKey(profileName: profileName))
        defaults.set(AISettingsJSON.encode(loaded.settings), forKey: baselineKey(profileName: profileName))
    }

    static func loaded(profileName: String, defaults: UserDefaults = .standard) -> Loaded? {
        guard let name = defaults.string(forKey: lastUsedKey(profileName: profileName)), !name.isEmpty,
              let settings = AISettingsJSON.decode([String: JSONSetting].self,
                                                   defaults.string(forKey: baselineKey(profileName: profileName)))
        else { return nil }
        return Loaded(name: name, settings: settings)
    }

    /// The preset shape of a settings dictionary: run and source fields removed.
    static func presetFields(_ settings: [String: JSONSetting]) -> [String: JSONSetting] {
        settings.filter { !excludedFields.contains($0.key) && $0.value != .null }
    }

    static func cardTitle(loaded: Loaded?, current: [String: JSONSetting]) -> String {
        NamedPresets.cardTitle(loadedName: loaded?.name,
                               modified: loaded.map { presetFields($0.settings) != presetFields(current) } ?? false)
    }

    /// A one-line description for the Load sheet.
    static func summary(_ preset: WizardPreset) -> String {
        let fields = preset.settings
        var parts: [String] = [preset.savedAt.formatted(date: .abbreviated, time: .shortened)]
        if let recipe = fields["formatPreset"]?.string, let title = ReelRecipe.recipe(id: recipe)?.title { parts.append(title) }
        if let seconds = fields["targetDurationSeconds"]?.number { parts.append("\(Int(seconds))s") }
        if fields["critiqueLoop"] == .bool(true) { parts.append("critique") }
        if fields["addCaptions"] == .bool(true) { parts.append("captions") }
        if fields["useMusic"] == .bool(true) { parts.append("music") }
        if let look = fields["lookPreset"]?.string, !look.isEmpty, look != "none" {
            parts.append(EffectCatalog.preset(for: look)?.name ?? look)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Lists (shared rules)

    static func sorted(_ presets: [WizardPreset]) -> [WizardPreset] { NamedPresets.sorted(presets) }
    static func cleaned(_ name: String) -> String { NamedPresets.cleaned(name) }
    static func preset(named name: String, in presets: [WizardPreset]) -> WizardPreset? { NamedPresets.preset(named: name, in: presets) }
    static func upsert(name: String, settings: [String: JSONSetting], savedAt: Date = Date(),
                       into presets: [WizardPreset]) -> [WizardPreset] {
        NamedPresets.upsert(WizardPreset(name: name, savedAt: savedAt, settings: presetFields(settings)), into: presets)
    }
    static func rename(_ oldName: String, to newName: String, in presets: [WizardPreset]) -> [WizardPreset]? {
        NamedPresets.rename(oldName, to: newName, in: presets)
    }
    static func delete(_ name: String, in presets: [WizardPreset]) -> [WizardPreset] { NamedPresets.delete(name, in: presets) }
    static func suggestedName(lastUsed: String?, presets: [WizardPreset]) -> String {
        NamedPresets.suggestedName(lastUsed: lastUsed, presets: presets)
    }
}

/// Snapshots of the Wizard's answers per profile, so switching profiles
/// brings each one's own answers back, as Express does with its memory keys.
/// Before the first switch a profile simply keeps the app-wide answers, so an
/// existing install migrates without losing anything.
@MainActor enum WizardMemory {
    /// The current answers as a preset-shaped dictionary.
    static func capture(profile: BrandProfile, renderSettings: RenderSettings?, pacing: EditPacing?,
                        defaults: UserDefaults = .standard) -> [String: JSONSetting] {
        var settings = AISettingsPreferences.wizard(defaults: defaults, profile: profile)
        if let renderSettings { settings["renderSettings"] = JSONSetting.dictionaryValue(renderSettings) }
        if let pacing { settings["pacing"] = JSONSetting.dictionaryValue(pacing) }
        return WizardPresetStore.presetFields(settings)
    }

    /// Write preset-shaped answers into the live defaults. Returns the render
    /// settings and pacing carried by the dictionary, which the view keeps as
    /// its run edits (they have no defaults key of their own).
    @discardableResult
    static func apply(_ settings: [String: JSONSetting], profileName: String,
                      defaults: UserDefaults = .standard) -> (renderSettings: RenderSettings?, pacing: EditPacing?) {
        AISettingsPreferences.write(WizardPresetStore.presetFields(settings), kind: .wizard,
                                    scopes: [.options, .prompts], profileName: profileName,
                                    defaults: defaults, recordSnapshot: false)
        return (settings["renderSettings"].flatMap { $0.decodeValue() },
                settings["pacing"].flatMap { $0.decodeValue() })
    }

    static func remember(profile: BrandProfile, renderSettings: RenderSettings?, pacing: EditPacing?,
                         defaults: UserDefaults = .standard) {
        let captured = capture(profile: profile, renderSettings: renderSettings, pacing: pacing, defaults: defaults)
        defaults.set(AISettingsJSON.encode(captured), forKey: WizardPresetStore.answersKey(profileName: profile.profileName))
    }

    /// Nil when this profile has never been remembered: the live answers stand.
    @discardableResult
    static func restore(profileName: String, defaults: UserDefaults = .standard) -> (renderSettings: RenderSettings?, pacing: EditPacing?)? {
        guard let stored = AISettingsJSON.decode([String: JSONSetting].self,
                                                 defaults.string(forKey: WizardPresetStore.answersKey(profileName: profileName)))
        else { return nil }
        return apply(stored, profileName: profileName, defaults: defaults)
    }
}
