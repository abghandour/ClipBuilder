import Foundation
import SwiftUI
import Testing
@testable import Clip_Builder

@Suite("Sidebar provider status")
@MainActor
struct ProviderStatusModelTests {
    @Test("Status maps to its dot color, label, and sign-in action")
    func presentation() {
        let cases: [(ProviderAuth.State, Color, String, Bool)] = [
            (.signedIn, .green, "signed in", false),
            (.signedOut, .red, "not signed in", true),
            (.unknown, .gray, "unknown", true),
        ]
        for (state, color, label, canSignIn) in cases {
            let item = ProviderStatusItem(id: "claude", label: "Claude Code", state: state)
            #expect(item.color == color)
            #expect(item.statusLabel == label)
            #expect(item.accessibilityLabel == "Claude Code: \(label)")
            #expect(item.canSignIn == canSignIn)
        }
    }

    @Test("Only installed providers are shown, using the configured binary")
    func installedProviders() async {
        let model = ProviderStatusModel(
            locate: { name in
                switch name {
                case "/custom/claude", "codex", "kimi": URL(fileURLWithPath: name)
                default: nil
                }
            },
            status: { key, binary in
                switch key {
                case "claude": return binary.path == "/custom/claude" ? .signedIn : .unknown
                case "codex": return .signedOut
                case "kimi": return .unknown
                default:
                    Issue.record("Probed an uninstalled provider: \(key)")
                    return .unknown
                }
            }
        )
        await model.refresh(binaries: ["claude": "/custom/claude"])
        #expect(model.items.map { $0.id } == ["claude", "codex", "kimi"])
        #expect(model.items.map { $0.state } == [.signedIn, .signedOut, .unknown])
    }

    @Test("No installed providers produces an empty row")
    func noInstalledProviders() async {
        let model = ProviderStatusModel(locate: { _ in nil }, status: { _, _ in
            Issue.record("Auth status must not run for missing binaries")
            return .unknown
        })
        await model.refresh(binaries: [:])
        #expect(model.items.isEmpty)
    }
}
