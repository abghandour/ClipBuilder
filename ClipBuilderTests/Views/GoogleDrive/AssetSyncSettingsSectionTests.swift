import Foundation
import Testing

@testable import Clip_Builder

@MainActor
struct AssetSyncSettingsSectionTests {
    @Test func onlyConnectedProfilesSeeSection() {
        #expect(!AssetSyncSettingsSection.isVisible(connection: nil))
        #expect(!AssetSyncSettingsSection.isVisible(connection: .notConfigured))
        #expect(!AssetSyncSettingsSection.isVisible(connection: .disconnected))
        #expect(AssetSyncSettingsSection.isVisible(connection: .connected(email: "a@example.com", expires: Date())))
    }
}
