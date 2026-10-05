import Foundation
import Testing
@testable import Clip_Builder

@Suite("Tag styles")
struct TagStyleTests {
    @Test func oldProfilesAndPartialStylesDecode() throws {
        let profile = try JSONDecoder().decode(BrandProfile.self, from: Data("{}".utf8))
        #expect(profile.tagStyle == nil && profile.tagStyles == nil)
        #expect(profile.tagStyle(id: nil) == TagStyle())
        let style = try JSONDecoder().decode(TagStyle.self, from: Data("{}".utf8))
        #expect(style == TagStyle())
        #expect(style.name.field == "Name" && style.description.field == "Role")
        #expect(style.description.scale == 0.72 && style.bgOn)
        let line = try JSONDecoder().decode(TagLineStyle.self, from: Data("{}".utf8))
        #expect(line.font == nil && line.underlineThickness == 0.06)
        #expect(try JSONDecoder().decode(TagImage.self, from: Data("{}".utf8)).width == 0.25)
    }

    @Test func profileAndOverlayRoundTripAndUnknownIDsUseDefault() throws {
        var style = TagStyle()
        style.description.field = "MMA record"
        style.description.underline = true
        style.images = [TagImage(path: "/tmp/logo.png", x: -0.3, y: 1.2)]
        let named = NamedTagStyle(name: "Fight", style: style)
        var profile = Fixtures.brand()
        profile.tagStyles = [named]
        let decoded = try JSONDecoder().decode(BrandProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded.tagStyle(id: named.id.uuidString) == style)
        #expect(decoded.tagStyle(id: "deleted") == TagStyle())
        var item = TextOverlayItem(text: "Alex\nFighter")
        item.design = "nameTag"
        item.tagStyle = style
        let restored = try JSONDecoder().decode(TextOverlayItem.self, from: JSONEncoder().encode(item))
        #expect(restored.tagStyle == style)
        item.tagStyle = nil
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        #expect(json["tag_style"] == nil)
    }
}
