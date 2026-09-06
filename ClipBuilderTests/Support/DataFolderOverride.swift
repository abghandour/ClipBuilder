import Foundation
@testable import Clip_Builder

/// Serial tests use this scope so production profile and settings data is never touched.
/// The override lives only in this process: writing the persisted default would
/// leave the user's app pointed at a temporary folder if the run were killed.
final class DataFolderOverride {
    let directory: TempDirectory
    private let previousValue: String?

    init(prefix: String = "ClipBuilderData") throws {
        directory = try TempDirectory(prefix: prefix)
        previousValue = SettingsStore.dataFolderOverride
        SettingsStore.dataFolderOverride = directory.url
            .appendingPathComponent("data", isDirectory: true).path
        ScreenCropStore.invalidateListing()
    }

    deinit {
        SettingsStore.dataFolderOverride = previousValue
        ScreenCropStore.invalidateListing()
    }
}
