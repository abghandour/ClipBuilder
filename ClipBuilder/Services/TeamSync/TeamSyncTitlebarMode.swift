import Foundation

/// What the title bar shows for Team Sync: nothing until Team settings hold a
/// server key, a Connect control while this profile is not on a team or the
/// account is signed out, and the Sync control once it is connected.
nonisolated enum TeamSyncTitlebarMode: Equatable, Sendable {
    case hidden, connect, sync

    static func current(configured: Bool, attached: Bool, signedIn: Bool) -> TeamSyncTitlebarMode {
        guard configured || attached else { return .hidden }
        return attached && signedIn ? .sync : .connect
    }
}
