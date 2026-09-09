import Foundation
import Testing
@testable import Clip_Builder

struct LearnedRedactionTests {
    @Test func goldenAllowList() throws {
        // Closed-schema golden oracle, independent of the production allow lists.
        var profile = BrandProfile(name: "Brand")
        profile.learnedSharing.deviceNickname = "Studio"
        profile.socials = ["instagram": SocialSlot(handle: "private_handle", url: "https://private/source", cookies: "session-secret")]
        profile.sourceFolder = "/Users/private/Input"
        profile.outputFolder = "/Users/private/Output"
        profile.logoPath = "/Users/private/logo.png"
        profile.houseStyle = "Strong openings\nCookie: session-secret\nig_comments private_handle"
        profile.tasteRubric = "Keep action https://private/source /Users/private/movie.mp4 @private_handle"
        profile.tasteExemplarFrames = ["/Users/private/exemplar.jpg"]
        profile.learnedSharing.enabled["people"] = true
        let person = PersonRecord(id: 1, key: "person", name: "Trainer", descriptor: "Coach",
                                  avatarVideoID: 4, avatarTime: 1, avatarBoxJSON: "face-box-secret")
        let result = try LearnedDocumentBuilder.build(profile: profile, people: [person],
            now: Date(timeIntervalSince1970: 0), readFrame: { _ in Data([0xff, 0xd8, 0xff, 0xd9]) })
        let goldenURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/LearnedRedaction.golden.json")
        let golden = try JSONDecoder().decode(LearnedPreferences.self, from: Data(contentsOf: goldenURL))
        #expect(result.document == golden)
        // Every profile field is classified as exported or private. Adding a
        // new field fails this independent oracle until reviewed explicitly.
        let source = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        let classified: Set<String> = ["profile_name", "brand_name", "content_domain", "source_folder", "output_folder",
            "tag_schema", "socials", "captions", "logo_path", "accent_color", "tagline", "hashtags", "caption_languages",
            "default_render_settings", "default_pacing", "use_learned_editing_defaults", "learned_hook_style",
            "learned_layout_preference", "taste_rubric", "taste_exemplar_frames", "taste_categories", "house_style",
            "buzz_sources", "buzz_extra_sources", "taste_rubric_provenance", "house_style_provenance", "learned_sharing"]
        #expect(Set(source.keys).subtracting(classified).isEmpty)
        let data = try JSONEncoder().encode(result.document)
        let wire = String(decoding: data, as: UTF8.self)
        for secret in ["session-secret", "private_handle", "/Users/", "https:", "ig_", "face-box-secret", "avatar", "socials", "providerSettings", "onDeviceAgreement"] {
            #expect(!wire.contains(secret))
        }
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(root.keys) == ["version", "contributor", "sections"])
        for section in try #require(root["sections"] as? [[String: Any]]) {
            #expect(Set(section.keys) == ["kind", "enabled", "updatedAt", "evidence", "items"])
            for item in try #require(section["items"] as? [[String: Any]]) {
                #expect(Set(item.keys) == ["id", "field", "text", "pinned", "evidence", "updatedAt", "frames", "numbers"])
            }
        }
        #expect(result.document.sections.first { $0.kind == .style }?.items.first?.text == "Strong openings")
        #expect(result.document.frameNames.allSatisfy { $0.hasPrefix("learned/Brand - Studio/frames/") })
        var unclassified = root
        unclassified["futurePrivateSetting"] = "secret"
        #expect(throws: LearnedRedaction.Failure.self) {
            try LearnedRedaction.validateSchema(JSONSerialization.data(withJSONObject: unclassified))
        }
    }

    @Test func disabledSectionsAndTraversal() throws {
        var profile = BrandProfile(name: "Brand")
        profile.learnedSharing.enabled["style"] = false
        profile.houseStyle = "Local only"
        let local = try LearnedDocumentBuilder.build(profile: profile).document
        #expect(local.sections.first?.items.isEmpty == false)
        #expect(try LearnedRedaction.apply(local, publishing: true).sections.first?.items.isEmpty == true)
        #expect(!LearnedRedaction.isFrame("learned/Brand/frames/../../secret.jpg", contributor: "Brand"))
    }
}
