import Foundation
import Testing
@testable import Clip_Builder

struct LearnedLibraryTests {
    @Test func isolatedInstallAndRead() throws {
        let temp = try TempDirectory()
        let library = LearnedLibrary(root: temp.url)
        var profile = BrandProfile(name: "Contributor")
        profile.learnedSharing.deviceNickname = "Studio"
        profile.houseStyle = "Open with action"
        let build = try LearnedDocumentBuilder.build(profile: profile)
        try LearnedLibrary(root: temp.url, profile: "Brand A").install(build.document, frames: [:])
        #expect(LearnedLibrary(root: temp.url, profile: "Brand A").documents().count == 1)
        #expect(LearnedLibrary(root: temp.url, profile: "Brand B").documents().isEmpty)
        #expect(library.documents().map(\.contributor) == ["Contributor - Studio"])
        #expect(try library.decode(JSONEncoder().encode(build.document)).sections.first?.items.first?.text == "Open with action")
    }
}
