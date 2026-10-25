import Foundation
import Testing
@testable import Clip_Builder

@Suite("Wizard mode")
struct WizardModeTests {
    @Test func modesHaveStableValuesLabelsAndSymbols() {
        #expect(WizardMode.allCases == [.express, .full])
        #expect(WizardMode.full.rawValue == "full")
        #expect(WizardMode.express.rawValue == "express")
        #expect(WizardMode.full.label == "Full")
        #expect(WizardMode.express.label == "Express")
        #expect(WizardMode.full.systemImage == "wand.and.stars")
        #expect(WizardMode.express.systemImage == "wand.and.stars.inverse")
    }

    @Test func remembersModeIndependentlyPerProfile() throws {
        let suite = "WizardModeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(WizardMode.remembered(profileName: "First", defaults: defaults) == .express)
        WizardMode.express.remember(profileName: "First", defaults: defaults)
        #expect(defaults.string(forKey: "wizard.mode.First") == "express")
        #expect(WizardMode.remembered(profileName: "First", defaults: defaults) == .express)
        #expect(WizardMode.remembered(profileName: "Second", defaults: defaults) == .express)

        WizardMode.full.remember(profileName: "Second", defaults: defaults)
        #expect(defaults.string(forKey: "wizard.mode.Second") == "full")
        #expect(WizardMode.remembered(profileName: "Second", defaults: defaults) == .full)
        #expect(WizardMode.remembered(profileName: "First", defaults: defaults) == .express)

        WizardMode.full.remember(profileName: "First", defaults: defaults)
        #expect(defaults.string(forKey: "wizard.mode.First") == "full")
        #expect(WizardMode.remembered(profileName: "First", defaults: defaults) == .full)
    }

    @Test func invalidRememberedModeFallsBackToFull() throws {
        let suite = "WizardModeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("future-mode", forKey: "wizard.mode.Profile")
        #expect(WizardMode.remembered(profileName: "Profile", defaults: defaults) == .express)
        WizardMode.express.remember(profileName: "Profile", defaults: defaults)
        #expect(WizardMode.remembered(profileName: "Profile", defaults: defaults) == .express)
    }
}
