import Testing

@testable import Clip_Builder

struct TextLookSummaryTests {
    @Test func disabledEffectsSayOff() {
        let decor = TextDecor.defaults
        #expect(TextLookSummary.shadow(decor, stored: nil) == "Off")
        #expect(TextLookSummary.stroke(decor) == "Off")
        #expect(TextLookSummary.box(decor, perWord: true) == "Off")
        #expect(TextLookSummary.border(decor) == "Off")
    }

    @Test func inheritedShadowCountsOnlyLocalOverrides() throws {
        let retro = try #require(TextShadowPresets.all.first { $0.name == "Retro 3D" })
        let stored = TextDecor(shadowOn: true)
        let resolved = stored.resolved(over: retro.shadow)
        #expect(TextLookSummary.shadow(resolved, stored: stored) == "Retro 3D · 1 override")
        #expect(TextLookSummary.overrideCount(nil) == 0)
        #expect(TextLookSummary.overrideCount(TextDecor(italic: false, shadowX: 0)) == 2)
    }

    @Test func boxSummaryDescribesColorRadiusAndScope() {
        let decor = TextDecor(bgOn: true, bgColor: "#ffd60a", bgRadius: 8).resolved()
        #expect(TextLookSummary.box(decor, perWord: true) == "#FFD60A · radius 8 · per word")
        #expect(TextLookSummary.box(decor, perWord: false) == "#FFD60A · radius 8 · whole box")
        var lines = decor
        lines.bgPerLine = true
        #expect(TextLookSummary.box(lines, perWord: true) == "#FFD60A · radius 8 · per line")
    }

    @Test func resettingPageBoxPreservesUnrelatedTextValues() throws {
        let original = TextDecor(color: "#ff0000", bgOn: true, bgRadius: 8, borderOn: true)
        let reset = try #require(TextLookSummary.resetBox(in: original))
        #expect(reset.color == original.color)
        #expect(reset.bgOn == nil)
        #expect(reset.bgRadius == nil)
        #expect(reset.borderOn == nil)
    }
}
