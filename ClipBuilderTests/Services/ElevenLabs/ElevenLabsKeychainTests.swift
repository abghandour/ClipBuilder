import Foundation
import Security
import Testing
@testable import Clip_Builder

struct ElevenLabsKeychainTests {
    @Test func storesOneMacLocalItemAndSupportsReplacementAndRemoval() throws {
        let fake = FakeKeychain()
        let keychain = ElevenLabsKeychain(api: fake.api)
        #expect(try keychain.read() == nil)
        try keychain.write("first-key")
        #expect(try keychain.read() == "first-key")
        fake.items.withLock {
            #expect($0.modern == ["com.clipbuilder.elevenlabs|api-key": Data("first-key".utf8)])
            #expect($0.legacy.isEmpty)
        }
        try keychain.write("replacement")
        #expect(try keychain.read() == "replacement")
        fake.items.withLock { #expect($0.modern.count == 1) }
        try keychain.write(nil)
        try keychain.write(nil)
        #expect(try keychain.read() == nil)
        fake.items.withLock { #expect($0.modern.isEmpty && $0.legacy.isEmpty) }
    }

    @Test func queriesAlwaysUseDataProtectionAndDeviceOnlyAccessibility() throws {
        let api = KeychainAPI(copyMatching: { query in
            #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
            #expect(query[kSecAttrService as String] as? String == "com.clipbuilder.elevenlabs")
            #expect(query[kSecAttrAccount as String] as? String == "api-key")
            #expect(query[kSecReturnData as String] as? Bool == true)
            #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
            return (errSecItemNotFound, nil)
        }, update: { query, attributes in
            #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
            #expect(attributes[kSecValueData as String] as? Data == Data("key".utf8))
            return errSecItemNotFound
        }, add: { attributes in
            #expect(attributes[kSecUseDataProtectionKeychain as String] as? Bool == true)
            #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
            return errSecSuccess
        }, delete: { query in
            // Removal clears both keychains, so only the item identity is fixed here.
            #expect(query[kSecAttrService as String] as? String == "com.clipbuilder.elevenlabs")
            #expect(query[kSecAttrAccount as String] as? String == "api-key")
            return errSecItemNotFound
        })
        let keychain = ElevenLabsKeychain(api: api)
        #expect(try keychain.read() == nil)
        try keychain.write("key")
        try keychain.write(nil)
    }

    @Test func keychainFailuresSurfaceWithoutWritingElsewhere() throws {
        let fake = FakeKeychain(modernWriteStatus: errSecIO)
        let keychain = ElevenLabsKeychain(api: fake.api)
        #expect(throws: ElevenLabsKeychain.StoreError(status: errSecIO)) { try keychain.write("key") }
        fake.items.withLock { #expect($0.modern.isEmpty && $0.legacy.isEmpty) }
    }

    /// An ad-hoc build has no keychain-access-groups entitlement: the
    /// data-protection keychain answers -34018 and the login keychain serves.
    @Test func missingEntitlementFallsBackToTheLoginKeychain() throws {
        let fake = FakeKeychain(entitled: false)
        let denied = ElevenLabsKeychain(api: fake.api)
        #expect(try denied.read() == nil)
        try denied.write("fallback-key")
        #expect(try denied.read() == "fallback-key")
        fake.items.withLock {
            #expect($0.modern.isEmpty)
            #expect($0.legacy == ["com.clipbuilder.elevenlabs|api-key": Data("fallback-key".utf8)])
        }
        try denied.write(nil)
        #expect(try denied.read() == nil)
        fake.items.withLock { #expect($0.legacy.isEmpty) }
    }
}
