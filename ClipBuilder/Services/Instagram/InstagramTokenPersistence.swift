import Foundation

/// Retained by the service's callback, without retaining the app store.
@MainActor
final class InstagramTokenPersistence {
    weak var store: AppStore?

    func save(_ refresh: InstagramTokenRefresh, connection: InstagramConnection,
              replacing token: String) throws -> Bool {
        try store?.applyInstagramTokenRefresh(refresh, connection: connection, replacing: token) ?? false
    }
}
