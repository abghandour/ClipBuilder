import Foundation

/// One light for all AI providers: the status bar's stop light.
///
/// Only providers that are signed in count. One that is not installed, not
/// signed in, or cannot say whether it is, is left out of the light and
/// listed apart. A counted provider is failing while the AI service is
/// skipping it: cooling down after a failure that was the provider's
/// (quota, sign-in, no answer), or refused for this account.
nonisolated struct ProviderHealth: Sendable {
    enum Light: Equatable, Sendable {
        /// Every counted provider works.
        case green
        /// At least one fails and at least one works.
        case yellow
        /// None works.
        case red
        /// Nothing to count: no provider is signed in.
        case off
    }

    struct Entry: Equatable, Sendable, Identifiable {
        var id: String
        var label: String
        /// Why it is failing; nil while it works.
        var problem: String?
    }

    /// Signed-in providers, in catalog order.
    var counted: [Entry] = []
    /// Installed but left out: not signed in, or unable to say.
    var ignored: [ProviderStatusItem] = []

    var working: [Entry] { counted.filter { $0.problem == nil } }
    var failing: [Entry] { counted.filter { $0.problem != nil } }

    var light: Light {
        if counted.isEmpty { return .off }
        if failing.isEmpty { return .green }
        return working.isEmpty ? .red : .yellow
    }

    /// `problems` are the providers the AI service is skipping, with the reason.
    init(items: [ProviderStatusItem], problems: [String: String]) {
        for item in items {
            if item.state == .signedIn {
                counted.append(Entry(id: item.id, label: item.label, problem: problems[item.id]))
            } else {
                ignored.append(item)
            }
        }
    }

    var summary: String {
        switch light {
        case .green: counted.count == 1 ? "\(counted[0].label) is working" : "All \(counted.count) AI providers are working"
        case .yellow: "\(failing.count) of \(counted.count) AI providers \(failing.count == 1 ? "is" : "are") failing"
        case .red: counted.count == 1 ? "\(counted[0].label) is failing" : "No AI provider is working"
        case .off: "No AI provider is signed in"
        }
    }

    /// The hover text: the summary, then who works, who fails and why, and who is left out.
    var tooltip: String {
        var lines = [summary]
        if !working.isEmpty { lines.append("Working: " + working.map(\.label).joined(separator: ", ")) }
        for entry in failing { lines.append("Failing: \(entry.label) (\(entry.problem ?? ""))") }
        if !ignored.isEmpty {
            lines.append("Not counted: " + ignored.map { "\($0.label) (\($0.statusLabel))" }.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}
