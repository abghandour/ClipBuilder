import Foundation

/// Express settings presets live on the active profile so Team Sync carries
/// them to every member. Views read and write through here.
extension AppStore {
    func expressPresets(profileName: String) -> [MiniWizardPreset] {
        guard activeProfile.profileName == profileName else { return [] }
        if let presets = activeProfile.expressPresets { return presets }
        // 1.102 kept a per-profile file; adopt it into the profile once.
        let legacy = MiniWizardPresetStore.legacyPresets(profileName: profileName)
        if !legacy.isEmpty {
            activeProfile.expressPresets = legacy
            _ = saveActiveProfile()
        }
        return legacy
    }

    @discardableResult
    func saveExpressPresets(_ presets: [MiniWizardPreset], profileName: String) -> Bool {
        guard activeProfile.profileName == profileName else { return false }
        activeProfile.expressPresets = MiniWizardPresetStore.sorted(presets)
        _ = saveActiveProfile()
        return true
    }
}
