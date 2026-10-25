import Foundation
import Synchronization
import Testing
@testable import Clip_Builder

@MainActor
struct WizardDefaultsMigrationTests {
    @Test func repeatedMigrationAndSettingsReadsDoNotWriteDefaults() throws {
        let suite = "WizardDefaultsMigration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            WizardDefaults.resetForTesting(defaults: defaults)
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.set(true, forKey: "wizard.reviewProposedCuts")
        defaults.set("split_zoom", forKey: "wizard.podcastFraming")
        WizardDefaults.migrateLegacy(defaults: defaults)
        #expect(defaults.string(forKey: WizardDefaults.workflowKey) == "reviewMoments")
        #expect(defaults.string(forKey: "wizard.highlightFraming") == "grid")
        #expect(defaults.object(forKey: "wizard.reviewProposedCuts") == nil)

        let before = defaults.dictionaryRepresentation() as NSDictionary
        let notifications = Mutex(0)
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { _ in notifications.withLock { $0 += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }

        WizardDefaults.migrateLegacy(defaults: defaults)
        _ = WizardDefaults.brandingOverride(defaults: defaults)
        _ = AISettingsPreferences.wizard(defaults: defaults, profile: Fixtures.brand())
        #expect(notifications.withLock { $0 } == 0)
        #expect(before.isEqual(to: defaults.dictionaryRepresentation()))

        // Even a fresh process must not write already-migrated defaults.
        WizardDefaults.resetForTesting(defaults: defaults)
        WizardDefaults.migrateLegacy(defaults: defaults)
        WizardCameraFocus.migrate(defaults: defaults)
        #expect(notifications.withLock { $0 } == 0)
        #expect(before.isEqual(to: defaults.dictionaryRepresentation()))
    }

    @Test func migrationIsOncePerDefaultsInstanceUntilReset() throws {
        let firstSuite = "WizardDefaultsFirst-\(UUID().uuidString)"
        let secondSuite = "WizardDefaultsSecond-\(UUID().uuidString)"
        let first = try #require(UserDefaults(suiteName: firstSuite))
        let second = try #require(UserDefaults(suiteName: secondSuite))
        defer {
            WizardDefaults.resetForTesting(defaults: first)
            WizardDefaults.resetForTesting(defaults: second)
            first.removePersistentDomain(forName: firstSuite)
            second.removePersistentDomain(forName: secondSuite)
        }
        WizardDefaults.migrateLegacy(defaults: first)
        second.set(true, forKey: "wizard.reviewProposedCuts")
        WizardDefaults.migrateLegacy(defaults: second)
        #expect(second.string(forKey: WizardDefaults.workflowKey) == "reviewMoments")

        first.set(true, forKey: "wizard.reviewProposedCuts")
        WizardDefaults.migrateLegacy(defaults: first)
        #expect(first.bool(forKey: "wizard.reviewProposedCuts"))
        WizardDefaults.resetForTesting(defaults: first)
        WizardDefaults.migrateLegacy(defaults: first)
        #expect(first.object(forKey: "wizard.reviewProposedCuts") == nil)
        #expect(first.string(forKey: WizardDefaults.workflowKey) == "automatic")
    }
}
