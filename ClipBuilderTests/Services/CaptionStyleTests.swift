import Foundation
import CoreText
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
        #expect(style.reveal == nil && style.revealMotion == nil)
        #expect(style.resolvedReveal == "none" && !style.resolvedRevealMotion)
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
        style.reveal = "word"
        style.revealMotion = true
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
        #expect(object["reveal"] as? String == "word")
        #expect(object["reveal_motion"] as? Bool == true)
        #expect(decoded.resolvedReveal == "word" && decoded.resolvedRevealMotion)
        #expect(style.resolvedHighlightFont == "Impact" && style.resolvedEmphasisFont == "Futura")
        style.highlightFont = ""
        style.emphasisFont = nil
        #expect(style.resolvedHighlightFont == style.font && style.resolvedEmphasisFont == style.font)
        style.emphasisColor = nil
        #expect(style.resolvedEmphasisColor == "#123456")
    }

    @Test func decorationsPreserveLegacyDefaultsAndInheritance() throws {
        var style = try JSONDecoder().decode(CaptionStyle.self, from: Data("{}".utf8))
        #expect(style.text == nil && style.highlightDecor == nil && style.emphasisDecor == nil && style.bgRadius == nil)
        for state in CaptionStyle.WordState.allCases {
            let decor = style.resolvedDecor(for: state)
            #expect(!decor.resolvedItalic && !decor.resolvedUnderline && !decor.resolvedStrikethrough)
            #expect(!decor.resolvedBackground && decor.resolvedRadius == 6)
            #expect(style.resolvedSize(for: state) == 49)
        }
        #expect(style.resolvedPageRadius == 49.0 / 6)
        style.text = CaptionWordDecor(italic: true, underline: true, size: 60)
        #expect(style.resolvedDecor(for: .highlight).resolvedItalic)
        style.highlightDecor = CaptionWordDecor(italic: false)
        #expect(!style.resolvedDecor(for: .highlight).resolvedItalic)
        #expect(style.resolvedDecor(for: .highlight).resolvedUnderline)
        #expect(style.resolvedSize(for: .highlight) == 60)
        style.highlight = "scale"
        #expect(abs(style.resolvedSize(for: .highlight) - 67.2) < 0.001)
        style.emphasisDecor = CaptionWordDecor(size: 200)
        #expect(style.resolvedSize(for: .emphasis) == 120)
    }

    @Test func unknownRevealAndNullSettingsUseLegacyDefaults() throws {
        let style = try JSONDecoder().decode(CaptionStyle.self, from: Data(#"{"reveal":"future-mode","reveal_motion":null}"#.utf8))
        #expect(style.resolvedReveal == "none" && !style.resolvedRevealMotion)
        let null = try JSONDecoder().decode(CaptionStyle.self, from: Data(#"{"reveal":null}"#.utf8))
        #expect(null.resolvedReveal == "none")
    }

    @Test func decorationRoundTrip() throws {
        var style = CaptionStyle()
        let decor = CaptionWordDecor(italic: true, underline: true, strikethrough: false,
                                    size: 72, bgOn: true, bgColor: "#123456", bgRadius: 20)
        style.text = decor
        style.highlightDecor = decor
        style.emphasisDecor = decor
        style.bgRadius = 32
        let data = try JSONEncoder().encode(style)
        #expect(try JSONDecoder().decode(CaptionStyle.self, from: data) == style)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["text_decor", "highlight_decor", "emphasis_decor"] {
            let encoded = try #require(object[key] as? [String: Any])
            #expect(encoded["bg_on"] as? Bool == true)
            #expect(encoded["bg_color"] as? String == "#123456")
            #expect(encoded["bg_radius"] as? Double == 20)
            #expect(encoded["strikethrough"] as? Bool == false)
        }
        #expect(object["bg_radius"] as? Double == 32)
    }

    @Test func presetsAreIndependentCopies() {
        let first = CaptionPresets.styles
        let second = CaptionPresets.styles
        #expect(first.count == 7)
        #expect(first.map(\.style) == second.map(\.style))
        #expect(Set(first.map(\.id)).isDisjoint(with: second.map(\.id)))
    }
}

extension CaptionStyleTests {
    @Test func fontOnlyEmphasisKeepsNormalSizeAndRoundTrips() throws {
        var style = CaptionStyle()
        style.emphasis = "font"
        style.emphasisFont = "Georgia"
        style.emphasisDecor = CaptionWordDecor(italic: true)
        #expect(style.resolvedEmphasis == "font")
        #expect(style.resolvedEmphasisFont == "Georgia")
        #expect(style.resolvedSize(for: .emphasis) == style.resolvedSize(for: .text))
        #expect(style.resolvedDecor(for: .emphasis).resolvedItalic)
        #expect(try JSONDecoder().decode(CaptionStyle.self, from: JSONEncoder().encode(style)) == style)
    }

    @Test func interviewSerifPresetMatchesTheReferenceStyle() throws {
        let style = try #require(CaptionPresets.styles.first { $0.name == "Interview Serif" }).style
        #expect(style.resolvedWeight == "bold" && style.resolvedWordsPerPage == 3)
        #expect(style.resolvedReveal == "word" && style.resolvedHighlight == "color")
        #expect(style.resolvedHighlightColor == "#e5322d" && style.resolvedEmphasis == "font")
        #expect(style.resolvedEmphasisFont == "Georgia" && style.resolvedDecor(for: .emphasis).resolvedItalic)
        #expect(!style.resolvedDecor(for: .text).resolvedItalic)
        #expect(style.position == "middle" && style.resolvedShadow && !style.bgOn && style.resolvedStrokeWidth == 0)
        #expect(style.resolvedSize(for: .emphasis) == style.resolvedSize(for: .text))
        #expect(try JSONDecoder().decode(CaptionStyle.self, from: JSONEncoder().encode(style)) == style)
    }
}


extension CaptionStyleTests {
    @Test func interviewSerifResolvesToAStockItalicFace() throws {
        let style = try #require(CaptionPresets.styles.first { $0.name == "Interview Serif" }).style
        let family = CTFontCreateWithName(style.resolvedEmphasisFont as CFString, 49, nil)
        #expect(CTFontCopyFamilyName(family) as String == "Georgia")
        let bold = try #require(CTFontCreateCopyWithSymbolicTraits(family, 49, nil, .traitBold, .traitBold))
        let italic = try #require(CTFontCreateCopyWithSymbolicTraits(bold, 49, nil, .traitItalic, .traitItalic))
        #expect(CTFontCopyFamilyName(italic) as String == "Georgia")
        #expect(CTFontGetSymbolicTraits(italic).contains(.traitItalic))
        #expect(CTFontGetSymbolicTraits(italic).contains(.traitBold))
    }
}
