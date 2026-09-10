import Foundation

/// One device-only Keychain item, separate from per-profile account tokens.
nonisolated struct GoogleDriveConfigurationStore: Sendable {
    private let keychain: any DriveCredentialStore
    private let bundled: GoogleOAuthConfiguration
    private let account = "application"

    init(
        keychain: any DriveCredentialStore = DriveCredentialStores.store(
            service: "com.clipbuilder.google-drive.configuration"),
        bundled: GoogleOAuthConfiguration = .bundled
    ) {
        self.keychain = keychain
        self.bundled = bundled
    }

    func override() throws -> GoogleOAuthConfiguration? {
        guard let data = try keychain.read(profile: account),
            let value = try? JSONDecoder().decode(GoogleOAuthConfiguration.self, from: data),
            value.isConfigured
        else { return nil }
        return value
    }

    func resolved() throws -> GoogleOAuthConfiguration { try override() ?? bundled }

    func save(_ value: GoogleOAuthConfiguration?) throws {
        let clean = value.map {
            GoogleOAuthConfiguration(
                clientID: $0.clientID.trimmingCharacters(in: .whitespacesAndNewlines),
                clientSecret: $0.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let clean, !clean.isConfigured { throw GoogleDriveError.invalidResponse }
        try keychain.write(try clean.map { try JSONEncoder().encode($0) }, profile: account)
    }
}
