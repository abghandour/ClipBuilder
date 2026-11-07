import Testing
@testable import Clip_Builder

struct ReleaseNameTests {
    @Test func parseTakesTheFirstNonBlankLineTrimmed() {
        #expect(ReleaseName.parse("Harbor\n") == "Harbor")
        #expect(ReleaseName.parse("  \n  Blue Harbor  \nignored") == "Blue Harbor")
        #expect(ReleaseName.parse("") == nil)
        #expect(ReleaseName.parse(" \n\t\n") == nil)
    }

    @Test func aboutVersionNamesTheReleaseOnlyWhenItHasAName() {
        #expect(ReleaseName.aboutVersion(version: "1.152", name: "Harbor") == "1.152 “Harbor”")
        #expect(ReleaseName.aboutVersion(version: "1.152", name: nil) == nil)
    }

    @Test func debugAndTestBuildsCarryNoName() {
        #expect(ReleaseName.current == nil)
    }
}
