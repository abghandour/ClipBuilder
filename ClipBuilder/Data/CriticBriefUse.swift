import Foundation

/// Profile-scoped override of the measured keep rule.
nonisolated enum CriticBriefUse: String, Codable, CaseIterable, Sendable {
    case automatic, on, off

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .on: return "On"
        case .off: return "Off"
        }
    }

    func isEnabled(keepRulePassed: Bool) -> Bool {
        switch self {
        case .automatic: return keepRulePassed
        case .on: return true
        case .off: return false
        }
    }

    func status(keepRulePassed: Bool) -> String {
        switch self {
        case .automatic:
            return keepRulePassed ? "Used: automatic (keep rule passed)"
                : "Used: automatic (keep rule not passed yet)"
        case .on: return "Used: always"
        case .off: return "Off"
        }
    }
}
