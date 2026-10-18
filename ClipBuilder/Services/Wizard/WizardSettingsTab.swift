import Foundation

/// The Settings tabs both wizards share, in the order a reel is built: the
/// picture, its sound, what is drawn over it, and the wrapper around it.
nonisolated enum WizardSettingsTab: String, CaseIterable, Sendable {
    case picture, audio, overlays, package

    var label: String {
        switch self {
        case .picture: "Picture"
        case .audio: "Audio"
        case .overlays: "Overlays"
        case .package: "Package"
        }
    }

    /// Audio only exists where the recipe or footage offers sound choices.
    static func available(audio: Bool) -> [WizardSettingsTab] {
        allCases.filter { $0 != .audio || audio }
    }

    /// A remembered tab the page does not offer opens Picture.
    func effective(in tabs: [WizardSettingsTab]) -> WizardSettingsTab { tabs.contains(self) ? self : .picture }
}

/// The next render as a card: what renders, then the active choices
/// grouped the way the Settings tabs are. Both wizards show one above
/// their Generate button.
nonisolated struct WizardRunSummary: Equatable, Sendable {
    struct Section: Equatable, Sendable {
        var title: String
        var items: [String]
    }
    /// "One reel from Guard pass, Take 2 + 2 more" or "No kept footage".
    var headline: String
    /// "15 s", "Auto length"; nil when the length is not a choice.
    var length: String?
    var sections: [Section]
    var hasFootage: Bool
}
