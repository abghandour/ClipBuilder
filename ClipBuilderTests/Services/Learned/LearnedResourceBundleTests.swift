import Foundation
import Testing
@testable import Clip_Builder

struct LearnedResourceBundleTests {
    @Test func packAndImportUseSameDocumentAndMerge() throws {
        let bundle = try TempDirectory()
        let target = try TempDirectory()
        var profile = BrandProfile(name: "Team")
        profile.learnedSharing.deviceNickname = "Studio"
        profile.tasteRubric = "Action"
        profile.tasteExemplarFrames = ["injected.jpg"]
        profile.socials["instagram"] = SocialSlot(handle: "secret_handle", cookies: "secret_cookie")
        let build = try LearnedDocumentBuilder.build(profile: profile,
            readFrame: { _ in Data([0xff, 0xd8, 0xff, 0xd9]) })
        #expect(try LearnedResourceBundle.pack([build], root: bundle.url) == 2)
        let library = LearnedLibrary(root: target.url)
        #expect(try LearnedResourceBundle.unpack(root: bundle.url, library: library) == 1)
        let imported = try #require(library.documents().first)
        #expect(imported == (try LearnedRedaction.apply(build.document, publishing: true)))
        let frame = try #require(imported.frameNames.first)
        #expect(try Data(contentsOf: target.url.appendingPathComponent(frame)) == Data([0xff, 0xd8, 0xff, 0xd9]))
        let local = try LearnedDocumentBuilder.build(profile: BrandProfile(name: "Local")).document
        #expect(LearnedMerge.merge(local: local, contributors: [imported]).contains { $0.origin == "Team - Studio" })
    }
}
