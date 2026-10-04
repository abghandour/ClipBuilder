import Foundation
import Testing
@testable import Clip_Builder

@Suite("Brand profile decoding")
struct BrandProfileTests {
    @Test("Legacy profiles have no Mini instructions")
    func legacyMiniInstructions() throws {
        let profile = try JSONDecoder().decode(BrandProfile.self, from: Data(#"{"profile_name":"Legacy"}"#.utf8))
        #expect(profile.miniInstructions == nil)
    }

    @Test("Mini instructions round trip under the private profile key")
    func miniInstructions() throws {
        var profile = BrandProfile(name: "Mini")
        profile.miniInstructions = "Keep the complete answer.\nStart with the question."
        let data = try JSONEncoder().encode(profile)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["mini_instructions"] as? String == profile.miniInstructions)
        #expect(try JSONDecoder().decode(BrandProfile.self, from: data).miniInstructions == profile.miniInstructions)
    }

    @Test("Old profiles have no remembered Instagram publish account")
    func legacyInstagramPublishAccount() throws {
        let profile = try JSONDecoder().decode(BrandProfile.self, from: Data(#"{"profile_name":"Legacy"}"#.utf8))
        #expect(profile.instagramPublishAccount == nil)
    }

    @Test("Instagram publish account round trips with its profile key")
    func instagramPublishAccount() throws {
        var profile = BrandProfile(name: "Publish")
        profile.instagramPublishAccount = "podcast"
        let data = try JSONEncoder().encode(profile)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["instagram_publish_account"] as? String == "podcast")
        #expect(try JSONDecoder().decode(BrandProfile.self, from: data).instagramPublishAccount == "podcast")
    }
}

extension BrandProfileTests {
    @Test func namedCaptionStylesRoundTripAndResolve() throws {
        var profile = BrandProfile(name: "Captions")
        var style = CaptionStyle()
        style.font = "Menlo"
        style.alignment = "trailing"
        style.bgOn = true
        style.bgColor = "#102030"
        let named = NamedCaptionStyle(name: "Interview", style: style)
        profile.captionStyles = [named]
        let data = try JSONEncoder().encode(profile)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["caption_styles"] != nil)
        let decoded = try JSONDecoder().decode(BrandProfile.self, from: data)
        #expect(decoded.captionStyles == [named])
        #expect(decoded.captionStyle(id: named.id.uuidString) == style)
        #expect(decoded.captionStyle(id: UUID().uuidString) == decoded.captions)
        #expect(decoded.captionStyle(id: nil) == decoded.captions)
        #expect(decoded.captionStyle(id: "invalid") == decoded.captions)
        let old = try JSONDecoder().decode(BrandProfile.self, from: Data(#"{"profile_name":"Old"}"#.utf8))
        #expect(old.captionStyles == nil && old.captions.alignment == nil)
        #expect(try JSONDecoder().decode(CaptionStyle.self, from: Data("{}".utf8)).alignment == nil)
    }
}
