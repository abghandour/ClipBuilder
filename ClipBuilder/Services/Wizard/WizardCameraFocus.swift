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
        if defaults.string(forKey: WizardExpressExtras.framingKey) == nil,
           defaults.object(forKey: "wizard.highlightFraming") != nil || defaults.object(forKey: "wizard.podcastFraming") != nil {
            var old = WizardOptions()
            old.highlightFraming = CropRecipe.Kind(rawValue: selection)
            old.podcastFraming = selection == original ? .original : .followSpeaker
            old.interviewZoom = defaults.double(forKey: "wizard.interviewZoom")
            old.interviewCuts = defaults.bool(forKey: "wizard.interviewCuts")
            defaults.set(Framing.legacy(from: old).joined, forKey: WizardExpressExtras.framingKey)
        }
        defaults.set(true, forKey: migrationKey)
    }
}
