import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Builder Wizard history")
struct BuilderWizardHistoryTests {
    @Test func tenEntriesPerProfileRoundTrip() throws {
        let suite = "BuilderWizardHistoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = BuilderWizardHistory(defaults: defaults)
        for index in 0..<12 { history.add("request \(index)", profile: "First") }
        history.add("other request", profile: "Second")
        let reopened = BuilderWizardHistory(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(reopened.requests(profile: "First") == (2..<12).reversed().map { "request \($0)" })
        #expect(reopened.requests(profile: "Second") == ["other request"])
        #expect(reopened.requests(profile: "Missing").isEmpty)
        reopened.add("request 5", profile: "First")
        #expect(reopened.requests(profile: "First").first == "request 5")
        #expect(reopened.requests(profile: "First").count == 10)
        reopened.add("  \n  ", profile: "First")
        #expect(reopened.requests(profile: "First").count == 10)
    }
}
