import Foundation
import Testing

@testable import Clip_Builder

@MainActor
struct AssetSyncHomeTests {
    @Test func unavailableHomeDisablesRefresh() async throws {
        for trashed in [false, true] {
            let fixture = try AssetSyncFixture { _, _ in
                if !trashed { return (Data(), 404, [:]) }
                var folder = AssetSyncFixture.folder("home", "Library")
                folder.trashed = true
                return try AssetSyncFixture.response(folder)
            }
            let home = AssetSyncHome(
                folder: AssetSyncFixture.folder("home", "Library"), breadcrumb: "My Drive › Library")
            #expect(try await home.validate(client: fixture.client) == false)
            #expect(home.isLost)
            #expect(!home.canRefresh)
            #expect(home.rowStatus == "Folder no longer available — choose again")
        }
    }

    @Test func noHomeMakesNoTrafficAndForgetLeavesFiles() async throws {
        let fixture = try AssetSyncFixture { _, _ in throw GoogleDriveError.invalidResponse }
        await fixture.attach()
        fixture.transfers.refreshAssets(profile: fixture.profile.profileName) { _ in Issue.record("OFF path ran sync") }
        #expect(await fixture.transport.requests.isEmpty)
        #expect(fixture.transfers.assetHomes.isEmpty)
        let source = try fixture.write("music/keep.mp3")
        try await fixture.transfers.chooseAssetHome(
            AssetSyncFixture.folder("home", "Library"),
            breadcrumb: "My Drive › Library", profile: fixture.profile.profileName)
        let json = try await fixture.database.driveSetting("assetHome")!
        let restored = await AssetSyncHome.restore(json: json, database: fixture.database)
        #expect(restored?.selection.breadcrumb == "My Drive › Library")
        #expect(restored?.canRefresh == true)
        try await fixture.database.setDriveSetting("unrelated", value: "keep")
        try await fixture.transfers.forgetAssetHome(profile: fixture.profile.profileName)
        #expect(fixture.transfers.assetHomes.isEmpty)
        #expect(try await fixture.database.driveSetting("assetHome") == "")
        #expect(try await fixture.database.driveSetting("assetSyncJournal") == "")
        #expect(try await fixture.database.driveSetting("unrelated") == "keep")
        #expect(try Data(contentsOf: source) == Data("abc".utf8))
        #expect(await fixture.transport.requests.isEmpty)
    }
}
