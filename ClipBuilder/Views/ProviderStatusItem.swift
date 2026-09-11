import SwiftUI

nonisolated struct ProviderStatusItem: Identifiable, Sendable {
    let id: String
    let label: String
    let state: ProviderAuth.State

    var statusLabel: String {
        switch state {
        case .signedIn: "signed in"
        case .signedOut: "not signed in"
        case .unknown: "unknown"
        }
    }

    var accessibilityLabel: String { "\(label): \(statusLabel)" }
    var canSignIn: Bool { state != .signedIn }

    @MainActor var color: Color {
        switch state {
        case .signedIn: .green
        case .signedOut: .red
        case .unknown: .gray
        }
    }

    var symbol: String {
        switch id {
        case "claude": "sparkle"
        case "gemini": "diamond"
        case "codex": "chevron.left.forwardslash.chevron.right"
        case "qwen": "q.circle"
        case "kimi": "k.circle"
        default: "terminal"
        }
    }
}
