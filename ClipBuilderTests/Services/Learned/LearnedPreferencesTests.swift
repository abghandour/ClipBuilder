import Foundation
import Testing
@testable import Clip_Builder

struct LearnedPreferencesTests {
    @Test func roundTripAndDefaults() throws {
        var profile = BrandProfile(name: "Brand")
        profile.learnedSharing.deviceNickname = "Studio"
        let document = try LearnedDocumentBuilder.build(profile: profile).document
        #expect(document.contributor == "Brand - Studio")
        #expect(document.sections.filter(\.enabled).map(\.kind) == [.style, .taste, .lessons, .vocabulary, .benchmarks])
        #expect(try JSONDecoder().decode(LearnedPreferences.self, from: JSONEncoder().encode(document)) == document)
        #expect(LearnedPreferences.stableID("original") == LearnedPreferences.stableID("original"))
        #expect(try JSONDecoder().decode(BrandProfile.self, from: JSONEncoder().encode(profile)).learnedSharing == profile.learnedSharing)
    }
}
