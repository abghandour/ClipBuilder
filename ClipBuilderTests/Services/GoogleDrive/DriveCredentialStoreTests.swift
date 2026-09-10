import Foundation
import Security
import Synchronization
import Testing
@testable import Clip_Builder

/// An in-memory stand-in for the two keychains: the data-protection one
/// (queries carrying kSecUseDataProtectionKeychain) and the legacy
/// login keychain. `entitled == false` reproduces a build with no
/// keychain-access-group entitlement, which the real API refuses.
final class FakeKeychain: Sendable {
    struct Store: Sendable {
        var modern: [String: Data] = [:]
        var legacy: [String: Data] = [:]
    }

    let items = Mutex(Store())
    let entitled: Bool
    /// A data-protection write that fails for a reason other than a missing
    /// entitlement (a locked keychain, an I/O error).
    let modernWriteStatus: OSStatus

    init(entitled: Bool = true, modernWriteStatus: OSStatus = errSecSuccess) {
        self.entitled = entitled
        self.modernWriteStatus = modernWriteStatus
    }

    private func isModern(_ query: [String: Any]) -> Bool {
        (query[kSecUseDataProtectionKeychain as String] as? Bool) == true
    }

    private func key(_ query: [String: Any]) -> String {
        "\(query[kSecAttrService as String] as? String ?? "")|"
            + "\(query[kSecAttrAccount as String] as? String ?? "")"
    }

    var api: KeychainAPI {
        KeychainAPI(
            copyMatching: { [self] query in
                if isModern(query) && !entitled { return (errSecMissingEntitlement, nil) }
                let value = items.withLock { store in
                    isModern(query) ? store.modern[key(query)] : store.legacy[key(query)]
                }
                return value.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
            },
            update: { [self] query, attributes in
                if isModern(query) && !entitled { return errSecMissingEntitlement }
                if isModern(query) && modernWriteStatus != errSecSuccess { return modernWriteStatus }
                guard let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
                return items.withLock { store in
                    if isModern(query) {
                        guard store.modern[key(query)] != nil else { return errSecItemNotFound }
                        store.modern[key(query)] = data
                    } else {
                        guard store.legacy[key(query)] != nil else { return errSecItemNotFound }
                        store.legacy[key(query)] = data
                    }
                    return errSecSuccess
                }
            },
            add: { [self] attributes in
                if isModern(attributes) && !entitled { return errSecMissingEntitlement }
                if isModern(attributes) && modernWriteStatus != errSecSuccess { return modernWriteStatus }
                guard let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
                items.withLock { store in
                    if isModern(attributes) {
                        store.modern[key(attributes)] = data
                    } else {
                        store.legacy[key(attributes)] = data
                    }
                }
                return errSecSuccess
            },
            delete: { [self] query in
                if isModern(query) && !entitled { return errSecMissingEntitlement }
                return items.withLock { store in
                    let removed = isModern(query)
                        ? store.modern.removeValue(forKey: key(query))
                        : store.legacy.removeValue(forKey: key(query))
                    return removed == nil ? errSecItemNotFound : errSecSuccess
                }
            })
    }
}

/// The login keychain grants access per code signature. The test host is
/// re-signed ad hoc on every build, so it would ask the user for permission
/// forever — these runs keep their secrets in a file beside their scratch
/// data instead.
@Suite("Drive credential stores", .serialized)
struct DriveCredentialStoreTests {
    @Test("the file store round-trips, deletes on nil, and stays owner-only")
    func fileStoreRoundTrip() throws {
        let temp = try TempDirectory()
        let store = FileCredentialStore(service: "com.clipbuilder.google-drive", root: temp.url)
        #expect(try store.read(profile: "Peace") == nil)

        try store.write(Data("token".utf8), profile: "Peace")
        #expect(try store.read(profile: "Peace") == Data("token".utf8))
        #expect(try store.read(profile: "Other") == nil, "profiles do not share a file")

        try store.write(Data("newer".utf8), profile: "Peace")
        #expect(try store.read(profile: "Peace") == Data("newer".utf8))

        let file = temp.url.appendingPathComponent(".credentials")
            .appendingPathComponent(store.folderName)
            .appendingPathComponent(store.fileName(for: "Peace"))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.int16Value == 0o600)

        try store.write(nil, profile: "Peace")
        #expect(try store.read(profile: "Peace") == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("names that an escape would fold together keep their own files")
    func profileNamesNeverCollide() throws {
        let temp = try TempDirectory()
        let store = FileCredentialStore(service: "com.clipbuilder.google-drive", root: temp.url)
        try store.write(Data("spaced".utf8), profile: "A B")
        try store.write(Data("scored".utf8), profile: "A_B")
        #expect(try store.read(profile: "A B") == Data("spaced".utf8))
        #expect(try store.read(profile: "A_B") == Data("scored".utf8))
    }

