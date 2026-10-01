import Foundation

/// Captured once for the entire run, including the image bytes. A manual refresh
/// in another window cannot change the judge between versions.
nonisolated struct CriticBriefContext: Sendable {
    var brief: CriticBrief
    var frames: [AIFrame]

    static func loadForRun(database: Database, profile: BrandProfile, generatedID: Int64,
                           ai: AIService, emit: @escaping @Sendable (String) -> Void) async throws -> Self? {
        let store = CriticBriefStore(profile: profile)
        return try await loadForRun(database: database, profile: profile, generatedID: generatedID,
                                    store: store, build: { pool in
            try await store.build(pool: pool, profile: profile, ai: ai, emit: emit)
        }, emit: emit)
    }

    /// Inject the cache and expensive build boundary so policy tests need no AI or media encoding.
    static func loadForRun(database: Database, profile: BrandProfile, generatedID: Int64,
                           store: CriticBriefStore,
                           build: @Sendable ([CriticExemplars.Candidate]) async throws -> CriticBrief?,
                           emit: @escaping @Sendable (String) -> Void) async throws -> Self? {
        let use = profile.criticBriefUse
        guard use != .off else { return nil }
        var brief = try await AppJobWork.run { store.load() }
        let cached = brief
        let keepRulePassed = try await AppJobWork.run {
            cached.map { store.enabledByDefault($0) } ?? false
        }
        guard use.isEnabled(keepRulePassed: keepRulePassed) else {
            emit("Critic brief has not passed the agreement keep rule; reviewing without brief. Evaluate Critic in Settings > AI.")
            return nil
        }
        let exclusion = try await database.criticExclusion(generatedID: generatedID)
        let selection = try await CriticExemplars.select(database: database, profile: profile, excluding: exclusion, emit: emit)
        if let cached = brief {
            // Never use a cached teacher containing the target or its siblings.
            let candidates = try await database.criticExemplarCandidates()
            let safeIDs = try await AppJobWork.run {
                Set(candidates.filter { !exclusion.contains($0) && FileManager.default.fileExists(atPath: $0.path) }.map(\.id))
            }
            guard cached.exemplars.allSatisfy({ safeIDs.contains($0.id) }) else {
                emit("Critic brief contains an excluded or missing reel; reviewing without brief.")
                return nil
            }
            let key = try await AppJobWork.run { try CriticBriefStore.key(pool: selection.exemplars, profile: profile) }
            if key != cached.key {
                emit("Critic brief is stale (favorites changed); refresh from Wizard > Critic Brief")
            }
        } else {
            guard selection.reason == nil else { return nil }
            emit("Critic brief: building once before the first critique…")
            brief = try await build(selection.exemplars)
        }
        guard let brief else { return nil }
        let frames = try await AppJobWork.run { try store.frames(for: brief) }
        return Self(brief: brief, frames: frames)
    }

    func logStaleness(database: Database, profile: BrandProfile, generatedID: Int64,
                      emit: @escaping @Sendable (String) -> Void) async throws {
        let exclusion = try await database.criticExclusion(generatedID: generatedID)
        let pool = try await CriticExemplars.select(database: database, profile: profile, excluding: exclusion)
        let current = try await AppJobWork.run { try CriticBriefStore.key(pool: pool.exemplars, profile: profile) }
        if current != brief.key {
            emit("Critic brief is stale (favorites changed); refresh from Wizard > Critic Brief")
        }
    }

}
