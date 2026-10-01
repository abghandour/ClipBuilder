import Foundation

nonisolated struct InstagramTokenRefresh: Sendable {
    let token: String
    let refreshedAt: Date
    let expiresAt: Date
}
