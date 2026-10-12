import Foundation

/// Frozen counts from a particular analyzed source span. Refresh is explicit;
/// re-analysis never mutates timeline metadata. All fields tolerate older JSON.
nonisolated struct StrikeStatPayload: Codable, Sendable, Equatable {
    enum Kind: String, Codable, CaseIterable, Sendable { case grapplingCard, roundCard }
    enum Unit: String, Codable, CaseIterable, Sendable { case kmh = "km/h", mph, mps = "m/s" }
    enum State: String, Codable, CaseIterable, Sendable { case scored, legacy, unavailable, outcomeCheck = "outcome_check" }
    struct Scope: Codable, Sendable, Equatable {
        var start: Double?
        var end: Double?
        var analyzedSeconds: Double?
        var round: Int?
        var isRecap: Bool?
    }
    struct Values: Codable, Sendable, Equatable {
        var fighters: [Fighter]?
        var attempts: [Attempt]?
    }
    struct Fighter: Codable, Sendable, Equatable {
        var key: String?
        var name: String?
        var strikes: Int?
        var significantStrikes: Int?
        var knockdowns: Int?
    }
    struct Attempt: Codable, Sendable, Equatable {
        var kind: AttemptKind?
        var attacker: String?
        var defender: String?
        var completed: Int?
        var defended: Int?
        var unresolved: Int?
        var legacy: Int?
        var holds: [String: Int]?
        var outcomeCheck: Bool?

        init(_ pair: StrikeStatsSummary.Pair) {
            kind = pair.kind; attacker = pair.attacker; defender = pair.defender
            completed = pair.completed; defended = pair.defended; unresolved = pair.unresolved
            legacy = pair.legacy; holds = pair.holds; outcomeCheck = pair.outcomeCheck
        }

        var pair: StrikeStatsSummary.Pair {
            StrikeStatsSummary.Pair(kind: kind ?? .takedown, attacker: attacker ?? "", defender: defender ?? "",
                                    completed: completed ?? 0, defended: defended ?? 0, unresolved: unresolved ?? 0,
                                    legacy: legacy ?? 0, holds: holds ?? [:], outcomeCheck: outcomeCheck ?? false)
        }
    }
    var version: Int? = 1
    var kind: Kind?
    var sourceVideoID: Int64?
    var sourceTime: Double?
    var fighterKey: String?
    var values: Values?
    var states: [State]?
    var unit: Unit?
    var scope: Scope?
    var calibrationSummary: String?
    /// nil shows both attempt kinds.
    var attemptKind: AttemptKind?
}
