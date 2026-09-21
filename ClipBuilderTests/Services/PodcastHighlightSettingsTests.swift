import Foundation
import Testing
@testable import Clip_Builder

@Suite("Podcast highlight settings and requests")
struct PodcastHighlightSettingsTests {
    @Test func defaultClampAndRoundTrip() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(PodcastSettings.self, from: Data("{}".utf8)).highlightMaxSeconds == 30)
        for (raw, expected) in [(1, 5), (200, 120), (25, 25)] {
            let settings = try decoder.decode(PodcastSettings.self, from: Data("{\"highlight_max_seconds\":\(raw)}".utf8))
            #expect(settings.highlightMaxSeconds == Double(expected))
            let data = try JSONEncoder().encode(settings)
            #expect(String(decoding: data, as: UTF8.self).contains("highlight_max_seconds"))
            #expect(try decoder.decode(PodcastSettings.self, from: data).highlightMaxSeconds == Double(expected))
        }
        var settings = PodcastSettings()
        settings.highlightMaxSeconds = 400
        #expect(settings.highlightMaxSeconds == 120)
        settings.highlightMaxSeconds = .nan
        #expect(settings.highlightMaxSeconds == 30)
    }

    @MainActor @Test func requests() {
        let context = ParserContext(library: ScriptFixtures.library(), model: ScriptFixtures.model())
        let parser = BuilderRequestParser()
        #expect(parser.parse("podcast highlights, 25 seconds max", context: context) == .podcastHighlights(maxSeconds: 25))
        #expect(parser.parse("make podcast highlights", context: context) == .podcastHighlights(maxSeconds: nil))
        #expect(parser.parse("make podcast highlights under 20s", context: context) == .podcastHighlights(maxSeconds: 20))
        #expect(parser.podcastHighlights("make podcast highlights and delete all clips") == nil)
        #expect(parser.parse("podcast highlights for Modestino, 25 seconds max", context: context) == .podcastHighlights(maxSeconds: 25))
        #expect(parser.podcastHighlights("don't make podcast highlights") == nil)
        #expect(parser.podcastHighlights("podcast highlights, 200 seconds max") == .podcastHighlights(maxSeconds: 120))
    }

    @Test func cameraAndBRollOptionsArePlainCodableValues() throws {
        let defaults = try JSONDecoder().decode(WizardOptions.self, from: Data("{}".utf8))
        #expect(defaults.highlightFraming == nil && defaults.useBRoll && defaults.brollInstructions.isEmpty)
        for kind in CropRecipe.Kind.allCases {
            var options = WizardOptions()
            options.highlightFraming = kind
            options.useBRoll = false
            options.brollInstructions = "Use fight footage; never cover the host."
            let data = try JSONEncoder().encode(options)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["highlightFraming"] as? String == kind.rawValue)
            #expect(object["useBRoll"] as? Bool == false)
            #expect(object["brollInstructions"] as? String == options.brollInstructions)
            #expect(!object.keys.contains { $0.hasPrefix("_") || $0.hasPrefix("wizard.") })
            let restored = try JSONDecoder().decode(WizardOptions.self, from: data)
            #expect(restored.highlightFraming == kind && !restored.useBRoll)
            #expect(restored.brollInstructions == options.brollInstructions)
        }
        let restored = try JSONDecoder().decode(WizardOptions.self, from: JSONEncoder().encode(defaults))
        #expect(restored.highlightFraming == nil && restored.useBRoll)
    }


    @MainActor @Test func builderAcceptsHighlightControlsWithoutSwallowingOtherEdits() {
        let parser = BuilderRequestParser()
        #expect(parser.podcastHighlights("podcast highlights, camera: grid, no b-roll") == .podcastHighlights(maxSeconds: nil))
        #expect(parser.podcastHighlights("podcast highlights, talker and the rest, without b-roll") == .podcastHighlights(maxSeconds: nil))
        #expect(parser.podcastHighlights("podcast highlights, camera: grid, delete all clips") == nil)
    }


    @MainActor @Test func aiFramingExportsAsNullAndSettingsReplay() throws {
        let suite = "PodcastControls-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("", forKey: "wizard.highlightFraming")
        defaults.set(false, forKey: "wizard.useBRoll")
        defaults.set("Only reactions", forKey: "wizard.brollInstructions")
        let exported = AISettingsPreferences.wizard(defaults: defaults, profile: Fixtures.brand())
        #expect(exported["highlightFraming"] == .null)
        let data = try JSONEncoder().encode(exported)
        let options = try JSONDecoder().decode(WizardOptions.self, from: data)
        #expect(options.highlightFraming == nil && !options.useBRoll && options.brollInstructions == "Only reactions")
        defaults.set("grid", forKey: "wizard.highlightFraming")
        let fixed = AISettingsPreferences.wizard(defaults: defaults, profile: Fixtures.brand())
        #expect(fixed["highlightFraming"] == .string("grid"))
        defaults.set(true, forKey: "wizard.useBRoll")
        defaults.set("", forKey: "wizard.brollInstructions")
        AISettingsPreferences.write(exported, kind: .wizard, scopes: [.options, .prompts], defaults: defaults)
        #expect(defaults.string(forKey: "wizard.highlightFraming") == nil)
        #expect(!defaults.bool(forKey: "wizard.useBRoll"))
        #expect(defaults.string(forKey: "wizard.brollInstructions") == "Only reactions")
    }
}
