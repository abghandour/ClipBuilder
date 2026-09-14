import Foundation
import Testing
@testable import Clip_Builder

@Suite("Builder browser tab preference")
struct ClipBrowserPaneTests {
    @Test(arguments: ["scenes", "wizard", "scripts", "unknown", ""])
    func restoresStoredTab(value: String) throws {
        let suite = "ClipBrowserTabs.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(value, forKey: "builder.browserTab")
        let stored = try #require(defaults.string(forKey: "builder.browserTab"))
        #expect(ClipBrowserPane.restoredTab(stored) == (["scenes", "wizard", "scripts"].contains(value) ? value : "scenes"))
    }
}
