import Foundation
import Testing
@testable import Clip_Builder

@Suite("Wizard Express extras")
struct WizardExpressExtrasTests {
    private func defaults() -> UserDefaults {
        let suite = "WizardExpressExtrasTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func extrasReadIntoOptionsOnlyWhenTheyApply() {
        let d = defaults()
        var options = WizardOptions()
        options.includeWatermark = true
        options.includeIntroBumper = true
        options.includeOutroBumper = false
        d.set(" fadeblack ", forKey: WizardExpressExtras.transitionChoiceKey)
        d.set("vintage", forKey: WizardExpressExtras.lookPresetKey)
        d.set(0.4, forKey: WizardExpressExtras.lookIntensityKey)
        d.set(true, forKey: WizardExpressExtras.overlayEnabledKey)
        d.set("Lower Third", forKey: WizardExpressExtras.overlayTemplateKey)
        d.set(2.5, forKey: WizardExpressExtras.overlayStartKey)
        d.set(0, forKey: WizardExpressExtras.overlayDurationKey)
        d.set("Hook\nSecond", forKey: WizardExpressExtras.overlayTextsKey)
        d.set("Mark", forKey: WizardExpressExtras.watermarkOverlayKey)
        d.set(0.3, forKey: WizardExpressExtras.watermarkOpacityKey)
        d.set("bumpers/intro.mp4", forKey: WizardExpressExtras.introBumperKey)
        d.set("bumpers/outro.mp4", forKey: WizardExpressExtras.outroBumperKey)
        WizardExpressExtras.apply(to: &options, defaults: d) { libraryPath, placement in
            placement == .intro && libraryPath == "bumpers/intro.mp4" ? "/Users/me/intro.mp4" : nil
        }
        #expect(options.transitionChoice == "fadeblack")
        #expect(options.lookPreset == "vintage" && options.lookIntensity == 0.4)
        #expect(options.fixedOverlayTemplate == "Lower Third" && options.fixedOverlayStart == 2.5)
        #expect(options.fixedOverlayDuration == nil && options.fixedOverlayTexts == ["Hook", "Second"])
        #expect(options.watermarkOverlayTemplate == "Mark" && options.watermarkOpacity == 0.3)
        #expect(options.introBumperPath == "/Users/me/intro.mp4" && options.outroBumperPath == nil)
        #expect(WizardEngine.lookEffect(for: options) == EffectSpec(preset: "vintage", intensity: 0.4))

        // Off switches clear the dependent fields; a clamped intensity; no watermark, no design.
        d.set(false, forKey: WizardExpressExtras.overlayEnabledKey)
        d.set(3.0, forKey: WizardExpressExtras.lookIntensityKey)
        d.set(5, forKey: WizardExpressExtras.overlayDurationKey)
        options.includeWatermark = false
        WizardExpressExtras.apply(to: &options, defaults: d)
        #expect(options.fixedOverlayTemplate == nil && options.fixedOverlayTexts == nil)
        #expect(options.lookIntensity == 1)
        #expect(options.watermarkOverlayTemplate == nil && options.watermarkOpacity == nil)
        #expect(options.introBumperPath == nil)
        d.set("", forKey: WizardExpressExtras.transitionChoiceKey)
        d.set("none", forKey: WizardExpressExtras.lookPresetKey)
        WizardExpressExtras.apply(to: &options, defaults: d)
        #expect(options.transitionChoice == nil && options.lookPreset == nil && options.lookIntensity == nil)
        #expect(WizardExpressExtras.splitTexts(nil).isEmpty && WizardExpressExtras.splitTexts("") .isEmpty)
        #expect(WizardExpressExtras.joinedTexts(["a", "b"]) == "a\nb")
    }

    @Test func lookIntensitySurvivesTheOptionsRoundTrip() throws {
        var options = WizardOptions()
        options.lookPreset = "bw"
        options.lookIntensity = 0.5
        let decoded = try JSONDecoder().decode(WizardOptions.self, from: JSONEncoder().encode(options))
        #expect(decoded.lookIntensity == 0.5)
        let merged = WizardOptions.merge(step1: options.step1, step2: options.step2, base: WizardOptions())
        #expect(merged.lookIntensity == 0.5 && merged.lookPreset == "bw")
        #expect(try JSONDecoder().decode(WizardOptions.self, from: Data(#"{"lookPreset":"bw"}"#.utf8)).lookIntensity == nil)
    }
}
