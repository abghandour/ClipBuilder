import Foundation
import Testing

@testable import Clip_Builder

@Suite("Google Drive setup")
struct GoogleDriveSetupTests {
    @Test("Every Drive error uses plain language")
    func friendlyErrors() {
        let errors: [GoogleDriveError] = [
            .accountMismatch(expected: "person@example.com"), .notConfigured, .reconnect,
            .quota, .notFound, .forbidden, .offline, .cancelled, .invalidResponse, .conflict, .inUse,
            .server(500), .keychain(-1),
        ]
        for error in errors {
            let text = error.localizedDescription.lowercased()
            #expect(!text.isEmpty)
            for forbidden in [
                "plist", "info.plist", "googleoauth", "client id", "client secret", "oauth", "pkce", "scope",
            ] {
                #expect(!text.contains(forbidden))
            }
        }
    }

    @Test("Folders report whether the user may add children; unknown means writable")
    func folderCapabilities() throws {
        let decoder = JSONDecoder()
        let viewOnly = try decoder.decode(
            DriveFile.self,
            from: Data(
                #"{"id":"a","name":"PAX Folder","mimeType":"application/vnd.google-apps.folder","capabilities":{"canAddChildren":false}}"#
                    .utf8))
        #expect(!viewOnly.canAddChildren)
        let editable = try decoder.decode(
            DriveFile.self, from: Data(#"{"id":"b","name":"Mine","mimeType":"application/vnd.google-apps.folder","capabilities":{"canAddChildren":true}}"#.utf8))
        #expect(editable.canAddChildren)
        let root = DriveFile(id: "root", name: "My Drive", mimeType: "application/vnd.google-apps.folder")
        #expect(root.canAddChildren)
        #expect(GoogleDriveClient.fields.contains("capabilities/canAddChildren"))
    }

    @Test("Sign-in requires full Drive access, not the read-only and app-file pair")
    func fullDriveScope() {
        #expect(GoogleDriveAuth.hasDriveScopes("openid email https://www.googleapis.com/auth/drive"))
        #expect(
            !GoogleDriveAuth.hasDriveScopes(
                "https://www.googleapis.com/auth/drive.readonly https://www.googleapis.com/auth/drive.file"))
    }

    @Test("The device Keychain override wins; clearing it restores bundled values")
    func overridePrecedence() throws {
        let keychain = FakeDriveCredentials()
        let bundle = GoogleOAuthConfiguration(clientID: "bundled", clientSecret: "bundled-secret")
        let store = GoogleDriveConfigurationStore(keychain: keychain, bundled: bundle)
        #expect(try store.resolved() == bundle)
        let override = GoogleOAuthConfiguration(clientID: "custom", clientSecret: "custom-secret")
        try store.save(override)
        #expect(try store.override() == override)
        #expect(try store.resolved() == override)
        let reopened = GoogleDriveConfigurationStore(keychain: keychain, bundled: bundle)
        #expect(try reopened.resolved() == override)
        try reopened.save(nil)
        #expect(try store.override() == nil)
        #expect(try store.resolved() == bundle)
    }

    @Test("Absent, incomplete, or malformed overrides fall back to the bundle")
    func overrideFallback() throws {
        let keychain = FakeDriveCredentials()
        let bundle = GoogleOAuthConfiguration(clientID: "bundled", clientSecret: "secret")
        let store = GoogleDriveConfigurationStore(keychain: keychain, bundled: bundle)
        try keychain.write(Data("broken".utf8), profile: "application")
        #expect(try store.resolved() == bundle)
        try keychain.write(
            JSONEncoder().encode(GoogleOAuthConfiguration(clientID: "  ", clientSecret: "secret")),
            profile: "application")
        #expect(try store.resolved() == bundle)
        try store.save(.init(clientID: " custom \n", clientSecret: " secret "))
        #expect(try store.resolved() == .init(clientID: "custom", clientSecret: "secret"))
        try store.save(nil)
        let empty = GoogleDriveConfigurationStore(keychain: keychain, bundled: .init(clientID: "", clientSecret: ""))
        #expect(try !empty.resolved().isConfigured)
    }

    @Test("Saving an override updates availability and requires the old account to sign in again")
    func liveConfiguration() async throws {
        let settings = GoogleDriveConfigurationStore(
            keychain: FakeDriveCredentials(), bundled: .init(clientID: "", clientSecret: ""))
        let accounts = FakeDriveCredentials()
        try accounts.write(
            JSONEncoder().encode(DriveCredential(refreshToken: "old", issuedAt: Date(), email: "person@example.com")),
            profile: "profile")
        let auth = GoogleDriveAuth(configurationStore: settings, credentials: accounts)
        #expect(await auth.state(profile: "profile") == .notConfigured)
        try await auth.saveApplicationOverride(.init(clientID: "custom", clientSecret: "secret"))
        #expect(await auth.configuration.clientID == "custom")
        #expect(try await auth.applicationOverride()?.clientID == "custom")
        #expect(await auth.state(profile: "new profile") == .disconnected)
        if case .reconnect = await auth.state(profile: "profile") {
        } else {
            Issue.record("Changing the app connection must require signing in again")
        }
        try await auth.saveApplicationOverride(nil)
        #expect(await auth.state(profile: "profile") == .notConfigured)
    }
}