    @Test("a profile name that could escape the folder is refused")
    func dangerousProfileNamesAreRefused() throws {
        let temp = try TempDirectory()
        let store = FileCredentialStore(service: "svc", root: temp.url)
        for name in ["..", ".", "", "../escape", "a/b"] {
            #expect(throws: FileCredentialStore.StoreError.self) {
                try store.write(Data("x".utf8), profile: name)
            }
            #expect(throws: FileCredentialStore.StoreError.self) {
                _ = try store.read(profile: name)
            }
        }
    }

    @Test("a delete that cannot happen is reported, not swallowed")
    func deleteFailureSurfaces() throws {
        let temp = try TempDirectory()
        let store = FileCredentialStore(service: "svc", root: temp.url)
        try store.write(Data("token".utf8), profile: "Peace")
        let directory = temp.url.appendingPathComponent(".credentials")
        // A read-only parent makes the unlink fail the way a locked folder
        // or a permissions change would.
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: directory
                                                .appendingPathComponent(store.folderName).path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.appendingPathComponent(store.folderName).path)
        }
        #expect(throws: FileCredentialStore.StoreError.self) {
            try store.write(nil, profile: "Peace")
        }
    }

    @Test("the Drive token moves to the data-protection keychain once, then stays")
    func keychainMigration() throws {
        let fake = FakeKeychain()
        fake.items.withLock { $0.legacy["com.clipbuilder.google-drive|Peace"] = Data("old".utf8) }
        let keychain = GoogleDriveKeychain(service: "com.clipbuilder.google-drive", api: fake.api)

        #expect(try keychain.read(profile: "Peace") == Data("old".utf8))
        fake.items.withLock {
            #expect($0.modern["com.clipbuilder.google-drive|Peace"] == Data("old".utf8),
                    "the token is adopted by the data-protection keychain")
            #expect($0.legacy.isEmpty, "and the old item, which prompts, is gone")
        }

        // A second read finds it where it now lives.
        #expect(try keychain.read(profile: "Peace") == Data("old".utf8))
        try keychain.write(Data("new".utf8), profile: "Peace")
        fake.items.withLock {
            #expect($0.modern["com.clipbuilder.google-drive|Peace"] == Data("new".utf8))
            #expect($0.legacy.isEmpty)
        }
        try keychain.write(nil, profile: "Peace")
        fake.items.withLock { #expect($0.modern.isEmpty && $0.legacy.isEmpty) }
    }

    @Test("without the entitlement the old keychain keeps working and keeps its item")
    func keychainFallsBackWithoutEntitlement() throws {
        let fake = FakeKeychain(entitled: false)
        fake.items.withLock { $0.legacy["svc|Peace"] = Data("old".utf8) }
        let keychain = GoogleDriveKeychain(service: "svc", api: fake.api)

        #expect(try keychain.read(profile: "Peace") == Data("old".utf8))
        fake.items.withLock {
            #expect($0.legacy["svc|Peace"] == Data("old".utf8),
                    "a refused migration leaves the legacy item exactly as it was")
            #expect($0.modern.isEmpty)
        }
        try keychain.write(Data("new".utf8), profile: "Peace")
        fake.items.withLock { #expect($0.legacy["svc|Peace"] == Data("new".utf8)) }
    }

    @Test("a data-protection write that fails leaves the old item alone")
    func failedModernWriteKeepsTheLegacyItem() throws {
        let fake = FakeKeychain(modernWriteStatus: errSecIO)
        fake.items.withLock { $0.legacy["svc|Peace"] = Data("old".utf8) }
        let keychain = GoogleDriveKeychain(service: "svc", api: fake.api)

        // The migration cannot complete, so the token stays where it works.
        #expect(try keychain.read(profile: "Peace") == Data("old".utf8))
        fake.items.withLock {
            #expect($0.legacy["svc|Peace"] == Data("old".utf8))
            #expect($0.modern.isEmpty)
        }

        // A write that cannot reach the new keychain is an error, not a
        // silent downgrade — only a missing entitlement falls back.
        #expect(throws: GoogleDriveError.self) {
            try keychain.write(Data("new".utf8), profile: "Peace")
        }
        fake.items.withLock { #expect($0.legacy["svc|Peace"] == Data("old".utf8)) }
    }

    @Test("a store keeps the data root it was made with")
    func storeBindsItsRoot() throws {
        let temp = try TempDirectory()
        let store = FileCredentialStore(service: "svc", root: temp.url)
        let scope = try DataFolderOverride()
        _ = scope
        try store.write(Data("token".utf8), profile: "Peace")
        #expect(try store.read(profile: "Peace") == Data("token".utf8),
                "a later data-folder change does not move an existing store")
        #expect(store.root == temp.url)
    }

    @Test("a run against a scratch data folder never touches the keychain")
    func scratchRunsUseTheFileStore() throws {
        let scope = try DataFolderOverride()
        _ = scope
        #expect(SettingsStore.customDataFolder != nil)
        #expect(DriveCredentialStores.usesFileStore)
        #expect(DriveCredentialStores.store() is FileCredentialStore)
        #expect(DriveCredentialStores.store(service: "com.clipbuilder.google-drive.configuration")
                is FileCredentialStore)

        // The default stores of the Drive types are the selected one, so no
        // caller has to remember this.
        let store = DriveCredentialStores.store()
        try store.write(Data("scratch".utf8), profile: "Test")
        let fileStore = try #require(store as? FileCredentialStore)
        let written = SettingsStore.dataDirectory
            .appendingPathComponent(".credentials")
            .appendingPathComponent(fileStore.folderName)
            .appendingPathComponent(fileStore.fileName(for: "Test"))
        #expect(FileManager.default.fileExists(atPath: written.path),
                "the token lands in the scratch data folder, not the login keychain")
        try store.write(nil, profile: "Test")
    }
}
