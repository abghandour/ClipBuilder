import Foundation
import Testing
@testable import Clip_Builder

struct CaptionStyleTests {
    @Test func legacyJSONDefaults() throws {
        let json = ##"{"font":"sans","color":"#ffffff","bg_on":false,"bg_color":"#000000","position":"bottom"}"##
        let style = try JSONDecoder().decode(CaptionStyle.self, from: Data(json.utf8))
        #expect(style.resolvedWordsPerPage == nil)
        #expect(style.resolvedHighlight == "none" && style.resolvedHighlightColor == "#ffd60a")
        #expect(style.resolvedEmphasis == "none" && style.resolvedEmphasisColor == "#ffd60a")
        #expect(!style.resolvedUppercase && style.resolvedWeight == "regular")
        #expect(style.resolvedStrokeWidth == 1 && !style.resolvedShadow && style.resolvedLetterSpacing == 0)
        #expect(style.resolvedAnimation == "none" && !style.resolvedEmoji && !style.resolvedSpeakerColors)
    }

    @Test func allSettingsRoundTripAndUseSnakeCase() throws {
        var style = CaptionStyle()
        style.wordsPerPage = 3
        style.highlight = "box"
        style.highlightColor = "#123456"
        style.emphasis = "both"
        style.emphasisColor = "#abcdef"
        style.uppercase = true
        style.weight = "black"
        style.strokeWidth = 4
        style.shadow = true
        style.letterSpacing = -1
        style.animation = "slide-up"
        style.emoji = true
        style.speakerColors = true
        style.highlightFont = "Impact"
        style.emphasisFont = "Futura"
        let data = try JSONEncoder().encode(style)
        let decoded = try JSONDecoder().decode(CaptionStyle.self, from: data)
        #expect(decoded == style)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["words_per_page"] as? Int == 3)
        #expect(object["speaker_colors"] as? Bool == true)
        #expect(object["letter_spacing"] as? Double == -1)
        #expect(object["highlight_font"] as? String == "Impact")
        #expect(style.resolvedHighlightFont == "Impact" && style.resolvedEmphasisFont == "Futura")
        style.highlightFont = ""
        style.emphasisFont = nil
        #expect(style.resolvedHighlightFont == style.font && style.resolvedEmphasisFont == style.font)
        style.emphasisColor = nil
        #expect(style.resolvedEmphasisColor == "#123456")
    }

    @Test func presetsAreIndependentCopies() {
        let first = CaptionPresets.styles
        let second = CaptionPresets.styles
        #expect(first.count == 6)
        #expect(first.map(\.style) == second.map(\.style))
        #expect(Set(first.map(\.id)).isDisjoint(with: second.map(\.id)))
    }
}
