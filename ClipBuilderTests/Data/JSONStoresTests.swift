import Foundation
import Testing
@testable import Clip_Builder

@Suite("JSON stores", .serialized)
struct JSONStoresTests {
    @Test("profiles and settings stay inside the overridden data folder")
    func profileAndSettings() throws {
        let scope = try DataFolderOverride()
        var profile = Fixtures.brand(name: "Fixture")
        profile.brandName = "Fixture Brand"
        try ProfileStore.save(profile)
        #expect(ProfileStore.load(name: "Fixture")?.brandName == "Fixture Brand")
        #expect(ProfileStore.profileURL(name: "Fixture").path.hasPrefix(scope.directory.url.path))

        var settings = AppSettings()
        settings.theme = "midnight"
        SettingsStore.save(settings)
        #expect(SettingsStore.loadSettings().theme == "midnight")
        #expect(SettingsStore.settingsURL.path.hasPrefix(scope.directory.url.path))
    }

    @Test("regression: a failed profile write leaves no partial file behind")
    func atomicProfileWrite() throws {
        let scope = try DataFolderOverride()
        _ = scope
        // Seed the directory so the failure is the write itself, not the
        // directory creation.
        try ProfileStore.save(Fixtures.brand(name: "Existing"))
        let directory = ProfileStore.profilesDirectory
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }

        #expect(throws: (any Error).self) {
            try ProfileStore.save(Fixtures.brand(name: "Blocked"))
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains("Blocked") || $0.hasPrefix(".dat") || $0.contains(".tmp") }
        #expect(leftovers.isEmpty, "partial file(s) left behind: \(leftovers)")
        // The existing profile is untouched.
        #expect(ProfileStore.load(name: "Existing") != nil)
    }

    @Test("regression: screen crops support case-only rename")
    func screenCropCaseRename() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let layout = ScreenCropLayout(name: "Fixture Crop", areas: [
            ScreenCropArea(name: "Full", points: [
                ScreenCropPoint(x: 0, y: 0), ScreenCropPoint(x: 1, y: 0),
                ScreenCropPoint(x: 1, y: 1), ScreenCropPoint(x: 0, y: 1),
            ]),
        ])
        try ScreenCropStore.save(layout)
        let renamed = try ScreenCropStore.rename("Fixture Crop", to: "fixture crop")
        #expect(renamed == "fixture crop")
        #expect(ScreenCropStore.layout(named: "fixture crop")?.areas.count == 1)
    }

    @Test("overlay templates save, list, rename (case-only too), and delete")
    func overlayTemplates() throws {
        let scope = try DataFolderOverride()
        _ = scope
        OverlayTemplateStore.invalidateCache()
        var composition = OverlayComposition()
        composition.texts = [TextOverlayItem(text: "Hello", startTime: 0, endTime: 2)]
        try OverlayTemplateStore.save(OverlayTemplate(name: "Fixture Title", composition: composition))
        #expect(OverlayTemplateStore.list().map(\.name) == ["Fixture Title"])
        #expect(OverlayTemplateStore.list().first?.composition.texts.first?.text == "Hello")

        let renamed = try OverlayTemplateStore.rename("Fixture Title", to: "fixture title")
        #expect(renamed == "fixture title")
        #expect(OverlayTemplateStore.list().map(\.name) == ["fixture title"])

        try OverlayTemplateStore.delete(name: "fixture title")
        #expect(OverlayTemplateStore.list().isEmpty)
    }

    @Test("wizard defaults migrate legacy keys without clobbering explicit choices")
    func wizardDefaultsMigration() throws {
        let suite = "ClipBuilderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // Fresh install: every mode gets a value.
        WizardDefaults.migrateLegacy(defaults: defaults)
        #expect(defaults.string(forKey: WizardDefaults.durationModeKey) == WizardDurationMode.automatic.rawValue)
        #expect(defaults.string(forKey: WizardDefaults.layoutModeKey) == WizardLayoutMode.automatic.rawValue)
        #expect(defaults.string(forKey: WizardDefaults.audioModeKey) != nil)

        // An explicit choice survives a second migration.
        defaults.set(WizardLayoutMode.selected.rawValue, forKey: WizardDefaults.layoutModeKey)
        WizardDefaults.migrateLegacy(defaults: defaults)
        #expect(defaults.string(forKey: WizardDefaults.layoutModeKey) == WizardLayoutMode.selected.rawValue)

        // Both legacy scope toggles on: batch scope wins, curated filter drops.
        defaults.set(true, forKey: "wizard.limitToSelection")
        defaults.set(true, forKey: "wizard.curatedOnly")
        WizardDefaults.migrateLegacy(defaults: defaults)
        #expect(!defaults.bool(forKey: "wizard.curatedOnly"))
    }

    @Test("wizard options read approved layouts and allowed transitions from defaults")
    func wizardOptionsFromDefaults() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let suite = "ClipBuilderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // Off: any layout, any transition.
        #expect(WizardDefaults.approvedScreenCropLayouts(defaults: defaults).isEmpty)
        #expect(WizardDefaults.allowedTransitions(defaults: defaults) == nil)

        defaults.set(true, forKey: WizardDefaults.limitTransitionsKey)
        // "cut" is the nil transition, not a name; unknown names drop.
        defaults.set("cut,fade,not-a-transition", forKey: WizardDefaults.allowedTransitionsKey)
        #expect(WizardDefaults.allowedTransitions(defaults: defaults) == ["fade"])

        defaults.set(true, forKey: WizardDefaults.useScreenCropsKey)
        defaults.set("50-50 Horizontal,Missing Layout", forKey: WizardDefaults.screenCropLayoutsKey)
        #expect(WizardDefaults.approvedScreenCropLayouts(defaults: defaults) == ["50-50 Horizontal"])
        // An empty saved selection means every existing layout.
        defaults.set("", forKey: WizardDefaults.screenCropLayoutsKey)
        #expect(WizardDefaults.approvedScreenCropLayouts(defaults: defaults).contains("50-50 Diagonal"))
    }

    @Test("default profile creation is idempotent")
    func defaultProfile() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let first = ProfileStore.ensureDefaultProfile()
        let second = ProfileStore.ensureDefaultProfile()
        #expect(first.profileName == "Default")
        #expect(second == first)
    }
}
