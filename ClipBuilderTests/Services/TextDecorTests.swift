import Foundation
import Testing
@testable import Clip_Builder

struct TextDecorTests {
    @Test func everyFieldRoundTripsAndMerges() throws {
        let json = ##"{"color":"#123456","gradientOn":true,"fillEndColor":"#abcdef","fillAngle":90,"textOpacity":0.6,"weight":"black","italic":true,"underline":true,"strikethrough":true,"casing":"title","size":1.3,"letterSpacing":2,"lineHeight":1.4,"strokeOn":true,"strokeWidth":3,"strokeColor":"#012345","strokeOpacity":0.4,"shadowOn":true,"shadowColor":"#fedcba","shadowOpacity":0.3,"shadowX":0.2,"shadowY":-0.3,"shadowBlur":0.4,"shadowStyle":"extrude","bgOn":true,"bgColor":"#020304","bgOpacity":0.2,"bgRadius":12,"bgPaddingX":0.3,"bgPaddingY":0.4,"bgPerLine":true,"borderOn":true,"borderWidth":4,"borderColor":"#fefefe","alignment":"trailing","maxWidthFrac":0.6,"underlineColor":"#ffffff","underlineThickness":0.08}"##
        let all = try JSONDecoder().decode(TextDecor.self, from: Data(json.utf8))
        #expect(try JSONDecoder().decode(TextDecor.self, from: JSONEncoder().encode(all)) == all)
        #expect(TextDecor().merged(over: all) == all)
        var explicit = TextDecor()
        explicit.italic = false
        explicit.strokeWidth = 0
        let merged = explicit.merged(over: all)
        #expect(merged.italic == false && merged.strokeWidth == 0 && merged.shadowX == 0.2)
        #expect(TextDecor().resolved().casing == "asWritten")
        #expect(TextDecor().resolved().shadowStyle == "soft")
        #expect(TextDecor(shadowStyle: "bogus").resolved().shadowStyle == "soft")
    }

    @Test func captionStatePrecedenceAndLegacyCompatibility() {
        var style = CaptionStyle()
        style.letterSpacing = 1
        style.decor = TextDecor(letterSpacing: 2)
        style.text = CaptionWordDecor(decor: TextDecor(letterSpacing: 3))
        style.highlightDecor = CaptionWordDecor(decor: TextDecor(letterSpacing: 4))
        #expect(style.resolvedTextDecor(for: .highlight).letterSpacing == 4)
        #expect(style.resolvedTextDecor(for: .emphasis).letterSpacing == 3)
        style.text?.decor = nil
        #expect(style.resolvedTextDecor(for: .emphasis).letterSpacing == 2)
        style.decor = nil
        #expect(style.resolvedTextDecor(for: .emphasis).letterSpacing == 1)
        style.bgOn = true
        #expect(style.legacyDecor.strokeOn == false)
        style.decor = TextDecor(strokeOn: true)
        #expect(style.resolvedTextDecor(for: .text).strokeOn == true)
    }

    @Test func tagLineInheritsTagAndOverridesLocally() {
        var line = TagLineStyle(color: "#111111")
        let base = TextDecor(color: "#222222", shadowOn: true)
        #expect(line.resolvedTextDecor(over: base).color == "#222222")
        line.decor = TextDecor(color: "#333333", shadowOn: false)
        #expect(line.resolvedTextDecor(over: base).color == "#333333")
        #expect(line.resolvedTextDecor(over: base).shadowOn == false)
    }

    @Test func sharedStyleUpdatesEverySurfaceAndFont() {
        var shared = NamedTextStyle(name: "Brand", decor: TextDecor(color: "#ff0000"), fontFamily: "Georgia")
        var caption = CaptionStyle(); caption.sharedStyleID = shared.id.uuidString
        var tag = TagStyle(); tag.sharedStyleID = shared.id.uuidString
        var item = TextOverlayItem(text: "Text"); item.sharedStyleID = shared.id.uuidString
        for color in ["#ff0000", "#00ff00"] {
            shared.decor.color = color
            #expect(caption.applyingSharedStyle([shared]).resolvedTextDecor(for: .text).color == color)
            #expect(tag.applyingSharedStyle([shared]).name.resolvedTextDecor(over: shared.decor).color == color)
            #expect(item.applyingSharedStyle([shared]).resolvedTextDecor.color == color)
            #expect(caption.applyingSharedStyle([shared]).font == "Georgia")
            #expect(tag.applyingSharedStyle([shared]).name.font == "Georgia")
            #expect(item.applyingSharedStyle([shared]).fontfamily == "Georgia")
        }
        caption.fontOverride = "Menlo"
        #expect(caption.applyingSharedStyle([shared]).font == "Menlo")
        #expect(caption.applyingSharedStyle([]).decor == nil)
    }

