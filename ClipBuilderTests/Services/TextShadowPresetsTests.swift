import Foundation
import Testing
@testable import Clip_Builder

struct TextShadowPresetsTests {
    @Test func presetsHaveUniqueNamesAndValidStyles() {
        let names = TextShadowPresets.all.map(\.name)
        #expect(Set(names).count == names.count)
        for preset in TextShadowPresets.all {
            #expect(preset.shadow.shadowOn == true)
            #expect(TextDecor.shadowStyles.contains(preset.shadow.shadowStyle ?? ""), "\(preset.name)")
            #expect(preset.help.count > 20, "\(preset.name)")
        }
    }

    @Test func applyTouchesOnlyShadowFields() throws {
        var stored = TextDecor(color: "#ff0000", strokeOn: true, strokeWidth: 3, bgOn: true, bgColor: "#00ff00")
        stored.shadowOn = false
        let preset = try #require(TextShadowPresets.all.first { $0.name == "Retro 3D" })
        let applied = TextShadowPresets.apply(preset, to: stored)
        #expect(applied.color == "#ff0000" && applied.strokeWidth == 3 && applied.bgColor == "#00ff00")
        #expect(applied.shadowOn == true && applied.shadowStyle == "extrude" && applied.shadowX == 0.06)
        #expect(TextShadowPresets.matching(applied)?.name == "Retro 3D")
        var nudged = applied
        nudged.shadowX = 0.2
        #expect(TextShadowPresets.matching(nudged) == nil)
    }

    @Test func everyPresetRoundTripsThroughMatching() {
        for preset in TextShadowPresets.all {
            #expect(TextShadowPresets.matching(TextShadowPresets.apply(preset, to: nil))?.name == preset.name, "\(preset.name)")
        }
    }
}
