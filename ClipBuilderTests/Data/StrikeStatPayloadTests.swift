import Foundation
import Testing
@testable import Clip_Builder

@Suite("Strike stat timeline payload")
struct StrikeStatPayloadTests {
    @Test func payloadRoundTripAndOldTimelineJSON() throws {
        var item = TextOverlayItem(text: "Counts")
        item.stat = StrikeStatPayload(kind: .grapplingCard, sourceVideoID: 1, sourceTime: 3,
                                     values: .init(fighters: [.init(key: "a", name: "Alice", strikes: 4)]),
                                     states: [.scored], unit: .kmh, scope: .init(start: 2, end: 6))
        let decoded = try JSONDecoder().decode(TextOverlayItem.self, from: JSONEncoder().encode(item))
        #expect(decoded.stat == item.stat)
        let legacy = try JSONDecoder().decode(TextOverlayItem.self, from: Data(#"{"text":"old","start_time":0,"end_time":3}"#.utf8))
        #expect(legacy.stat == nil)
    }

    @Test func sourceBindingHandlesTrimSpeedRepeatsAndMissingSource() {
        let clip = Fixtures.timelineClip(sourceStart: 2, duration: 4, startTime: 10, speed: 0.5)
        var repeatClip = clip; repeatClip.uid = UUID(); repeatClip.startTime = 20
        var item = TextOverlayItem(text: "Card", startTime: 0, endTime: 1)
        item.stat = StrikeStatPayload(kind: .roundCard, sourceVideoID: 1, sourceTime: 3)
        let mapped = StrikeStatSourceBinding.mapped(item, clips: [clip, repeatClip], scenes: [Fixtures.scene()], videos: [])
        #expect(mapped.map(\.startTime) == [12, 22])
        #expect(mapped.map(\.endTime) == [14, 24])
        item.stat?.sourceTime = 7
        #expect(StrikeStatSourceBinding.mapped(item, clips: [clip], scenes: [Fixtures.scene()], videos: []).isEmpty)
    }

    @Test func editingTextDetachesBadgeAndDesign() {
        var original = TextOverlayItem(text: "AI-scored · 2 takedowns")
        original.stat = StrikeStatPayload(kind: .grapplingCard)
        original.design = "grapplingCard"
        var edited = original; edited.text = "AI-scored · 3 takedowns"
        StrikeStatSourceBinding.detachAfterTextEdit(&edited, previous: original)
        #expect(edited.stat == nil && edited.design == "tag" && !edited.text.contains("AI-scored"))
        var styled = original; styled.fontsize = 50
        StrikeStatSourceBinding.detachAfterTextEdit(&styled, previous: original)
        #expect(styled.stat == original.stat)
    }

    @Test func lookOptionsSurviveCopiedRunAndLegacyJSON() throws {
        var options = WizardOptions()
        options.strikeStats = true; options.strikeUnits = "mph"
        options.strikeGrapplingCard = true; options.strikeRoundCard = false; options.strikeSpeedCallouts = false
        let restored = try JSONDecoder().decode(WizardOptions.self, from: JSONEncoder().encode(options))
        #expect(restored.strikeStats == true && restored.strikeUnits == "mph" && restored.strikeRoundCard == false)
        let step2 = try JSONDecoder().decode(WizardStep2Options.self, from: JSONEncoder().encode(options.step2))
        let merged = WizardOptions.merge(step1: options.step1, step2: step2)
        #expect(merged.strikeStats == true && merged.strikeUnits == "mph" && merged.strikeRoundCard == false)
        #expect(try JSONDecoder().decode(WizardOptions.self, from: Data("{}".utf8)).strikeStats == nil)
    }
    @Test func copiedPreferencesIncludeStrikeStats() throws {
        let suite = "StrikeStats-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        AISettingsPreferences.write(["strikeStats": .bool(true), "strikeUnits": .string("mph"),
                                     "strikeGrapplingCard": .bool(false), "strikeRoundCard": .bool(true),
                                     "strikeSpeedCallouts": .bool(false)], kind: .wizard, scopes: [.options], defaults: defaults)
        #expect(defaults.bool(forKey: "wizard.strikeStats"))
        #expect(defaults.string(forKey: "wizard.strikeUnits") == "mph")
        #expect(!defaults.bool(forKey: "wizard.strikeGrapplingCard"))
        #expect(defaults.bool(forKey: "wizard.strikeRoundCard"))
    }

}
