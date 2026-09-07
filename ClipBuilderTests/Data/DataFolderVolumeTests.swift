import Foundation
import Testing
@testable import Clip_Builder

@Suite("Data folder volume guard", .serialized)
struct DataFolderVolumeTests {
    @Test("an internal-disk folder that doesn't exist yet is accepted")
    func internalFolderAccepted() throws {
        let scope = try TempDirectory(prefix: "ClipBuilderVolume")
        let path = scope.url.appendingPathComponent("not/yet/created/data").path
        #expect(SettingsStore.dataFolderRejection(forPath: path) == nil)
        #expect(SettingsStore.dataFolderRejection(forPath: "~/Documents/ClipBuilder/data") == nil)
    }

    @Test("a folder on an unmounted /Volumes drive is rejected and ignored")
    func unmountedVolumeRejected() throws {
        let path = "/Volumes/ClipBuilder-Missing-\(UUID().uuidString)/ClipBuilder/data"
        let rejection = try #require(SettingsStore.dataFolderRejection(forPath: path))
        #expect(rejection.path == path)
        #expect(rejection.reason.contains("not mounted"))

        // The override resolves through the same guard as the user default:
        // the app falls back to the default folder and records the reason.
        let previous = SettingsStore.dataFolderOverride
        defer { SettingsStore.dataFolderOverride = previous }
        _ = SettingsStore.takeRejectedDataFolder()
        SettingsStore.dataFolderOverride = path
        #expect(SettingsStore.customDataFolder == nil)
        #expect(SettingsStore.takeRejectedDataFolder()?.path == path)
        #expect(SettingsStore.takeRejectedDataFolder() == nil)
    }

    @Test("mounted external volumes are rejected")
    func mountedExternalRejected() throws {
        let keys: Set<URLResourceKey> = [.volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey]
        let external = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys),
                                                               options: [.skipHiddenVolumes]) ?? [])
            .first { url in
                let values = try? url.resourceValues(forKeys: keys)
                return values?.volumeIsInternal == false || values?.volumeIsRemovable == true
                    || values?.volumeIsEjectable == true
            }
        guard let external else { return }   // no external drive attached: nothing to check
        let rejection = SettingsStore.dataFolderRejection(forPath: external.appendingPathComponent("data").path)
        #expect(rejection?.reason == "it is on an external drive")
    }
}
