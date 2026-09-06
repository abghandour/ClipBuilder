import Foundation
import Testing

@testable import Clip_Builder

nonisolated struct FailingAdvancedKeychain: DriveCredentialStore {
    let data: Data
    func read(profile: String) throws -> Data? { data }
    func write(_ data: Data?, profile: String) throws { throw GoogleDriveError.keychain(-1) }
}

@Suite("Advanced Google Drive settings")
@MainActor
struct GoogleDriveAdvancedSettingsTests {
    private func drive(
        bundle: GoogleOAuthConfiguration = .init(clientID: "", clientSecret: ""),
        keychain: any DriveCredentialStore = FakeDriveCredentials()
    ) -> GoogleDriveTransfers {
        GoogleDriveTransfers(
            auth: GoogleDriveAuth(
                configurationStore: GoogleDriveConfigurationStore(keychain: keychain, bundled: bundle),
                credentials: FakeDriveCredentials()))
    }

    @Test("Save enables Connect for attached profiles and an unattached active profile")
    func saveRefreshesProfiles() async throws {
        let transfers = drive()
        let temp = try TempDatabase()
        await transfers.attach(profile: BrandProfile(name: "attached"), database: temp.database)
        await transfers.refreshState(profile: "active")
        #expect(transfers.states["attached"] == .notConfigured)
        #expect(transfers.states["active"] == .notConfigured)
        let model = GoogleDriveAdvancedSettingsModel()
        await model.load(auth: transfers.auth)
        model.clientID = " custom "
        model.clientSecret = " secret "
        #expect(model.canSave)
        await model.save(clear: false, drive: transfers, activeProfile: "active")
        #expect(model.message == "Saved. Google Drive is ready to connect.")
        #expect(model.source == .personal)
        #expect(transfers.states["attached"] == .disconnected)
        #expect(transfers.states["active"] == .disconnected)
        #expect(await transfers.auth.state(profile: "active") == .disconnected)
        #expect(try await transfers.auth.applicationOverride() == .init(clientID: "custom", clientSecret: "secret"))
    }

    @Test("Clearing uses distinct copy for populated and empty built-in settings, even when already clear")
    func clearMessages() async throws {
        for configured in [false, true] {
            let transfers = drive(
                bundle: .init(clientID: configured ? "built-in" : "", clientSecret: configured ? "secret" : ""))
            let model = GoogleDriveAdvancedSettingsModel()
            model.clientID = "custom"
            model.clientSecret = "secret"
            await model.save(clear: false, drive: transfers, activeProfile: "active")
            let savedMessage = model.message
            for _ in 0..<2 {
                await model.save(clear: true, drive: transfers, activeProfile: "active")
                #expect(
                    model.message
                        == (configured
                            ? "Using the app's built-in settings."
                            : "This copy of Clip Builder has no built-in Google settings."))
                #expect(model.message != savedMessage)
                #expect(model.message?.contains("Saved") == false)
                #expect(model.source == (configured ? .builtIn : .unavailable))
                #expect(model.clientID.isEmpty && model.clientSecret.isEmpty)
                #expect(try await transfers.auth.applicationOverride() == nil)
                #expect(transfers.states["active"] == (configured ? .disconnected : .notConfigured))
            }
        }
    }

    @Test("Keychain failures preserve both typed values and the confirmed credential source")
    func writeFailurePreservesInput() async throws {
        let data = try JSONEncoder().encode(
            GoogleOAuthConfiguration(clientID: "original", clientSecret: "original-secret"))
        let transfers = drive(keychain: FailingAdvancedKeychain(data: data))
        let model = GoogleDriveAdvancedSettingsModel()
        await model.load(auth: transfers.auth)
        #expect(model.source == .personal)
        model.clientID = "new-id"
        model.clientSecret = "new-secret"
        for clear in [false, true] {
            await model.save(clear: clear, drive: transfers, activeProfile: "active")
            #expect(model.clientID == "new-id" && model.clientSecret == "new-secret")
            #expect(model.source == .personal)
            #expect(model.message == GoogleDriveError.keychain(-1).localizedDescription)
            #expect(model.canSave)
            #expect(!model.saving)
        }
    }

    @Test("Incomplete input cannot save or report success")
    func validation() async throws {
        let transfers = drive()
        let model = GoogleDriveAdvancedSettingsModel()
        model.clientID = " \n "
        model.clientSecret = "secret"
        #expect(!model.canSave)
        await model.save(clear: false, drive: transfers, activeProfile: "active")
        #expect(model.message == "Enter both fields before saving.")
        #expect(try await transfers.auth.applicationOverride() == nil)
        model.clientID = "id"
        model.clientSecret = " "
        #expect(!model.canSave)
        model.clientSecret = "secret"
        #expect(model.canSave)
    }

    @Test("Loading reports the persisted source without overwriting unsaved edits")
    func loadSource() async throws {
        let transfers = drive(bundle: .init(clientID: "built-in", clientSecret: "secret"))
        let model = GoogleDriveAdvancedSettingsModel()
        await model.load(auth: transfers.auth)
        #expect(model.source.description == "Using the app's built-in settings")
        try await transfers.auth.saveApplicationOverride(.init(clientID: "custom", clientSecret: "saved-secret"))
        await model.load(auth: transfers.auth)
        #expect(model.clientID == "custom" && model.clientSecret == "saved-secret")
        #expect(model.source.description == "Using your own credentials (saved on this Mac)")
        model.clientID = "unsaved"
        await model.load(auth: transfers.auth)
        #expect(model.clientID == "unsaved")
    }
}
