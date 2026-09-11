import Foundation
@testable import Clip_Builder

/// Synchronous tests use this scope when they need an empty data folder.
/// Never await while holding it: the override is process-global and suite
/// serialization does not isolate it from other suites. Async tests use the
/// scratch test-host data folder plus their own TempDatabase/TempDirectory.
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
