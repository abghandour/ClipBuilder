import Foundation
import Security
import Testing
@testable import Clip_Builder

/// The shared keychain item behind every store: lives in the access group
/// both channels are entitled to, adopts login-keychain items once, and
/// falls back to the login keychain only when this build has no entitlement.
struct AppKeychainItemTests {
    @Test func sharedQueriesNameTheAccessGroupAndLegacyOnesDoNot() {
        let item = AppKeychain.Item(service: "svc", account: "acct")
        let shared = item.query(legacy: false)
        #expect(shared[kSecAttrAccessGroup as String] as? String == AppKeychain.accessGroup)
        #expect(shared[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(AppKeychain.accessGroup.hasSuffix(".com.mokotti-solutions.clipbuilder.shared"))
        let legacy = item.query(legacy: true)
        #expect(legacy[kSecAttrAccessGroup as String] == nil)
        #expect(legacy[kSecUseDataProtectionKeychain as String] == nil)
        #expect(legacy[kSecAttrService as String] as? String == "svc")
        #expect(legacy[kSecAttrAccount as String] as? String == "acct")
    }

    @Test func aLoginKeychainItemMovesToTheSharedKeychainOnce() throws {
        let fake = FakeKeychain()
        fake.items.withLock { $0.legacy["svc|acct"] = Data("old".utf8) }
        let item = AppKeychain.Item(service: "svc", account: "acct", api: fake.api)
        #expect(try item.read() == Data("old".utf8))
        fake.items.withLock {
            #expect($0.modern["svc|acct"] == Data("old".utf8))
            #expect($0.legacy.isEmpty)
        }
        try item.write(Data("new".utf8))
        #expect(try item.read() == Data("new".utf8))
        try item.write(nil)
        #expect(try item.read() == nil)
        fake.items.withLock { #expect($0.modern.isEmpty && $0.legacy.isEmpty) }
    }

    @Test func withoutTheEntitlementTheLoginKeychainServesAndKeepsItsItem() throws {
        let fake = FakeKeychain(entitled: false)
        fake.items.withLock { $0.legacy["svc|acct"] = Data("old".utf8) }
        let item = AppKeychain.Item(service: "svc", account: "acct", api: fake.api)
        #expect(try item.read() == Data("old".utf8))
        try item.write(Data("new".utf8))
        fake.items.withLock {
            #expect($0.legacy["svc|acct"] == Data("new".utf8))
            #expect($0.modern.isEmpty)
        }
    }

    @Test func aFailedSharedWriteIsAnErrorAndLeavesTheOldItem() throws {
        let fake = FakeKeychain(modernWriteStatus: errSecIO)
        fake.items.withLock { $0.legacy["svc|acct"] = Data("old".utf8) }
        let item = AppKeychain.Item(service: "svc", account: "acct", api: fake.api)
        #expect(try item.read() == Data("old".utf8))
        #expect(throws: AppKeychain.Failure(status: errSecIO)) { try item.write(Data("new".utf8)) }
        fake.items.withLock {
            #expect($0.legacy["svc|acct"] == Data("old".utf8))
            #expect($0.modern.isEmpty)
        }
    }

    @Test func instagramTokensAndTheTeamSessionUseTheSharedItem() throws {
        let fake = FakeKeychain()
        try KeychainStore.save("token", account: KeychainStore.graphTokenAccount(igUserID: "7"), api: fake.api)
        #expect(KeychainStore.read(account: "instagram_graph_token:7", api: fake.api) == "token")
        fake.items.withLock { #expect($0.modern.keys.contains("com.clipbuilder.instagram|instagram_graph_token:7")) }
        KeychainStore.delete(account: "instagram_graph_token:7", api: fake.api)
        #expect(KeychainStore.read(account: "instagram_graph_token:7", api: fake.api) == nil)
    }
}
