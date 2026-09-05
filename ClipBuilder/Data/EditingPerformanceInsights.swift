import Foundation

nonisolated struct EditingPerformanceInsights: Sendable {
    struct Athlete: Identifiable, Sendable {
        var key: String
        var name: String
        var appearances: Int
        var followersGained: Double
        var views: Double
        var reach: Double
        var watchTime: Double
        var shares: Double
        var saves: Double
        var comments: Double
        var id: String { key }
    }

    struct Pattern: Identifiable, Sendable {
        var dimension: String
        var value: String
        var reels: Int
        var averageWatchTime: Double
        var averageReach: Double
        var id: String { "\(dimension)|\(value)" }
    }

    var athletes: [Athlete]
    var patterns: [Pattern]
    var suggestedHook: String?
    var suggestedLayout: String?
    var suggestedCadence: Double?
}
