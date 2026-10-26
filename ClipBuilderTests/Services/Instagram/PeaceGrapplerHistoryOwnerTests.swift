import Testing
@testable import Clip_Builder

@Suite("Peace Grappler history owner")
struct PeaceGrapplerHistoryOwnerTests {
    @Test("The committed reports belong to the main account only", arguments: ["peacegrappler", "@PeaceGrappler", " peacegrappler\n"])
    func owner(username: String) {
        #expect(PeaceGrapplerImporter.historyBelongs(to: username))
    }

    @Test("Other own accounts never receive that history", arguments: ["peacegrappler_podcast", "pg_grappling", "peacegrappler_mma", ""])
    func others(username: String) {
        #expect(!PeaceGrapplerImporter.historyBelongs(to: username))
    }

    @Test("Report counts parse plain, grouped, and decimal values")
    func reportIntParses() {
        #expect(ReportHTML.int("1,234") == 1234)
        #expect(ReportHTML.int("+56") == 56)
        #expect(ReportHTML.int("12.7") == 12)
        #expect(ReportHTML.int(nil) == nil)
    }

    @Test("Non-finite and out-of-range report counts return nil instead of trapping",
          arguments: ["nan", "inf", "-inf", "1e100", "-1e100", "infinity"])
    func reportIntRejects(text: String) {
        #expect(ReportHTML.int(text) == nil)
    }
}
