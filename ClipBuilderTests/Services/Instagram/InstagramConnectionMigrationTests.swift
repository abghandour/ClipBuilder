import Foundation
import Testing
@testable import Clip_Builder

@Suite("Instagram connection migration")
struct InstagramConnectionMigrationTests {
    @Test("Legacy connection migrates with its flavor and dates", arguments: ["facebook", "instagram"])
    func legacyConnection(flavor: String) throws {
        var settings = InstagramSettings()
        settings.connectedUsername = "peacegrappler"
        settings.connectedIGUserID = "ig-123"
        settings.tokenFlavor = flavor
        settings.tokenExpiresAt = .distantFuture
        settings.tokenRefreshedAt = .distantPast
        settings.cookieSource = "safari"
        let migrated = InstagramConnectionMigration.migrate(settings)
        #expect(migrated.connections == [InstagramConnection(
            username: "peacegrappler", igUserID: "ig-123", tokenFlavor: flavor,
            tokenExpiresAt: .distantFuture, tokenRefreshedAt: .distantPast)])
        #expect(migrated.connections.first?.id == "ig-123")
        #expect(migrated.connectedUsername.isEmpty)
        #expect(migrated.connectedIGUserID.isEmpty)
        #expect(migrated.tokenFlavor == "facebook")
        #expect(migrated.tokenExpiresAt == nil)
        #expect(migrated.tokenRefreshedAt == nil)
        #expect(migrated.cookieSource == "safari")
    }

    @Test("Already migrated settings are untouched, even with stale legacy fields")
    func alreadyMigrated() throws {
        var settings = InstagramSettings()
        settings.connections = [InstagramConnection(username: "new", igUserID: "new-id", tokenFlavor: "instagram")]
        settings.connectedUsername = "old"
        settings.connectedIGUserID = "old-id"
        let migrated = InstagramConnectionMigration.migrate(settings)
        #expect(migrated.connections == settings.connections)
        #expect(migrated.connectedUsername == settings.connectedUsername)
        #expect(migrated.connectedIGUserID == settings.connectedIGUserID)
    }

    @Test("A legacy account without an ID is dropped")
    func emptyLegacyID() {
        var settings = InstagramSettings()
        settings.connectedUsername = "old"
        settings.tokenExpiresAt = .distantFuture
        let migrated = InstagramConnectionMigration.migrate(settings)
        #expect(migrated.connections.isEmpty)
        #expect(!migrated.isGraphConnected)
        #expect(migrated.connectedUsername.isEmpty)
        #expect(migrated.tokenExpiresAt == nil)
    }

    @Test("Unconnected settings remain unconnected")
    func noLegacyConnection() {
        #expect(InstagramConnectionMigration.migrate(InstagramSettings()).connections.isEmpty)
    }
}
