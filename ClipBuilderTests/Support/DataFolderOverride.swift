import Foundation
@testable import Clip_Builder

/// Serial tests use this scope so production profile and settings data is never touched.
final class DataFolderOverride {
    let directory: TempDirectory
    private let previousValue: Any?

    init(prefix: String = "ClipBuilderData") throws {
        directory = try TempDirectory(prefix: prefix)
        let defaults = UserDefaults.standard
        previousValue = defaults.object(forKey: SettingsStore.dataFolderDefaultsKey)
        defaults.set(directory.url.appendingPathComponent("data", isDirectory: true).path,
                     forKey: SettingsStore.dataFolderDefaultsKey)
        ScreenCropStore.invalidateListing()
    }

    deinit {
        let defaults = UserDefaults.standard
        if let previousValue {
            defaults.set(previousValue, forKey: SettingsStore.dataFolderDefaultsKey)
        } else {
            defaults.removeObject(forKey: SettingsStore.dataFolderDefaultsKey)
        }
        ScreenCropStore.invalidateListing()
    }
}
