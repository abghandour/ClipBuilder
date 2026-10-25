import Foundation

/// Navigation preference only; Full and Express keep independent settings.
nonisolated enum WizardMode: String, CaseIterable, Sendable {
    // Express first: it is the default and sits on the left of the switch.
    case express, full

    var label: String {
        switch self {
        case .full: "Full"
        case .express: "Express"
        }
    }

    var systemImage: String {
        switch self {
        case .full: "wand.and.stars"
        case .express: "wand.and.stars.inverse"
        }
    }

    static func remembered(profileName: String, defaults: UserDefaults = .standard) -> WizardMode {
        defaults.string(forKey: "wizard.mode.\(profileName)").flatMap(WizardMode.init(rawValue:)) ?? .express
    }

    func remember(profileName: String, defaults: UserDefaults = .standard) {
        let key = "wizard.mode.\(profileName)"
        guard defaults.string(forKey: key) != rawValue else { return }
        defaults.set(rawValue, forKey: key)
    }
}
