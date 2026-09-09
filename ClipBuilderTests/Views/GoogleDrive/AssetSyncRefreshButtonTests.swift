import Foundation
import Testing

@testable import Clip_Builder

@MainActor
struct AssetSyncRefreshButtonTests {
    @Test func connectionLostHomeAndRunningDisableRefresh() {
        let home = AssetSyncHome(folder: AssetSyncFixture.folder("home", "Library"), breadcrumb: "Library")
        let connected = DriveConnectionState.connected(email: "test@example.com", expires: Date())
        #expect(AssetSyncRefreshButton.canRefresh(home: home, connection: connected))
        #expect(!AssetSyncRefreshButton.canRefresh(home: home, connection: nil))
        #expect(!AssetSyncRefreshButton.canRefresh(home: home, connection: .disconnected))
        home.isRefreshing = true
        #expect(!AssetSyncRefreshButton.canRefresh(home: home, connection: connected))
        home.isRefreshing = false
        home.isLost = true
        #expect(!AssetSyncRefreshButton.canRefresh(home: home, connection: connected))
    }
}