    @Test func bindingReadsInheritedAndWritesOnlySelectedField() {
        let inherited = TextDecor(color: "#123456", italic: true, shadowOn: true)
        #expect(TextDecorEditing.value(\.italic, stored: nil, inherited: inherited) == true)
        let stored = TextDecorEditing.setting(\.italic, to: false, in: nil)
        #expect(stored.italic == false && stored.color == nil && stored.shadowOn == nil)
        let reset = TextDecorEditing.setting(\.italic, to: nil, in: stored)
        #expect(TextDecorEditing.value(\.italic, stored: reset, inherited: inherited) == true)
    }

    @Test func casingAfterMarkupAndTitleStopWords() {
        #expect(TextCasing.apply("the art of a win and the loss", casing: "title") == "The Art of a Win and the Loss")
        #expect(TextCasing.apply("AbC", casing: "asWritten") == "AbC")
        #expect(TextCasing.apply("AbC", casing: "lower") == "abc")
        var item = TextOverlayItem(text: "*the art* of a win")
        item.decor = TextDecor(casing: "title")
        let words = TextOverlayRenderer.parseMarkup(item.textLayoutItem.text)
        #expect(words[0].highlighted && words[1].highlighted)
        #expect(TextOverlayRenderer.plainText(words) == "The Art of a Win")
    }

    @Test func gradientCanBeDisabledWithoutChangingInheritedColors() {
        let base = TextDecor(fillEndColor: "#ff0000")
        var own = TextDecor(); own.gradientOn = false
        #expect(own.resolved(over: base).fillEndColor == nil)
        #expect(base.fillEndColor == "#ff0000")
    }

    @Test func profileTimelineAndTemplateRoundTrip() throws {
        let old = try Data(contentsOf: TextStyleLegacyFixtureTests.fixtures.appendingPathComponent("profile-1.128.json"))
        var profile = try JSONDecoder().decode(BrandProfile.self, from: old)
        #expect(profile.textStyles == nil && profile.captions.decor == nil)
        let timeline = try JSONDecoder().decode(TimelineDocument.self, from: Data(contentsOf: TextStyleLegacyFixtureTests.fixtures.appendingPathComponent("timeline-1.128.json")))
        #expect(timeline.textOverlays.first?.decor == nil)
        let named = NamedTextStyle(name: "Look", decor: TextDecor(borderOn: true), fontFamily: "Menlo")
        profile.textStyles = [named]
        #expect(try JSONDecoder().decode(BrandProfile.self, from: JSONEncoder().encode(profile)).textStyles == [named])
        var item = timeline.textOverlays[0]
        item.decor = named.decor; item.sharedStyleID = named.id.uuidString
        var composition = OverlayComposition(); composition.texts = [item]
        let restored = try JSONDecoder().decode(OverlayComposition.self, from: JSONEncoder().encode(composition))
        #expect(restored.texts[0].decor == item.decor && restored.texts[0].sharedStyleID == item.sharedStyleID)
        let wire = try TeamProfileDocument.encode(profile)
        #expect(try TeamProfileDocument.applying(wire, to: BrandProfile(name: "Other")).textStyles == [named])
    }
}

extension TextDecorTests {
    @Test func overlayTemplateFileKeepsDecorAndSharedReference() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var item = TextOverlayItem(text: "*Shared* look")
        item.decor = TextDecor(fillEndColor: "#ff0000", letterSpacing: 3, bgRadius: 20, borderOn: true)
        item.sharedStyleID = UUID().uuidString
        var composition = OverlayComposition()
        composition.texts = [item]
        let url = directory.appendingPathComponent("overlay-template.json")
        try JSONEncoder().encode(composition).write(to: url, options: .atomic)
        let restored = try JSONDecoder().decode(OverlayComposition.self, from: Data(contentsOf: url))
        #expect(restored.texts[0].decor == item.decor)
        #expect(restored.texts[0].sharedStyleID == item.sharedStyleID)
        #expect(restored.texts[0].text == item.text)
    }
}

extension TextDecorTests {
    @Test func captionPageBorderInheritsCurrentTextFill() {
        var style = CaptionStyle()
        style.text = CaptionWordDecor(decor: TextDecor(color: "#ff0000", borderOn: true))
        #expect(style.pageDecor.borderColor == "#ff0000")
        style.text?.decor?.borderColor = "#00ff00"
        #expect(style.pageDecor.borderColor == "#00ff00")
    }
}
