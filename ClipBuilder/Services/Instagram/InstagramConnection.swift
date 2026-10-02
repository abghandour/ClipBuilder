import Foundation

nonisolated struct InstagramConnection: Codable, Sendable, Identifiable, Equatable {
    var username: String
    var igUserID: String
    var tokenFlavor: String
    var tokenExpiresAt: Date?
    var tokenRefreshedAt: Date?
    var id: String { igUserID }

    enum CodingKeys: String, CodingKey {
        case username
        case igUserID = "ig_user_id"
        case tokenFlavor = "token_flavor"
        case tokenExpiresAt = "token_expires_at"
        case tokenRefreshedAt = "token_refreshed_at"
    }
}
