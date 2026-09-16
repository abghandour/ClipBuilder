import Foundation

/// Persisted defaults are clamped again at run creation, including programmatic edits.
nonisolated struct BuilderAgentLimits: Codable, Sendable, Equatable {
    /// Runs that look at frames take minutes: a 68 s podcast clip framed at
    /// speaker changes used three, so the default allows ten.
    static let defaultWallSeconds = 600.0
    /// The default before frame sampling existed; a saved copy of it means
    /// "never chosen", not "three minutes".
    static let legacyWallSeconds = 180.0
    var wallSeconds: Double = BuilderAgentLimits.defaultWallSeconds
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
        let saved = try c.decodeIfPresent(Double.self, forKey: .wallSeconds) ?? Self.defaultWallSeconds
        wallSeconds = saved == Self.legacyWallSeconds ? Self.defaultWallSeconds : saved
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
        value.wallSeconds = wallSeconds.isFinite ? min(1800, max(1, wallSeconds)) : Self.defaultWallSeconds
        value.toolCalls = min(128, max(1, toolCalls))
        value.affectedItems = min(10_000, max(1, affectedItems))
        value.argumentBytes = min(256 * 1024, max(1024, argumentBytes))
        value.resultBytes = min(1024 * 1024, max(1024, resultBytes))
        value.loggedBytes = min(1024 * 1024, max(1024, loggedBytes))
        value.outputBytes = min(16 * 1024 * 1024, max(1024, outputBytes))
        return value
    }
}

/// Budget exhaustion is terminal for the run even when the refused call was a
/// read-only query: the endpoint distinguishes it from a retryable refusal.
nonisolated struct BuilderBudgetExceeded: Error, LocalizedError, Sendable {
    let reason: String
    var errorDescription: String? { reason }
}

@MainActor
final class BuilderRunBudget {
    let limits: BuilderAgentLimits
    let started = ContinuousClock.now
    private(set) var calls = 0
    private(set) var items = 0
    private(set) var logged = 1024 // Reserved for the terminal event, even after exhaustion.

    init(_ limits: BuilderAgentLimits) { self.limits = limits.bounded }

    var scriptClock: ScriptExecutionControl?

    func checkTime() throws {
        if let scriptClock {
            if let reason = scriptClock.reason { throw BuilderBudgetExceeded(reason: reason) }
            try Task.checkCancellation()
            return
        }
        guard started.duration(to: .now) < .seconds(limits.wallSeconds) else {
            throw BuilderBudgetExceeded(reason: "Agent wall-time budget exhausted.")
        }
        try Task.checkCancellation()
    }

    func admit(arguments: Int, affected: Int) throws {
        try checkTime()
        guard calls < limits.toolCalls, arguments <= limits.argumentBytes,
              affected <= limits.affectedItems - items,
              logged <= limits.loggedBytes else {
            throw BuilderBudgetExceeded(reason: "Agent call, item, payload or log budget exhausted.")
        }
        calls += 1
        items += affected
    }

    func chargeLog(_ bytes: Int) throws {
        guard bytes <= limits.loggedBytes - logged else {
            throw BuilderBudgetExceeded(reason: "Agent log budget exhausted.")
        }
        logged += bytes
    }
}
