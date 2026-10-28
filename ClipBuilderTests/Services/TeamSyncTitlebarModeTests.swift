import Foundation
import Testing
@testable import Clip_Builder

struct TeamSyncTitlebarModeTests {
    @Test func connectUntilAttachedAndSignedIn() {
        #expect(TeamSyncTitlebarMode.current(configured: false, attached: false, signedIn: false) == .hidden)
        #expect(TeamSyncTitlebarMode.current(configured: true, attached: false, signedIn: true) == .connect)
        #expect(TeamSyncTitlebarMode.current(configured: true, attached: true, signedIn: false) == .connect)
        #expect(TeamSyncTitlebarMode.current(configured: false, attached: true, signedIn: false) == .connect)
        #expect(TeamSyncTitlebarMode.current(configured: true, attached: true, signedIn: true) == .sync)
    }

    @Test func storedSessionMarkerIsPerServerAndNeverReadsTheKeychain() throws {
        let defaults = try #require(UserDefaults(suiteName: "TeamSyncTitlebarModeTests.\(UUID().uuidString)"))
        #expect(!TeamSyncSession.hasStoredSession(url: "https://a.supabase.co", defaults: defaults))
        defaults.set(true, forKey: TeamSyncSession.markerKey(url: "https://a.supabase.co"))
        #expect(TeamSyncSession.hasStoredSession(url: "https://a.supabase.co", defaults: defaults))
        #expect(!TeamSyncSession.hasStoredSession(url: "https://b.supabase.co", defaults: defaults))
    }
}
