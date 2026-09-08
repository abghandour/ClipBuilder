import Foundation
import Observation

/// Lets synchronous catalog accessors establish a SwiftUI observation dependency.
/// Worker refreshes publish on MainActor; menus then read the refreshed snapshot.
@MainActor @Observable
final class AssetCatalogChanges {
    static let shared = AssetCatalogChanges()
    private(set) var revision: UInt64 = 0

    nonisolated static func observe() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { _ = shared.revision }
        }
    }

    static let notification = Notification.Name("AssetCatalogChanges")

    nonisolated static func publish() {
        Task { @MainActor in
            shared.revision &+= 1
            NotificationCenter.default.post(name: notification, object: nil)
        }
    }
}
