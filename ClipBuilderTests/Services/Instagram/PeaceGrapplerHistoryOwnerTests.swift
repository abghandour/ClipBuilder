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
}
