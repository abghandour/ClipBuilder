import Foundation
import Testing
@testable import Clip_Builder

@Suite("Brand profile decoding")
struct BrandProfileTests {
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
