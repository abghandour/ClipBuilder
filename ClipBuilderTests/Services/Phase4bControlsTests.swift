import Foundation
import Testing
@testable import Clip_Builder

@Suite("Shared picture drawing labels and pause preferences")
struct Phase4bControlsTests {
    @Test func drawingMenuUsesSingularAndFlooredSeconds() {
        let one = Telestration(time: 12.5, figures: [.init()])
        let two = Telestration(time: 59.99, figures: [.init(), .init()])
        #expect(TelestrationSource.drawingLabel(one) == "0:12 · 1 figure")
        #expect(TelestrationSource.drawingLabel(two) == "0:59 · 2 figures")
        #expect(TelestrationSource.drawingTime(60) == "1:00")
    }

    @Test func presetAndAssistantUpdatesRememberPositiveSeconds() throws {
        let suite = "Phase4bControlsTests.presets.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        StrikePausePreference.setActive(0.8, defaults: defaults)
        AISettingsPreferences.write(["strikeImpactFreeze": .number(1)], kind: .wizard,
            defaults: defaults)
        AISettingsPreferences.write(["strikeImpactFreeze": .number(0)], kind: .wizard,
            defaults: defaults)
        let reopened = try #require(UserDefaults(suiteName: suite))
        let on = StrikePausePreference.toggled(true,
            active: reopened.double(forKey: "wizard.strikeImpactFreeze"),
            remembered: reopened.double(forKey: "wizard.strikeImpactFreezeSeconds"))
        #expect(abs(on.active - 1) < 1e-9)
        #expect(abs(reopened.double(forKey: "wizard.strikeImpactFreeze")) < 1e-9)
        StrikePausePreference.setActive(on.active, defaults: reopened)
        AISettingsPreferences.write(["strikeImpactFreeze": .number(1.4)], kind: .wizard,
            defaults: reopened, recordSnapshot: false)
        #expect(abs(reopened.double(forKey: "wizard.strikeImpactFreezeSeconds") - 1.4) < 1e-9)
    }

    @Test func sameFilePicturesHaveAreaNames() throws {
        let scene = Fixtures.scene(start: 10, end: 20)
        var clip = Fixtures.planClip(start: 10, end: 14)
        clip.layout = "50-50 Horizontal"
        clip.screenCrop = "50-50 Horizontal/Top"
        clip.areaClips = [.init(area: "Bottom", sceneID: scene.id, start: 10, end: 14)]
        let sources = TelestrationSource.companions(clip: clip, sceneMap: [scene.id: scene])
        let bottom = try #require(sources.first)
        var top = bottom
        top.areaName = bottom.mainAreaName
        #expect(top.menuName == "\(scene.videoFilename) (Top)")
        #expect(bottom.menuName == "\(scene.videoFilename) (Bottom)")
        #expect(Set([top, bottom]).count == 2)
        top.areaName = nil
        #expect(top.menuName == scene.videoFilename)
    }

    @Test func wizardRemembersAcrossOffAndPreferenceReload() throws {
        let suite = "Phase4bControlsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let off = StrikePausePreference.toggled(false, active: 1, remembered: 0.8)
        defaults.set(off.active, forKey: "wizard.strikeImpactFreeze")
        defaults.set(off.remembered, forKey: "wizard.strikeImpactFreezeSeconds")
        let reopened = try #require(UserDefaults(suiteName: suite))
        #expect(reopened.double(forKey: "wizard.strikeImpactFreeze") == 0)
        let on = StrikePausePreference.toggled(true, active: reopened.double(forKey: "wizard.strikeImpactFreeze"),
            remembered: reopened.double(forKey: "wizard.strikeImpactFreezeSeconds"))
        #expect(on.active == 1 && on.remembered == 1)
        #expect(StrikePausePreference.toggled(true, active: 0, remembered: 0).active == StrikeHighlightRules.impactHold)
        #expect(StrikePausePreference.seconds(.nan) == StrikeHighlightRules.impactHold)
    }

    @Test func expressKeepsSecondsWhileOffAndAfterDecode() throws {
        var settings = MiniWizardSettings()
        settings.resolvedPauseOnContact = true
        settings.resolvedPauseOnContactSeconds = 1
        settings.resolvedPauseOnContact = false
        let encoded = try JSONEncoder().encode(settings)
        var reopened = try JSONDecoder().decode(MiniWizardSettings.self, from: encoded)
        #expect(!reopened.resolvedPauseOnContact && reopened.resolvedPauseOnContactSeconds == 1)
        reopened.resolvedPauseOnContact = true
        #expect(reopened.resolvedPauseOnContactSeconds == 1)
    }
}
