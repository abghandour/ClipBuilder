import Foundation

nonisolated enum WizardCameraFocus {
    static let original = "original"
    static let migrationKey = "wizard.cameraFocusMigrated"

    static func migratedSelection(cameraFocus: String, legacyPodcastFraming: String?) -> String {
        switch legacyPodcastFraming {
        case PodcastFramingMode.splitZoom.rawValue: CropRecipe.Kind.grid.rawValue
        case PodcastFramingMode.original.rawValue: original
        default: cameraFocus
        }
    }

    static func name(_ selection: String) -> String {
        if selection == original { return "Original framing" }
        return CropRecipe.Kind(rawValue: selection)?.name ?? "Let AI choose the best"
    }

    static func summary(_ selection: String) -> String {
        if selection == original { return "Keep the source framing without following speakers or splitting feeds." }
        return CropRecipe.Kind(rawValue: selection)?.summary ?? "Let the AI choose the camera focus that best suits the exchange."
    }

    static func migrate(defaults: UserDefaults) {
        guard !defaults.bool(forKey: migrationKey) else { return }
        let selection = migratedSelection(cameraFocus: defaults.string(forKey: "wizard.highlightFraming") ?? "",
            legacyPodcastFraming: defaults.string(forKey: "wizard.podcastFraming"))
        if selection != original, !selection.isEmpty {
            defaults.set(selection, forKey: "wizard.highlightFraming")
        }
        defaults.set(selection == original ? PodcastFramingMode.original.rawValue : PodcastFramingMode.followSpeaker.rawValue,
                     forKey: "wizard.podcastFraming")
        defaults.set(true, forKey: migrationKey)
    }
}
