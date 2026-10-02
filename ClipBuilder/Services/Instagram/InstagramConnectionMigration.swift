import Foundation

nonisolated enum InstagramConnectionMigration {
    static func migrate(_ settings: InstagramSettings) -> InstagramSettings {
        guard settings.connections.isEmpty, !settings.connectedUsername.isEmpty else { return settings }
        var migrated = settings
        if !settings.connectedIGUserID.isEmpty {
            migrated.connections = [InstagramConnection(
                username: settings.connectedUsername, igUserID: settings.connectedIGUserID,
                tokenFlavor: settings.tokenFlavor, tokenExpiresAt: settings.tokenExpiresAt,
                tokenRefreshedAt: settings.tokenRefreshedAt)]
        }
        migrated.connectedUsername = ""
        migrated.connectedIGUserID = ""
        migrated.tokenFlavor = "facebook"
        migrated.tokenExpiresAt = nil
        migrated.tokenRefreshedAt = nil
        return migrated
    }
}
