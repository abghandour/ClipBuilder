import Foundation
import CryptoKit

/// The only wire format used by the learning page, Drive, and resource bundles.
nonisolated struct LearnedPreferences: Codable, Sendable, Hashable {
    static let currentVersion = 1
    var version = currentVersion
    var contributor: String
    var sections: [Section]

    enum Kind: String, Codable, CaseIterable, Sendable {
        case style, taste, lessons, vocabulary, benchmarks, people, research
        var defaultEnabled: Bool { self != .people && self != .research }
    }

    struct Section: Codable, Sendable, Hashable, Identifiable {
        var kind: Kind
        var enabled: Bool
        var updatedAt: Date
        var evidence: String
        var items: [Item]
        var id: Kind { kind }
    }

    struct Item: Codable, Sendable, Hashable, Identifiable {
        var id: String
        var field: String
        var text: String
        var pinned = false
        var evidence = ""
        var updatedAt: Date
        var frames: [String] = []
        var numbers: [String: Double] = [:]
    }

    var frameNames: [String] { Array(Set(sections.flatMap(\.items).flatMap(\.frames))).sorted() }

    static func stableID(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func contributor(profile: BrandProfile) -> String {
        // This deliberately never consults the account, host name, or credentials.
        ProfileStore.sanitize(profile.profileName + " - " + profile.learnedSharing.deviceNickname)
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
    }
}

nonisolated struct LearnedSharing: Codable, Sendable, Hashable {
    var deviceNickname = ""
    var enabled: [String: Bool] = [:]
    var mutedContributors: Set<String> = []
    var dismissedLessons: Set<String> = []
    var updatedAt: [String: Date] = [:]
}
