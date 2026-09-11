import Foundation

/// Persisted defaults are clamped again at run creation, including programmatic edits.
nonisolated struct BuilderAgentLimits: Codable, Sendable, Equatable {
    var wallSeconds: Double = 180
    var toolCalls = 64
    var affectedItems = 2_000
    var argumentBytes = 256 * 1024
    var resultBytes = 1024 * 1024
    var loggedBytes = 256 * 1024
    var outputBytes = 8 * 1024 * 1024

    init() {}
    private enum CodingKeys: String, CodingKey {
        case wallSeconds, toolCalls, affectedItems, argumentBytes, resultBytes, loggedBytes, outputBytes
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wallSeconds = try c.decodeIfPresent(Double.self, forKey: .wallSeconds) ?? 180
        toolCalls = try c.decodeIfPresent(Int.self, forKey: .toolCalls) ?? 64
        affectedItems = try c.decodeIfPresent(Int.self, forKey: .affectedItems) ?? 2_000
        argumentBytes = try c.decodeIfPresent(Int.self, forKey: .argumentBytes) ?? 256 * 1024
        resultBytes = try c.decodeIfPresent(Int.self, forKey: .resultBytes) ?? 1024 * 1024
        loggedBytes = try c.decodeIfPresent(Int.self, forKey: .loggedBytes) ?? 256 * 1024
        outputBytes = try c.decodeIfPresent(Int.self, forKey: .outputBytes) ?? 8 * 1024 * 1024
        self = bounded
    }

    var bounded: Self {
        var value = self
        value.wallSeconds = wallSeconds.isFinite ? min(600, max(1, wallSeconds)) : 180
        value.toolCalls = min(128, max(1, toolCalls))
        value.affectedItems = min(10_000, max(1, affectedItems))
        value.argumentBytes = min(256 * 1024, max(1024, argumentBytes))
        value.resultBytes = min(1024 * 1024, max(1024, resultBytes))
        value.loggedBytes = min(1024 * 1024, max(1024, loggedBytes))
        value.outputBytes = min(16 * 1024 * 1024, max(1024, outputBytes))
        return value
    }
}

@MainActor
final class BuilderRunBudget {
    let limits: BuilderAgentLimits
    let started = ContinuousClock.now
    private(set) var calls = 0
    private(set) var items = 0
    private(set) var logged = 1024 // Reserved for the terminal event, even after exhaustion.

    init(_ limits: BuilderAgentLimits) { self.limits = limits.bounded }

    func checkTime() throws {
        guard started.duration(to: .now) < .seconds(limits.wallSeconds) else {
            throw ScriptError.invalid("Agent wall-time budget exhausted.")
        }
        try Task.checkCancellation()
    }

    func admit(arguments: Int, affected: Int) throws {
        try checkTime()
        guard calls < limits.toolCalls, arguments <= limits.argumentBytes,
              affected <= limits.affectedItems - items,
              logged <= limits.loggedBytes else {
            throw ScriptError.invalid("Agent call, item, payload or log budget exhausted.")
        }
        calls += 1
        items += affected
    }

    func chargeLog(_ bytes: Int) throws {
        guard bytes <= limits.loggedBytes - logged else {
            throw ScriptError.invalid("Agent log budget exhausted.")
        }
        logged += bytes
    }
}
