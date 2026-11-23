import Foundation

/// The existing active preference stays zero while off; the last duration survives it.
nonisolated enum StrikePausePreference {
    /// All writers (controls, presets and assistant settings) share this setter.
    static func setActive(_ value: Double, defaults: UserDefaults = .standard) {
        let active = value.isFinite && value > 0 ? seconds(value) : 0
        let previous = defaults.double(forKey: "wizard.strikeImpactFreeze")
        if active > 0 || previous.isFinite && previous > 0 {
            defaults.set(active > 0 ? active : seconds(previous), forKey: "wizard.strikeImpactFreezeSeconds")
        }
        defaults.set(active, forKey: "wizard.strikeImpactFreeze")
    }

    static func seconds(_ value: Double) -> Double {
        value.isFinite && value > 0
            ? min(StrikeFreezeRules.holdRange.upperBound, max(StrikeFreezeRules.holdRange.lowerBound, value))
            : StrikeHighlightRules.impactHold
    }

    static func toggled(_ enabled: Bool, active: Double, remembered: Double) -> (active: Double, remembered: Double) {
        let saved = seconds(active > 0 ? active : remembered)
        return (enabled ? saved : 0, saved)
    }
}
