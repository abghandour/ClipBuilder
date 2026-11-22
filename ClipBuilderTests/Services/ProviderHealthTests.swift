import Foundation
import Testing
@testable import Clip_Builder

@Suite("AI provider stop light")
struct ProviderHealthTests {
    private func item(_ id: String, _ state: ProviderAuth.State) -> ProviderStatusItem {
        ProviderStatusItem(id: id, label: AICatalog.provider(id)?.label ?? id, state: state)
    }

    @Test("Green when every signed-in provider works, yellow when some fail, red when none works")
    func lights() {
        let signedIn = [item("claude", .signedIn), item("codex", .signedIn)]
        #expect(ProviderHealth(items: signedIn, problems: [:]).light == .green)
        #expect(ProviderHealth(items: signedIn, problems: ["codex": "quota"]).light == .yellow)
        #expect(ProviderHealth(items: signedIn, problems: ["codex": "quota", "claude": "no answer"]).light == .red)
        #expect(ProviderHealth(items: [item("claude", .signedIn)], problems: ["claude": "quota"]).light == .red)
    }

    @Test("A provider without a sign-in is left out of the light, also when it is failing")
    func ignored() {
        let items = [item("claude", .signedIn), item("antigravity", .signedOut), item("kimi", .unknown)]
        let health = ProviderHealth(items: items, problems: ["antigravity": "not signed in"])
        #expect(health.light == .green)
        #expect(health.counted.map(\.id) == ["claude"] && health.ignored.map(\.id) == ["antigravity", "kimi"])
        // Nothing signed in: no colour to show.
        let none = ProviderHealth(items: [item("antigravity", .signedOut)], problems: [:])
        #expect(none.light == .off && none.summary == "No AI provider is signed in")
        #expect(ProviderHealth(items: [], problems: [:]).light == .off)
    }

    @Test("The hover text names who works, who fails and why, and who is not counted")
    func tooltip() {
        let items = [item("claude", .signedIn), item("codex", .signedIn), item("antigravity", .signedOut)]
        let health = ProviderHealth(items: items, problems: ["codex": "quota exceeded; skipped for 9 more min"])
        #expect(health.tooltip == """
            1 of 2 AI providers is failing
            Working: Claude Code
            Failing: Codex CLI (quota exceeded; skipped for 9 more min)
            Not counted: Antigravity CLI (not signed in)
            """)
        #expect(ProviderHealth(items: [item("claude", .signedIn), item("codex", .signedIn)], problems: [:]).summary
            == "All 2 AI providers are working")
    }
}
